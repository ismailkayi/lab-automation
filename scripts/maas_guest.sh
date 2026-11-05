#!/bin/bash
# Runs inside the MAAS demo VM. Safe to rerun: every step checks what
# already exists and only creates what is missing.
set -Eeuo pipefail

export PATH="$PATH:/snap/bin"
export DEBIAN_FRONTEND=noninteractive

# shellcheck source=/dev/null
source /root/maas.env

# MAAS_IP and the channels are passed in by the host script.
: "${MAAS_IP:?MAAS_IP is not set}"
MAAS_CHANNEL="${MAAS_CHANNEL:-3.8/candidate}"
LXD_CHANNEL="${MAAS_LXD_CHANNEL:-5.21/stable}"
POSTGRESQL_CHANNEL="16/stable"
TARGET_COUNT="${MAAS_TARGET_COUNT:-2}"

SERIES="noble"
MAAS_URL="http://${MAAS_IP}:5240/MAAS"
PXE_CIDR="${PXE_PREFIX}.0/24"
PXE_GATEWAY="${PXE_PREFIX}.1"
DYNAMIC_START="${PXE_PREFIX}.100"
DYNAMIC_END="${PXE_PREFIX}.199"
VM_HOST_NAME="lab-lxd"
LXD_PROJECT="maas"
LXD_CERT="/root/maas-lxd.crt"
LXD_KEY="/root/maas-lxd.key"
SSH_KEY="/root/.ssh/id_ed25519"
TARGET_CORES=2
TARGET_MEMORY_MIB=2048
TARGET_DISK_GB=20
STEP=0
TOTAL_STEPS=9

step() { STEP=$((STEP + 1)); echo; echo "==> [${STEP}/${TOTAL_STEPS}] $*"; }
trap '(( BASH_SUBSHELL == 0 )) && echo "ERROR: step ${STEP} failed at line ${LINENO}. Fix the cause and rerun menu 12; completed steps are skipped." >&2' ERR

# Retries commands that depend on the network (snap store, apt, image servers).
retry() {
    local attempt
    for attempt in 1 2 3 4 5; do
        "$@" && return 0
        echo "    attempt ${attempt}/5 failed: $*" >&2
        if [[ "$attempt" -lt 5 ]]; then sleep $((attempt * 20)); fi
    done
    return 1
}

wait_until() {
    local description="$1" seconds="$2"
    shift 2
    local deadline=$((SECONDS + seconds))
    until "$@" >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for ${description}" >&2
            return 1
        fi
        sleep 10
    done
}

install_snap() {
    local name="$1" channel="$2"
    shift 2
    if snap list "$name" >/dev/null 2>&1; then
        echo "    ${name} already installed"
    else
        retry snap install "$name" --channel="$channel" "$@"
    fi
}

mcli() { maas admin "$@"; }
psql_admin() { postgresql.psql -U postgres -h /tmp -tAc "$1"; }

step "Preparing the system"
cloud-init status --wait >/dev/null || true
snap wait system seed.loaded
if [[ ! -e /dev/kvm ]]; then
    echo "ERROR: /dev/kvm is missing in this VM, so the demo machines cannot start. Enable nested virtualization on the lab host." >&2
    false
fi
snapd_ready() { dpkg --compare-versions "$(snap version | awk '$1 == "snapd" {print $2}')" ge 2.75; }
snapd_ready || retry snap refresh snapd
snapd_ready || { echo "ERROR: MAAS 3.8 needs snapd 2.75 or newer." >&2; false; }
# MAAS runs its own chrony, which conflicts with systemd-timesyncd before Ubuntu 25.10.
if dpkg --compare-versions "$(. /etc/os-release && echo "$VERSION_ID")" lt 25.10; then
    systemctl disable --now systemd-timesyncd 2>/dev/null || true
fi
command -v jq >/dev/null || { retry apt-get update -qq; retry apt-get install -y -qq jq; }

step "Installing the MAAS, PostgreSQL and LXD snaps"
install_snap postgresql "$POSTGRESQL_CHANNEL"
install_snap maas "$MAAS_CHANNEL"
if ! snap list lxd >/dev/null 2>&1; then
    retry snap install lxd --channel="$LXD_CHANNEL"
elif [[ "$(snap list lxd | awk 'NR == 2 {print $4}')" != "$LXD_CHANNEL" ]]; then
    retry snap refresh lxd --channel="$LXD_CHANNEL"
fi
# The demo stays on the installed revisions until the instructor updates them.
snap refresh --hold=forever maas postgresql lxd >/dev/null

step "Initializing MAAS (region and rack controller)"
wait_until "PostgreSQL" 180 psql_admin "SELECT 1"
[[ "$(psql_admin "SELECT 1 FROM pg_roles WHERE rolname = 'maas'")" == 1 ]] \
    || psql_admin "CREATE ROLE maas LOGIN PASSWORD '${DB_PASSWORD}'" >/dev/null
[[ "$(psql_admin "SELECT 1 FROM pg_database WHERE datname = 'maas'")" == 1 ]] \
    || postgresql.createdb -U postgres -h /tmp -O maas maas
if [[ "$(cat /var/snap/maas/common/snap_mode 2>/dev/null || true)" != "region+rack" ]]; then
    maas init region+rack --database-uri "postgres://maas:${DB_PASSWORD}@localhost/maas" \
        --maas-url "$MAAS_URL" --force
fi
wait_until "the MAAS API" 300 curl -fsS --max-time 10 "http://localhost:5240/MAAS/api/2.0/version/"
if ! maas apikey --username admin >/dev/null 2>&1; then
    maas createadmin --username admin --password "$ADMIN_PASSWORD" --email admin@maas.demo
fi
maas login admin "http://localhost:5240/MAAS" "$(maas apikey --username admin)" >/dev/null
# Machines resolve names through MAAS, which forwards to the lab bridge's resolver.
mcli maas set-config name=upstream_dns value="${SUBNET_PREFIX}.1" >/dev/null
mcli maas set-config name=completed_intro value=true >/dev/null

step "Selecting and importing the Ubuntu boot images"
SOURCE_ID="$(mcli boot-sources read | jq -r '.[0].id')"
COMMISSIONING_SERIES="$(mcli maas get-config name=commissioning_distro_series | jq -r '.')"
for series in "$SERIES" "$COMMISSIONING_SERIES"; do
    if ! mcli boot-source-selections read "$SOURCE_ID" \
        | jq -e --arg series "$series" 'any(.[]; .release == $series)' >/dev/null; then
        mcli boot-source-selections create "$SOURCE_ID" os=ubuntu release="$series" \
            arches=amd64 subarches='*' labels='*' >/dev/null
    fi
done
mcli boot-resources import >/dev/null

step "Preparing LXD as the machine host"
lxd waitready --timeout 300
lxc storage show default >/dev/null 2>&1 || lxc storage create default dir
# MAAS provides DHCP and DNS on this bridge, so LXD must not. MAAS's named binds
# every new address at once, so dnsmasq must not claim port 53 either.
lxc network show maas-pxe >/dev/null 2>&1 \
    || lxc network create maas-pxe ipv4.address="${PXE_GATEWAY}/24" ipv4.nat=true \
        ipv4.dhcp=false ipv6.address=none dns.mode=none raw.dnsmasq=port=0
[[ "$(lxc config get core.https_address)" == "${MAAS_IP}:8443" ]] \
    || lxc config set core.https_address "${MAAS_IP}:8443"
if [[ ! -f "$LXD_KEY" ]]; then
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 -subj "/CN=maas-demo" \
        -keyout "$LXD_KEY" -out "$LXD_CERT" 2>/dev/null
    chmod 600 "$LXD_KEY"
fi
lxc config trust list --format json | jq -e 'any(.[]; .name == "maas-demo")' >/dev/null \
    || lxc config trust add "$LXD_CERT" --name maas-demo

step "Configuring the machine network and DHCP in MAAS"
rack_id() { mcli rack-controllers read | jq -r '.[0].system_id // empty'; }
have_rack() { [[ -n "$(rack_id)" ]]; }
pxe_subnet() { mcli subnets read | jq -c --arg cidr "$PXE_CIDR" '[.[] | select(.cidr == $cidr)] | first // empty'; }
have_subnet() { [[ -n "$(pxe_subnet)" ]]; }
wait_until "the rack controller" 300 have_rack
RACK_ID="$(rack_id)"
# The rack reports the new bridge to MAAS on its next interface scan.
wait_until "MAAS to discover ${PXE_CIDR}" 600 have_subnet
SUBNET="$(pxe_subnet)"
SUBNET_ID="$(jq -r '.id' <<< "$SUBNET")"
FABRIC_ID="$(jq -r '.vlan.fabric_id' <<< "$SUBNET")"
VLAN_TAG="$(jq -r '.vlan.vid' <<< "$SUBNET")"
mcli subnet update "$SUBNET_ID" gateway_ip="$PXE_GATEWAY" >/dev/null
mcli ipranges read | jq -e --arg start "$DYNAMIC_START" 'any(.[]; .type == "dynamic" and .start_ip == $start)' >/dev/null \
    || mcli ipranges create type=dynamic subnet="$SUBNET_ID" start_ip="$DYNAMIC_START" \
        end_ip="$DYNAMIC_END" comment="Demo machines" >/dev/null
mcli vlan read "$FABRIC_ID" "$VLAN_TAG" | jq -e '.dhcp_on' >/dev/null \
    || mcli vlan update "$FABRIC_ID" "$VLAN_TAG" dhcp_on=True primary_rack="$RACK_ID" >/dev/null

step "Adding LXD as a MAAS VM host and uploading an SSH key"
VM_HOST_ID="$(mcli vm-hosts read | jq -r --arg name "$VM_HOST_NAME" '[.[] | select(.name == $name)] | first | .id // empty')"
if [[ -z "$VM_HOST_ID" ]]; then
    VM_HOST_ID="$(mcli vm-hosts create type=lxd name="$VM_HOST_NAME" project="$LXD_PROJECT" \
        power_address="https://${MAAS_IP}:8443" certificate="$(cat "$LXD_CERT")" key="$(cat "$LXD_KEY")" \
        | jq -r '.id')"
fi
install -d -m 700 "$(dirname "$SSH_KEY")"
[[ -f "$SSH_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "maas-demo" -f "$SSH_KEY"
mcli sshkeys read | jq -e --arg key "$(cut -d' ' -f2 "${SSH_KEY}.pub")" 'any(.[]; .key | contains($key))' >/dev/null \
    || mcli sshkeys create key="$(cat "${SSH_KEY}.pub")" >/dev/null

step "Waiting for the boot images to sync (the first import can take 10-20 minutes)"
images_synced() {
    mcli rack-controller list-boot-images "$RACK_ID" | jq -e --arg name "ubuntu/${SERIES}" \
        '.status == "synced" and any(.images[]; .name == $name)' >/dev/null
}
wait_until "the boot images" 3600 images_synced

machine_id() { mcli machines read hostname="$1" | jq -r --arg name "$1" '[.[] | select(.hostname == $name)] | first | .system_id // empty'; }
machine_status() { mcli machine read "$1" | jq -r '.status_name'; }

# Waits for a machine to reach a status; stops early on any failed state.
wait_machine() {
    local id="$1" wanted="$2" seconds="$3" deadline status last=""
    deadline=$((SECONDS + seconds))
    while true; do
        status="$(machine_status "$id")" || status="unknown"
        [[ "$status" == "$wanted" ]] && return 0
        case "$status" in
            Failed* | Broken | Missing)
                echo "ERROR: machine ${id} reached '${status}' while waiting for '${wanted}'." >&2
                return 1
                ;;
        esac
        if [[ "$status" != "$last" ]]; then
            echo "    ${id}: ${status}"
            last="$status"
        fi
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for machine ${id} to become ${wanted} (now ${status})." >&2
            return 1
        fi
        sleep 10
    done
}

step "Composing ${TARGET_COUNT} demo machines and waiting until they are Ready"
NAMES=()
for index in $(seq 1 "$TARGET_COUNT"); do
    NAMES+=("$(printf 'maas-demo-%02d' "$index")")
done
for name in "${NAMES[@]}"; do
    if [[ -z "$(machine_id "$name")" ]]; then
        mcli vm-host compose "$VM_HOST_ID" hostname="$name" cores="$TARGET_CORES" \
            memory="$TARGET_MEMORY_MIB" storage="root:${TARGET_DISK_GB}" >/dev/null
    fi
done
mcli tags read | jq -e 'any(.[]; .name == "demo")' >/dev/null \
    || mcli tags create name=demo comment="Machines created for the MAAS demo" >/dev/null
for name in "${NAMES[@]}"; do
    id="$(machine_id "$name")"
    echo "    ${name} (${id})"
    status="$(machine_status "$id")"
    [[ "$status" == "Failed commissioning" ]] && mcli machine commission "$id" >/dev/null
    # Setup stops at Ready. On a rerun, machines the instructor has allocated or deployed are left alone.
    case "$status" in
        New | Commissioning | Testing | "Failed commissioning") wait_machine "$id" Ready 1800 ;;
    esac
    mcli tag update-nodes demo add="$id" >/dev/null
done

MAAS_VERSION="$(snap list maas | awk 'NR == 2 {print $2}')"
MACHINES="$(mcli machines read | jq -r '[.[] | select(.hostname | startswith("maas-demo-")) | "\(.hostname): \(.status_name)\(if .status_name == "Deployed" then " (\(.ip_addresses[0]))" else "" end)"] | sort | join("; ")')"
(
    umask 077
    printf 'MAAS_IP=%q\nMAAS_VERSION=%q\nMACHINES=%q\n' "$MAAS_IP" "$MAAS_VERSION" "$MACHINES" > /root/maas-access.env
)
echo
echo "MAAS is ready: ${MAAS_URL}"
echo "Machines: ${MACHINES}"
