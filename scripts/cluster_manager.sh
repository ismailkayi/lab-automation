#!/bin/bash
# Instructor Cluster Manager service. Sourced by orchestrate.sh, which provides
# log_info/log_warn/log_success/print_section/print_kv.

CM_VM="lab-cluster-manager"
CM_NETWORK="lab-cmbr0"
CM_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-automation/cluster-manager"
CM_SETTINGS="${CM_STATE_DIR}/settings.env"
CM_GUEST_SCRIPT="${SCRIPT_DIR}/scripts/cluster_manager_guest.sh"

cm_lxc() { lxc --project default "$@" </dev/null; }

# Prints the first 172.31.X.0/24 prefix (e.g. 172.31.0) that does not overlap
# host routes or LXD networks. 172.30.0.0/16 is used by MicroCloud uplinks.
# Extra arguments are CIDRs that must be avoided as well, for subnets that are
# chosen together but not created yet.
cm_pick_subnet_prefix() {
    local routes networks
    routes="$(ip -j -4 route show table all)" || return 1
    networks="$(lxc network list local: --all-projects --format json)" || return 1
    python3 - "$routes" "$networks" "$@" <<'PY'
import ipaddress, json, sys
used = [ipaddress.ip_network(extra, strict=False) for extra in sys.argv[3:]]
for route in json.loads(sys.argv[1]):
    if route.get("dst", "default") != "default":
        used.append(ipaddress.ip_network(route["dst"], strict=False))
for network in json.loads(sys.argv[2]):
    config = network.get("config") or {}
    for key in ("ipv4.address", "ipv4.routes", "user.lab-automation.cidr"):
        for value in config.get(key, "").split(","):
            try:
                used.append(ipaddress.ip_network(value.strip(), strict=False))
            except ValueError:
                pass
for third in range(256):
    candidate = ipaddress.ip_network(f"172.31.{third}.0/24")
    if not any(candidate.overlaps(net) for net in used if net.version == 4):
        print(f"172.31.{third}")
        break
else:
    sys.exit("No free 172.31.X.0/24 subnet found")
PY
}

# Letters and digits only: a leading "-" would be parsed as an option by kcadm.
cm_random_password() {
    python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(24)))'
}

# Creates the settings file on first use; afterwards only the participant count can grow.
cm_prepare_settings() {
    local prefix count current subnet
    mkdir -p "$CM_STATE_DIR"
    chmod 700 "$CM_STATE_DIR"
    if [[ -f "$CM_SETTINGS" ]]; then
        # shellcheck source=/dev/null
        source "$CM_SETTINGS"
        current="$PARTICIPANT_COUNT"
        read -r -p "Number of participant accounts [current: ${current}]: " count
        count="${count:-$current}"
        if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < current || count > 50 )); then
            log_warn "Enter a number between ${current} and 50; existing accounts are never removed."
            return 1
        fi
        sed -i "s/^PARTICIPANT_COUNT=.*/PARTICIPANT_COUNT=${count}/" "$CM_SETTINGS"
        return 0
    fi

    read -r -p "Participant username prefix [student]: " prefix
    prefix="${prefix:-student}"
    if ! [[ "$prefix" =~ ^[a-z][a-z0-9-]{0,20}$ ]]; then
        log_warn "Use lowercase letters, digits and hyphens, starting with a letter."
        return 1
    fi
    read -r -p "Number of participant accounts [12]: " count
    count="${count:-12}"
    if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < 1 || count > 50 )); then
        log_warn "Enter a number between 1 and 50."
        return 1
    fi
    subnet="$(cm_pick_subnet_prefix)" || { log_warn "Could not choose a free service subnet."; return 1; }
    (
        umask 077
        cat > "$CM_SETTINGS" <<EOF
SUBNET_PREFIX=${subnet}
PARTICIPANT_PREFIX=${prefix}
PARTICIPANT_COUNT=${count}
INSTRUCTOR_PASSWORD=$(cm_random_password)
KEYCLOAK_ADMIN_PASSWORD=$(cm_random_password)
OIDC_CLIENT_SECRET=$(cm_random_password)
EOF
    )
}

cm_ensure_infrastructure() {
    # shellcheck source=/dev/null
    source "$CM_SETTINGS"
    if ! cm_lxc network show "local:${CM_NETWORK}" >/dev/null 2>&1; then
        log_info "Creating bridge ${CM_NETWORK} (${SUBNET_PREFIX}.0/24)."
        cm_lxc network create "local:${CM_NETWORK}" \
            ipv4.address="${SUBNET_PREFIX}.1/24" ipv4.nat=true ipv6.address=none \
            ipv4.dhcp.ranges="${SUBNET_PREFIX}.10-${SUBNET_PREFIX}.99" \
            user.lab-automation.component=cluster-manager || return 1
    elif [[ "$(cm_lxc network get "local:${CM_NETWORK}" ipv4.address)" != "${SUBNET_PREFIX}.1/24" ]]; then
        log_warn "Bridge ${CM_NETWORK} exists with a different subnet; refusing to continue."
        return 1
    fi

    if ! cm_lxc info "local:${CM_VM}" >/dev/null 2>&1; then
        local available_gib
        available_gib=$(awk '/MemAvailable:/ {print int($2 / 1048576)}' /proc/meminfo)
        if (( available_gib < 16 )); then
            log_warn "Only ${available_gib} GiB RAM is currently available; the service VM uses 12 GiB."
            read -r -p "Continue anyway? [y/N]: " answer
            [[ "${answer,,}" == "y" ]] || return 1
        fi
        log_info "Creating VM ${CM_VM} (6 vCPU, 12 GiB RAM, 80 GiB disk)."
        cm_lxc launch ubuntu:24.04 "local:${CM_VM}" --vm --network "$CM_NETWORK" \
            -c limits.cpu=6 -c limits.memory=12GiB -d root,size=80GiB \
            -c user.lab-automation.component=cluster-manager || return 1
    elif [[ "$(cm_lxc list "local:${CM_VM}" -c s -f csv)" != "RUNNING" ]]; then
        cm_lxc start "local:${CM_VM}" || return 1
    fi

    log_info "Waiting for the VM agent."
    local _
    for _ in $(seq 1 60); do
        cm_lxc exec "local:${CM_VM}" -- true >/dev/null 2>&1 && return 0
        sleep 5
    done
    log_warn "The VM agent did not start within 5 minutes."
    return 1
}

cm_write_access_files() {
    # shellcheck source=/dev/null
    source "$CM_SETTINGS"
    local number username csv="${CM_STATE_DIR}/participant-access.csv"
    local manager="https://${SUBNET_PREFIX}.220" keycloak="http://${SUBNET_PREFIX}.210:8080"
    (
        umask 077
        echo "username,password,cluster_manager_url,keycloak_url" > "$csv"
        for number in $(seq 1 "$PARTICIPANT_COUNT"); do
            username="$(printf '%s%02d' "$PARTICIPANT_PREFIX" "$number")"
            echo "${username},admingroup${number},${manager},${keycloak}" >> "$csv"
        done
        cat > "${CM_STATE_DIR}/instructor-access.txt" <<EOF
Cluster Manager:  ${manager}
Instructor login: instructor / ${INSTRUCTOR_PASSWORD}
Keycloak admin:   ${keycloak}/admin/  lab-admin / ${KEYCLOAK_ADMIN_PASSWORD}
EOF
    )
}

cm_install() {
    cm_prepare_settings || return 1
    cm_ensure_infrastructure || return 1
    cm_lxc file push "$CM_SETTINGS" "local:${CM_VM}/root/cluster-manager.env" --mode 0600 || return 1
    cm_lxc file push "$CM_GUEST_SCRIPT" "local:${CM_VM}/root/cluster-manager-setup.sh" --mode 0700 || return 1

    log_info "Installing inside the VM; output is also saved to ${CM_STATE_DIR}/setup.log"
    if ! cm_lxc exec "local:${CM_VM}" -- bash /root/cluster-manager-setup.sh 2>&1 \
        | tee -a "${CM_STATE_DIR}/setup.log"; then
        log_warn "Installation stopped. Rerun 'Install / resume' after fixing the reported problem."
        return 1
    fi
    cm_write_access_files
    log_success "Cluster Manager is ready."
    cm_show_access
}

cm_show_access() {
    if [[ ! -f "${CM_STATE_DIR}/instructor-access.txt" ]]; then
        log_warn "Cluster Manager has not completed installation yet."
        return 1
    fi
    print_section "Cluster Manager access"
    cat "${CM_STATE_DIR}/instructor-access.txt"
    echo ""
    print_kv "Participant list" "${CM_STATE_DIR}/participant-access.csv"
    log_warn "HTTP Keycloak and simple passwords: use only on the private lab network/VPN."
}

cm_installed() {
    [[ -f "$CM_SETTINGS" ]] || cm_lxc info "local:${CM_VM}" >/dev/null 2>&1 \
        || cm_lxc network show "local:${CM_NETWORK}" >/dev/null 2>&1
}

cm_remove() {
    local vm_exists=false network_exists=false
    if ! cm_lxc info local: >/dev/null 2>&1; then
        log_warn "Local LXD is unavailable; Cluster Manager resources and credentials were not removed."
        return 1
    fi
    if cm_lxc info "local:${CM_VM}" >/dev/null 2>&1; then
        vm_exists=true
        if [[ "$(cm_lxc config get "local:${CM_VM}" user.lab-automation.component)" != "cluster-manager" ]]; then
            log_warn "${CM_VM} is not owned by the Cluster Manager deployment; nothing was removed."
            return 1
        fi
    fi
    if cm_lxc network show "local:${CM_NETWORK}" >/dev/null 2>&1; then
        network_exists=true
        if [[ "$(cm_lxc network get "local:${CM_NETWORK}" user.lab-automation.component)" != "cluster-manager" ]]; then
            log_warn "${CM_NETWORK} is not owned by the Cluster Manager deployment; nothing was removed."
            return 1
        fi
    fi
    if [[ "$vm_exists" == "true" ]]; then
        cm_lxc delete --force "local:${CM_VM}" || return 1
    fi
    if [[ "$network_exists" == "true" ]]; then
        cm_lxc network delete "local:${CM_NETWORK}" || return 1
    fi
    rm -f -- "$CM_SETTINGS" "${CM_STATE_DIR}/participant-access.csv" \
        "${CM_STATE_DIR}/instructor-access.txt" "${CM_STATE_DIR}/setup.log" || return 1
    log_success "Cluster Manager service removed."
}

cm_destroy_warning() {
    log_warn "This deletes ${CM_VM}, bridge ${CM_NETWORK} and the stored credentials."
    log_warn "Participant labs are not touched, but their Cluster Manager registration stops working."
}

cm_destroy() {
    local answer
    cm_destroy_warning
    read -r -p "Type 'destroy' to continue: " answer
    [[ "$answer" == "destroy" ]] || { echo "Cancelled."; return 0; }
    cm_remove
}

cluster_manager_menu() {
    local choice
    print_section "Cluster Manager (one shared instructor service per host)"
    echo "  1) Install / resume / add participant accounts"
    echo "  2) Show access"
    echo "  3) Destroy Cluster Manager service"
    echo "  0) Cancel"
    echo ""
    read -r -p "Select: " choice
    case "$choice" in
        1) cm_install ;;
        2) cm_show_access ;;
        3) cm_destroy ;;
        *) echo "Cancelled." ;;
    esac
}
