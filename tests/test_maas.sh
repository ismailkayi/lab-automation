#!/bin/bash
# Variables set here are read by the sourced MAAS functions.
# shellcheck disable=SC2034
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../orchestrate.sh
source "${REPO_ROOT}/orchestrate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "Expected '$2' in '$1'"; }

MAAS_STATE_DIR="$TMP/state"
MAAS_SETTINGS="$MAAS_STATE_DIR/settings.env"
MAAS_ACCESS="$MAAS_STATE_DIR/access.env"
lxc() { fail "Unexpected real LXD call: $*"; }
curl() { fail "Unexpected real HTTP call: $*"; }

# Settings hold two different subnets and private credentials, and are kept on resume.
(
    : > "$TMP/calls"
    cm_pick_subnet_prefix() {
        echo "picked: $*" >> "$TMP/calls"
        if (( $# == 0 )); then echo "172.31.7"; else echo "172.31.8"; fi
    }
    maas_prepare_settings
    [[ "$(stat -c %a "$MAAS_STATE_DIR")" == "700" ]] || fail "State directory must be private"
    [[ "$(stat -c %a "$MAAS_SETTINGS")" == "600" ]] || fail "Settings must be private"
    grep -qx 'SUBNET_PREFIX=172.31.7' "$MAAS_SETTINGS" || fail "Missing the uplink subnet"
    grep -qx 'PXE_PREFIX=172.31.8' "$MAAS_SETTINGS" || fail "Missing the machine subnet"
    assert_contains "$(cat "$TMP/calls")" $'picked: \npicked: 172.31.7.0/24'
    for key in ADMIN_PASSWORD DB_PASSWORD; do
        grep -Eq "^${key}=[A-Za-z0-9]{24}\$" "$MAAS_SETTINGS" || fail "${key} must be alphanumeric"
    done
    before="$(cat "$MAAS_SETTINGS")"
    cm_pick_subnet_prefix() { echo "172.31.9"; }
    maas_prepare_settings
    [[ "$(cat "$MAAS_SETTINGS")" == "$before" ]] || fail "Resume must keep the saved settings"
)

# Subnets chosen together must not collide, although the second one is not created yet.
(
    ip() { echo '[{"dst": "default"}, {"dst": "172.31.0.0/24"}]'; }
    lxc() {
        echo '[{"config": {"ipv4.address": "172.31.1.1/24"}}, {"config": {"user.lab-automation.cidr": "172.31.2.0/24"}}]'
    }
    [[ "$(cm_pick_subnet_prefix)" == "172.31.3" ]] || fail "Routes and LXD networks must be avoided"
    [[ "$(cm_pick_subnet_prefix 172.31.3.0/24)" == "172.31.4" ]] || fail "An extra CIDR must be avoided"
    [[ "$(cm_pick_subnet_prefix 172.31.3.0/24 172.31.4.0/25)" == "172.31.5" ]] || fail "Every extra CIDR must be avoided"
)

# Sizes are validated before anything is created.
(
    MAAS_VM_CPU=6 MAAS_VM_MEMORY_GIB=12 MAAS_VM_DISK_GIB=100 MAAS_TARGET_COUNT=2
    maas_validate_sizing
    for name in MAAS_VM_CPU MAAS_VM_MEMORY_GIB MAAS_VM_DISK_GIB MAAS_TARGET_COUNT; do
        for bad in 0 -3 4.5 abc ""; do
            (
                printf -v "$name" '%s' "$bad"
                if maas_validate_sizing >/dev/null 2>&1; then
                    fail "${name}='${bad}' must be refused"
                fi
            )
        done
    done
    MAAS_TARGET_COUNT=1
    maas_validate_sizing
)

# The VM only starts when the host has memory for it plus some headroom.
(
    awk() { echo 8388608; }
    MAAS_VM_MEMORY_GIB=12
    if output="$(maas_check_memory 2>&1)"; then
        fail "Too little host memory must be refused"
    fi
    assert_contains "$output" "Only 8 GiB of host memory is available"
    MAAS_VM_MEMORY_GIB=4
    maas_check_memory
)

# Instance and bridge: created with the owner label, or refused when someone else owns them.
(
    export LXD_STORAGE_POOL=demo-pool
    SUBNET_PREFIX=172.31.7
    PXE_PREFIX=172.31.8
    MAAS_VM_CPU=6 MAAS_VM_MEMORY_GIB=12 MAAS_VM_DISK_GIB=100 MAAS_VM_IMAGE=ubuntu:test-image
    maas_check_kvm() { :; }
    maas_check_memory() { :; }
    maas_ip() { echo 172.31.7.50; }
    : > "$TMP/calls"
    maas_lxc() {
        echo "$*" >> "$TMP/calls"
        case "$1 $2" in
            "network show"|"info local:lab-maas") return 1 ;;
        esac
        return 0
    }
    maas_ensure_infrastructure >/dev/null
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "network create local:lab-maasbr0 ipv4.address=172.31.7.1/24 ipv4.nat=true ipv6.address=none"
    assert_contains "$calls" "ipv4.dhcp.ranges=172.31.7.10-172.31.7.99 user.lab-automation.component=maas-demo user.lab-automation.cidr=172.31.8.0/24"
    assert_contains "$calls" "launch ubuntu:test-image local:lab-maas --vm --network lab-maasbr0 --storage demo-pool"
    assert_contains "$calls" "-c limits.cpu=6 -c limits.memory=12GiB -d root,size=100GiB -c user.lab-automation.component=maas-demo"
    assert_contains "$calls" "config device set local:lab-maas eth0 ipv4.address=172.31.7.50"
    [[ "$MAAS_IP" == "172.31.7.50" ]] || fail "The VM address must be exported for the setup"

    LXD_STORAGE_POOL=""
    : > "$TMP/calls"
    if output="$(maas_ensure_infrastructure 2>&1)"; then
        fail "A missing storage pool must stop the VM creation"
    fi
    assert_contains "$output" "No LXD storage pool selected"
    [[ "$(cat "$TMP/calls")" != *"launch"* ]] || fail "No VM may be launched without a storage pool"

    LXD_STORAGE_POOL=demo-pool
    maas_lxc() {
        case "$1 $2" in
            "network show") return 0 ;;
            "network get") echo "someone-else" ;;
            *) fail "An unowned bridge must stop the install: $*" ;;
        esac
    }
    if maas_ensure_infrastructure >/dev/null 2>&1; then
        fail "An unowned bridge must be refused"
    fi
)

# An existing VM is reused: a stopped one is started, and its address must stay the pinned one.
(
    export LXD_STORAGE_POOL=demo-pool
    SUBNET_PREFIX=172.31.7
    PXE_PREFIX=172.31.8
    maas_check_memory() { :; }
    maas_ip() { echo 172.31.7.50; }
    : > "$TMP/calls"
    PINNED=172.31.7.50
    maas_lxc() {
        echo "$*" >> "$TMP/calls"
        case "$1 $2" in
            "network show"|"info local:lab-maas") return 0 ;;
            "network get"|"config get") echo "maas-demo" ;;
            "list local:^lab-maas$") echo STOPPED ;;
            "config device") [[ "$3" == "get" ]] && echo "$PINNED" ;;
        esac
        return 0
    }
    maas_ensure_infrastructure >/dev/null
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "start local:lab-maas"
    [[ "$calls" != *"launch"* && "$calls" != *"network create"* ]] || fail "Existing resources must be reused"
    [[ "$calls" != *"config device set"* ]] || fail "An already pinned address must not be set again"

    PINNED=172.31.7.99
    if output="$(maas_ensure_infrastructure 2>&1)"; then
        fail "A changed VM address must stop the setup"
    fi
    assert_contains "$output" "pinned to 172.31.7.99"

    maas_lxc() {
        case "$1 $2" in
            "network show"|"info local:lab-maas") return 0 ;;
            "network get") echo "maas-demo" ;;
            "config get") echo "someone-else" ;;
            *) fail "An unowned VM must stop the install: $*" ;;
        esac
    }
    if maas_ensure_infrastructure >/dev/null 2>&1; then
        fail "An unowned VM must be refused"
    fi
)

# The guest output is logged, and failures propagate through tee. Only the MAAS versions are
# handed to the guest.
(
    SCRIPT_DIR="$REPO_ROOT"
    MAAS_IP=172.31.7.50 MAAS_CHANNEL=9.9/test MAAS_LXD_CHANNEL=8.8/test MAAS_TARGET_COUNT=2
    mkdir -p "$MAAS_STATE_DIR"
    : > "$TMP/calls"
    maas_lxc() {
        case "$1 $2" in
            "file push") echo "push $4" >> "$TMP/calls" ;;
            "file pull") fail "Access data must not be pulled after a failed setup" ;;
            exec*) echo "$*" >> "$TMP/calls"; echo "guest output"; return 3 ;;
        esac
    }
    if maas_run_setup >/dev/null; then
        fail "Guest setup failure must propagate through tee"
    fi
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "push local:lab-maas/root/maas.env"
    assert_contains "$calls" "push local:lab-maas/root/maas-setup.sh"
    assert_contains "$calls" "exec local:lab-maas --env MAAS_IP=172.31.7.50 --env MAAS_TARGET_COUNT=2 --env MAAS_"
    for pair in MAAS_CHANNEL=9.9/test MAAS_LXD_CHANNEL=8.8/test "MAAS_POSTGRESQL_CHANNEL=${MAAS_POSTGRESQL_CHANNEL}" \
        "MAAS_DEPLOY_SERIES=${MAAS_DEPLOY_SERIES}"; do
        assert_contains "$calls" "--env ${pair}"
    done
    assert_contains "$calls" "-- bash /root/maas-setup.sh"
    for other in LANDSCAPE_ COS_ CM_ LXD_CHANNEL K8S_ JUJU_ UBUNTU_IMAGE; do
        [[ "$calls" != *"--env ${other}"* ]] || fail "The MAAS guest must not receive ${other}* versions"
    done
    assert_contains "$(cat "$MAAS_STATE_DIR/setup.log")" "guest output"

    maas_lxc() {
        case "$1 $2" in
            "file pull") printf 'MAAS_IP=172.31.7.50\n' > "$4" ;;
        esac
    }
    maas_run_setup >/dev/null
    [[ "$(stat -c %a "$MAAS_ACCESS")" == "600" ]] || fail "Access data must be private"
    rm -f "$MAAS_ACCESS"
)

# The web check needs HTTP 200 from the UI, following MAAS's redirect to the login page.
(
    MAAS_IP=172.31.7.50
    curl() {
        [[ "$*" == *"--noproxy"* ]] || fail "The web check must bypass proxies"
        [[ "$*" == *"--location"* ]] || fail "The web check must follow the redirect"
        [[ "${*: -1}" == "http://172.31.7.50:5240/MAAS/" ]] || fail "Unexpected URL: $*"
        echo 200
    }
    maas_check_web
    curl() { echo 502; }
    if maas_check_web >/dev/null 2>&1; then
        fail "An unhealthy MAAS must fail the web check"
    fi
    curl() { return 7; }
    if maas_check_web >/dev/null 2>&1; then
        fail "An unreachable MAAS must fail the web check"
    fi
)

install_stubs() {
    printf 'SUBNET_PREFIX=172.31.7\nPXE_PREFIX=172.31.8\nADMIN_PASSWORD=Secret123\nDB_PASSWORD=DbSecret456\n' > "$MAAS_SETTINGS"
    maas_validate_sizing() { :; }
    maas_prepare_settings() { :; }
    maas_ensure_infrastructure() { echo "infra" >> "$TMP/calls"; MAAS_IP=172.31.7.50; }
    maas_run_setup() {
        echo "setup" >> "$TMP/calls"
        printf 'MAAS_IP=172.31.7.50\nMAAS_VERSION=3.8.0\nMACHINES=%q\n' \
            "maas-demo-01: Ready; maas-demo-02: Ready" > "$MAAS_ACCESS"
    }
    maas_check_web() { echo "web" >> "$TMP/calls"; }
    maas_lxc() { return 1; }
}

(
    install_stubs
    : > "$TMP/calls"
    output="$(maas_install)"
    assert_contains "$(cat "$TMP/calls")" $'infra\nsetup\nweb'
    assert_contains "$output" "MAAS demo is ready"
    assert_contains "$output" "http://172.31.7.50:5240/MAAS"
    assert_contains "$output" "admin / Secret123"
    assert_contains "$output" "maas-demo-01: Ready; maas-demo-02: Ready"
)

(
    install_stubs
    maas_check_web() { return 1; }
    if output="$(maas_install 2>&1)"; then
        fail "An unreachable MAAS must fail the install"
    fi
    [[ "$output" != *"demo is ready"* ]] || fail "An unreachable MAAS must not be reported as ready"
)

(
    install_stubs
    maas_run_setup() { return 1; }
    maas_check_web() { fail "The web UI must not be checked after a failed setup"; }
    if output="$(maas_install 2>&1)"; then
        fail "A failed guest setup must fail the install"
    fi
    assert_contains "$output" "rerun menu 12"
)

(
    install_stubs
    maas_validate_sizing() { return 1; }
    maas_prepare_settings() { fail "Invalid sizes must stop the install before any change"; }
    if maas_install >/dev/null 2>&1; then
        fail "Invalid sizes must fail the install"
    fi
)

(
    install_stubs
    rm -f "$MAAS_SETTINGS"
    maas_lxc() { [[ "$*" == "info local:lab-maas" ]]; }
    maas_ensure_infrastructure() { fail "A VM without settings must not be reused"; }
    if maas_install >/dev/null 2>&1; then
        fail "A VM without saved settings must be refused"
    fi
)

# Leftovers of any kind stay discoverable so the destroy menu can remove them.
(
    rm -f "$MAAS_SETTINGS"
    maas_lxc() { return 1; }
    if maas_installed; then
        fail "Nothing is installed"
    fi
    maas_lxc() { [[ "$*" == "network show local:lab-maasbr0" ]]; }
    maas_installed || fail "A leftover bridge must stay discoverable for cleanup"
    maas_lxc() { [[ "$*" == "info local:lab-maas" ]]; }
    maas_installed || fail "A leftover VM must stay discoverable for cleanup"
    maas_lxc() { return 1; }
    printf 'ADMIN_PASSWORD=x\n' > "$MAAS_SETTINGS"
    maas_installed || fail "Leftover settings must stay discoverable for cleanup"
)

# Destroy: keep everything when LXD is down or a resource is not ours.
(
    mkdir -p "$MAAS_STATE_DIR"
    printf 'ADMIN_PASSWORD=x\n' > "$MAAS_SETTINGS"
    maas_lxc() { return 1; }
    if output="$(maas_destroy 2>&1)"; then
        fail "Destroy must fail when LXD is unavailable"
    fi
    assert_contains "$output" "Local LXD is unavailable"
    [[ -f "$MAAS_SETTINGS" ]] || fail "Unavailable LXD must not delete the settings"

    maas_lxc() {
        case "$1 $2" in
            "info local:"|"info local:lab-maas"|"network show") return 0 ;;
            "config get") echo "maas-demo" ;;
            "network get") echo "someone-else" ;;
            *) fail "An unowned bridge must prevent all changes: $*" ;;
        esac
    }
    if maas_destroy >/dev/null 2>&1; then
        fail "An unowned bridge must be refused"
    fi
    [[ -f "$MAAS_SETTINGS" ]] || fail "A refused destroy must keep the settings"
)

(
    mkdir -p "$MAAS_STATE_DIR"
    printf 'ADMIN_PASSWORD=x\n' > "$MAAS_SETTINGS"
    printf 'MAAS_IP=172.31.7.50\n' > "$MAAS_ACCESS"
    printf 'guest output\n' > "$MAAS_STATE_DIR/setup.log"
    : > "$TMP/calls"
    maas_lxc() {
        echo "$*" >> "$TMP/calls"
        case "$1 $2" in
            "config get"|"network get") echo "maas-demo" ;;
        esac
        return 0
    }
    output="$(maas_destroy)"
    assert_contains "$(cat "$TMP/calls")" $'delete --force local:lab-maas\nnetwork delete local:lab-maasbr0'
    [[ ! -e "$MAAS_SETTINGS" && ! -e "$MAAS_ACCESS" && ! -e "$MAAS_STATE_DIR/setup.log" ]] ||
        fail "Destroy must remove the saved MAAS data"
    assert_contains "$output" "MAAS demo removed"

    # A VM that is already gone must not keep the bridge and settings alive.
    printf 'ADMIN_PASSWORD=x\n' > "$MAAS_SETTINGS"
    : > "$TMP/calls"
    maas_lxc() {
        echo "$*" >> "$TMP/calls"
        case "$1 $2" in
            "info local:lab-maas") return 1 ;;
            "network get") echo "maas-demo" ;;
        esac
        return 0
    }
    maas_destroy >/dev/null
    calls="$(cat "$TMP/calls")"
    [[ "$calls" != *"delete --force"* ]] || fail "A missing VM must not be deleted"
    assert_contains "$calls" "network delete local:lab-maasbr0"
    [[ ! -e "$MAAS_SETTINGS" ]] || fail "Destroy must remove the settings when only the bridge is left"
)

# Overview.
(
    maas_lxc() { echo "RUNNING"; }
    printf 'ADMIN_PASSWORD=Secret123\n' > "$MAAS_SETTINGS"
    printf 'MAAS_IP=172.31.7.50\nMAAS_VERSION=3.8.0\n' > "$MAAS_ACCESS"
    output="$(lab_overview_maas)"
    assert_contains "$output" "VM state           RUNNING"
    assert_contains "$output" "http://172.31.7.50:5240/MAAS"
    assert_contains "$output" "Username           admin"
    assert_contains "$output" "Password           Secret123"
    rm -f "$MAAS_ACCESS"
    output="$(lab_overview_maas)"
    assert_contains "$output" "installation not finished"
    maas_lxc() { return 1; }
    output="$(lab_overview_maas)"
    assert_contains "$output" "not installed (menu 12)"
)
sed -n '/^lab_overview() {/,/^}/p' "${REPO_ROOT}/scripts/lab_overview.sh" | grep -qx '    lab_overview_maas' ||
    fail "The lab overview must show the MAAS demo"

# Menu wiring.
(
    : > "$TMP/calls"
    tofu() { :; }
    cm_installed() { return 1; }
    landscape_instances() { :; }
    LANDSCAPE_SETTINGS="$TMP/missing"
    cos_installed() { return 1; }
    maas_installed() { return 0; }
    maas_destroy() { echo "maas removed" >> "$TMP/calls"; }
    output="$(destroy_menu <<< $'1\nyes' 2>&1)" || fail "MAAS destroy must succeed"
    assert_contains "$output" "MAAS demo (lab-maas + lab-maasbr0)"
    assert_contains "$(cat "$TMP/calls")" "maas removed"

    : > "$TMP/calls"
    output="$(destroy_menu <<< $'1\nno' 2>&1)" || fail "Cancelling must not fail"
    [[ ! -s "$TMP/calls" ]] || fail "Only 'yes' may destroy the MAAS demo"
)
grep -q '^[[:space:]]*echo " 12) MAAS' "${REPO_ROOT}/orchestrate.sh" || fail "Menu option 12 must install MAAS"
grep -A2 'action" == "12"' "${REPO_ROOT}/orchestrate.sh" | grep -q maas_install || fail "Option 12 must call maas_install"

# Guest script: the pieces that were wrong on real hardware stay fixed.
guest="${REPO_ROOT}/scripts/maas_guest.sh"
bash -n "$guest" || fail "Guest script has a syntax error"
grep -q 'raw.dnsmasq=port=0' "$guest" || fail "LXD's dnsmasq must not take port 53 from MAAS"
grep -q 'vm-hosts create type=lxd' "$guest" || fail "LXD must be added as the MAAS VM host"
grep -q 'dhcp_on=True' "$guest" || fail "MAAS must provide DHCP on the machine network"
grep -q 'sshkeys create' "$guest" || fail "An SSH key must be uploaded so machines the instructor deploys can be logged in to"
[[ "$(grep -c 'machine deploy' "$guest")" == 0 ]] || fail "Setup must leave every machine Ready for the instructor to deploy live"
grep -qF 'New | Commissioning | Testing | "Failed commissioning")' "$guest" || fail "A rerun must only wait for machines that are still being commissioned"
grep -q 'ubuntu/\${SERIES}' "$guest" || fail "The boot image check must use MAAS's image names"
[[ "$(grep -c 'rack-controller refresh' "$guest")" == 0 ]] || fail "MAAS 3.8 has no rack-controller refresh command"
for key in MAAS_CHANNEL MAAS_POSTGRESQL_CHANNEL MAAS_LXD_CHANNEL MAAS_DEPLOY_SERIES; do
    grep -qF "\"\${${key}:?}\"" "$guest" || fail "The guest must require ${key} from the host"
done
grep -F 'snap refresh lxd' "$guest" -B1 | grep -qF '! lxd_held' || fail "A rerun must not switch the channel of an LXD that is already held"
grep -qF 'snap refresh --hold=forever maas postgresql lxd' "$guest" || fail "The snaps must be held after the first setup"
if grep -Eq '[A-Za-z0-9.]+/(stable|candidate|beta|edge)' "$guest" "${REPO_ROOT}/scripts/maas.sh"; then
    fail "MAAS channels belong in versions.env, not in the scripts"
fi
steps="$(grep -c '^step "' "$guest")"
grep -qx "TOTAL_STEPS=${steps}" "$guest" || fail "Step counter must match the ${steps} steps"

echo "PASS: MAAS settings, subnet choice, sizing, infrastructure ownership, setup logging, web check, install order, destroy safety, overview and menu wiring"
