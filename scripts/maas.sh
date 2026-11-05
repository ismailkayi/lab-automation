#!/bin/bash
# Instructor-only MAAS demo; sourced by orchestrate.sh. MAAS runs in one VM on
# its own bridge. Inside that VM an LXD host on a second bridge (the PXE
# network) supplies the machines that MAAS commissions and deploys, so no
# bare-metal hardware is needed.

MAAS_VM="lab-maas"
MAAS_NETWORK="lab-maasbr0"
MAAS_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-automation/maas"
MAAS_SETTINGS="${MAAS_STATE_DIR}/settings.env"
MAAS_ACCESS="${MAAS_STATE_DIR}/access.env"
MAAS_WEB_PORT=5240

# Versions and sizes can be overridden from the environment before starting.
MAAS_CHANNEL="${MAAS_CHANNEL:-3.8/candidate}"
MAAS_LXD_CHANNEL="${MAAS_LXD_CHANNEL:-5.21/stable}"
MAAS_VM_IMAGE="${MAAS_VM_IMAGE:-ubuntu:24.04}"
MAAS_VM_CPU="${MAAS_VM_CPU:-6}"
MAAS_VM_MEMORY_GIB="${MAAS_VM_MEMORY_GIB:-10}"
MAAS_VM_DISK_GIB="${MAAS_VM_DISK_GIB:-100}"
MAAS_TARGET_COUNT="${MAAS_TARGET_COUNT:-2}"

maas_lxc() { lxc --project default "$@" </dev/null; }

maas_owned() {
    local kind="$1" name="$2" owner
    if [[ "$kind" == "network" ]]; then
        owner="$(maas_lxc network get "local:${name}" user.lab-automation.component)" || return 1
    else
        owner="$(maas_lxc config get "local:${name}" user.lab-automation.component)" || return 1
    fi
    if [[ "$owner" != "maas-demo" ]]; then
        log_warn "${name} is not owned by the MAAS demo; refusing to change it."
        return 1
    fi
}

maas_require_number() {
    if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
        log_warn "$1 must be a positive whole number (got '$2')."
        return 1
    fi
}

maas_validate_sizing() {
    maas_require_number MAAS_VM_CPU "$MAAS_VM_CPU" || return 1
    maas_require_number MAAS_VM_MEMORY_GIB "$MAAS_VM_MEMORY_GIB" || return 1
    maas_require_number MAAS_VM_DISK_GIB "$MAAS_VM_DISK_GIB" || return 1
    maas_require_number MAAS_TARGET_COUNT "$MAAS_TARGET_COUNT" || return 1
}

# The demo machines are VMs inside the MAAS VM, so the host must offer nested KVM.
maas_check_kvm() {
    local file value
    if [[ ! -e /dev/kvm ]]; then
        log_warn "/dev/kvm is missing on this host; the MAAS demo machines are VMs and need KVM."
        return 1
    fi
    for file in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
        [[ -r "$file" ]] || continue
        value="$(<"$file")"
        [[ "$value" == "Y" || "$value" == "1" ]] && return 0
        log_warn "Nested virtualization is disabled on this host (${file} is ${value}); the MAAS demo needs it."
        return 1
    done
}

maas_check_memory() {
    local available_kib needed_kib
    available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)" || return 1
    needed_kib=$(( (MAAS_VM_MEMORY_GIB + 1) * 1024 * 1024 ))
    if (( available_kib < needed_kib )); then
        log_warn "Only $((available_kib / 1024 / 1024)) GiB of host memory is available; the MAAS VM needs ${MAAS_VM_MEMORY_GIB} GiB plus 1 GiB of headroom."
        log_warn "Free some memory or lower MAAS_VM_MEMORY_GIB, then run this menu entry again."
        return 1
    fi
}

maas_prepare_settings() {
    local subnet pxe admin_password db_password
    mkdir -p "$MAAS_STATE_DIR" || return 1
    chmod 700 "$MAAS_STATE_DIR" || return 1
    [[ -f "$MAAS_SETTINGS" ]] && return 0
    # SUBNET_PREFIX is the VM's uplink; PXE_PREFIX is the machine network that
    # only exists inside the VM. The uplink bridge records it so that other
    # services never choose it.
    subnet="$(cm_pick_subnet_prefix)" || { log_warn "Could not choose a free subnet for ${MAAS_NETWORK}."; return 1; }
    pxe="$(cm_pick_subnet_prefix "${subnet}.0/24")" || { log_warn "Could not choose a free subnet for the MAAS machine network."; return 1; }
    admin_password="$(cm_random_password)" || return 1
    db_password="$(cm_random_password)" || return 1
    (
        umask 077
        printf 'SUBNET_PREFIX=%q\nPXE_PREFIX=%q\nADMIN_PASSWORD=%q\nDB_PASSWORD=%q\n' \
            "$subnet" "$pxe" "$admin_password" "$db_password" > "$MAAS_SETTINGS"
    )
}

maas_ip() {
    maas_lxc list "local:${MAAS_VM}" --format json | python3 -c '
import json, sys
instances = [i for i in json.load(sys.stdin) if i["name"] == sys.argv[1]]
for instance in instances:
    for nic, data in ((instance.get("state") or {}).get("network") or {}).items():
        if nic == "lo":
            continue
        for address in data.get("addresses", []):
            if address.get("family") == "inet" and address.get("scope") == "global":
                print(address["address"])
                sys.exit(0)
sys.exit("No global IPv4 address found for " + sys.argv[1])
' "$MAAS_VM"
}

maas_ensure_infrastructure() {
    local _ pinned
    if ! maas_lxc network show "local:${MAAS_NETWORK}" >/dev/null 2>&1; then
        log_info "Creating bridge ${MAAS_NETWORK} (${SUBNET_PREFIX}.0/24; ${PXE_PREFIX}.0/24 is reserved for the machine network inside the VM)."
        maas_lxc network create "local:${MAAS_NETWORK}" \
            ipv4.address="${SUBNET_PREFIX}.1/24" ipv4.nat=true ipv6.address=none \
            ipv4.dhcp.ranges="${SUBNET_PREFIX}.10-${SUBNET_PREFIX}.99" \
            user.lab-automation.component=maas-demo \
            user.lab-automation.cidr="${PXE_PREFIX}.0/24" || return 1
    else
        maas_owned network "$MAAS_NETWORK" || return 1
    fi

    if ! maas_lxc info "local:${MAAS_VM}" >/dev/null 2>&1; then
        [[ -n "$LXD_STORAGE_POOL" ]] || { log_warn "No LXD storage pool selected. Run through orchestrate.sh."; return 1; }
        maas_check_kvm || return 1
        maas_check_memory || return 1
        log_info "Creating VM ${MAAS_VM} (${MAAS_VM_CPU} vCPU, ${MAAS_VM_MEMORY_GIB} GiB RAM, ${MAAS_VM_DISK_GIB} GiB disk)."
        maas_lxc launch "$MAAS_VM_IMAGE" "local:${MAAS_VM}" --vm --network "$MAAS_NETWORK" \
            --storage "$LXD_STORAGE_POOL" -c "limits.cpu=${MAAS_VM_CPU}" \
            -c "limits.memory=${MAAS_VM_MEMORY_GIB}GiB" -d "root,size=${MAAS_VM_DISK_GIB}GiB" \
            -c user.lab-automation.component=maas-demo || return 1
    else
        maas_owned instance "$MAAS_VM" || return 1
        if [[ "$(maas_lxc list "local:^${MAAS_VM}$" -c s -f csv)" != "RUNNING" ]]; then
            maas_check_memory || return 1
            maas_lxc start "local:${MAAS_VM}" || return 1
        fi
    fi

    for _ in {1..60}; do
        maas_lxc exec "local:${MAAS_VM}" -- true >/dev/null 2>&1 && break
        sleep 5
    done
    maas_lxc exec "local:${MAAS_VM}" -- true >/dev/null 2>&1 || {
        log_warn "The LXD agent in ${MAAS_VM} did not start within 5 minutes."
        return 1
    }

    MAAS_IP=""
    for _ in {1..60}; do
        MAAS_IP="$(maas_ip 2>/dev/null)" && break
        MAAS_IP=""
        sleep 2
    done
    [[ -n "$MAAS_IP" ]] || { log_warn "No IPv4 address for ${MAAS_VM}."; return 1; }
    # MAAS is initialised with this address, so it must not change on restarts.
    pinned="$(maas_lxc config device get "local:${MAAS_VM}" eth0 ipv4.address)" || return 1
    if [[ -z "$pinned" ]]; then
        maas_lxc config device set "local:${MAAS_VM}" eth0 ipv4.address="$MAAS_IP" || return 1
    elif [[ "$pinned" != "$MAAS_IP" ]]; then
        log_warn "${MAAS_VM} is pinned to ${pinned} but currently uses ${MAAS_IP}; restart it and rerun."
        return 1
    fi
}

maas_run_setup() {
    maas_lxc file push "$MAAS_SETTINGS" "local:${MAAS_VM}/root/maas.env" --mode 0600 || return 1
    maas_lxc file push "${SCRIPT_DIR}/scripts/maas_guest.sh" "local:${MAAS_VM}/root/maas-setup.sh" --mode 0700 || return 1
    log_info "Installing MAAS inside ${MAAS_VM}; this usually takes 10-15 minutes, longer on a slow connection. Output is also saved to ${MAAS_STATE_DIR}/setup.log"
    maas_lxc exec "local:${MAAS_VM}" \
        --env "MAAS_IP=${MAAS_IP}" --env "MAAS_CHANNEL=${MAAS_CHANNEL}" \
        --env "MAAS_LXD_CHANNEL=${MAAS_LXD_CHANNEL}" --env "MAAS_TARGET_COUNT=${MAAS_TARGET_COUNT}" \
        -- bash /root/maas-setup.sh 2>&1 | tee -a "${MAAS_STATE_DIR}/setup.log"
    local -a status=("${PIPESTATUS[@]}")
    if (( status[0] != 0 || status[1] != 0 )); then
        log_warn "MAAS setup or writing setup.log failed."
        return 1
    fi
    maas_lxc file pull "local:${MAAS_VM}/root/maas-access.env" "$MAAS_ACCESS" || return 1
    chmod 600 "$MAAS_ACCESS"
}

maas_check_web() {
    local code
    code="$(curl -sS --noproxy '*' --max-time 10 --location -o /dev/null -w '%{http_code}' \
        "http://${MAAS_IP}:${MAAS_WEB_PORT}/MAAS/")" || code="unreachable"
    if [[ "$code" != "200" ]]; then
        log_warn "http://${MAAS_IP}:${MAAS_WEB_PORT}/MAAS/ is not reachable from this host (HTTP ${code})."
        return 1
    fi
}

maas_print_access() {
    print_section "MAAS demo"
    print_kv "Web UI" "http://${MAAS_IP}:${MAAS_WEB_PORT}/MAAS"
    print_kv "Login" "admin / ${ADMIN_PASSWORD}"
    print_kv "Version" "MAAS ${MAAS_VERSION} (snap channel ${MAAS_CHANNEL})"
    print_kv "Machines" "${MACHINES}"
    print_kv "Instructor shell" "lxc exec ${MAAS_VM} -- bash   (the CLI profile 'admin' is logged in)"
    print_kv "Access" "Browsers on this host only; remote browsers need a route to ${SUBNET_PREFIX}.0/24."
}

maas_install() {
    if [[ ! -f "$MAAS_SETTINGS" ]] && maas_lxc info "local:${MAAS_VM}" >/dev/null 2>&1; then
        log_warn "${MAAS_VM} exists but its saved settings are missing; destroy it from menu 9 first."
        return 1
    fi
    maas_validate_sizing || return 1
    maas_prepare_settings || return 1
    # shellcheck source=/dev/null
    source "$MAAS_SETTINGS"
    maas_ensure_infrastructure || return 1
    if ! maas_run_setup; then
        log_warn "Fix the reported problem and rerun menu 12; existing resources are kept."
        return 1
    fi
    # shellcheck source=/dev/null
    source "$MAAS_ACCESS"
    maas_check_web || return 1
    log_success "MAAS demo is ready."
    maas_print_access
}

maas_installed() {
    [[ -f "$MAAS_SETTINGS" ]] \
        || maas_lxc info "local:${MAAS_VM}" >/dev/null 2>&1 \
        || maas_lxc network show "local:${MAAS_NETWORK}" >/dev/null 2>&1
}

maas_destroy() {
    local vm_exists=false network_exists=false
    if ! maas_lxc info local: >/dev/null 2>&1; then
        log_warn "Local LXD is unavailable; the MAAS demo was not removed."
        return 1
    fi
    if maas_lxc info "local:${MAAS_VM}" >/dev/null 2>&1; then
        vm_exists=true
        maas_owned instance "$MAAS_VM" || return 1
    fi
    if maas_lxc network show "local:${MAAS_NETWORK}" >/dev/null 2>&1; then
        network_exists=true
        maas_owned network "$MAAS_NETWORK" || return 1
    fi
    if [[ "$vm_exists" == "true" ]]; then
        maas_lxc delete --force "local:${MAAS_VM}" || return 1
    fi
    if [[ "$network_exists" == "true" ]]; then
        maas_lxc network delete "local:${MAAS_NETWORK}" || return 1
    fi
    rm -f -- "$MAAS_SETTINGS" "$MAAS_ACCESS" "${MAAS_STATE_DIR}/setup.log" || return 1
    log_success "MAAS demo removed (VM, bridge and saved settings; the machines inside the VM went with it)."
}
