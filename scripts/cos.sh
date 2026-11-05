#!/bin/bash
# Instructor-only COS Lite demo; sourced by orchestrate.sh. COS runs in one VM
# on its own bridge and monitors this host's LXD (metrics and events).

COS_VM="lab-cos"
COS_NETWORK="lab-cosbr0"
COS_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-automation/cos"
COS_SETTINGS="${COS_STATE_DIR}/settings.env"
COS_ACCESS="${COS_STATE_DIR}/access.env"
COS_METRICS_PORT=8444

cos_lxc() { lxc --project default "$@" </dev/null; }

cos_owned() {
    local kind="$1" name="$2" owner
    if [[ "$kind" == "network" ]]; then
        owner="$(cos_lxc network get "local:${name}" user.lab-automation.component)" || return 1
    else
        owner="$(cos_lxc config get "local:${name}" user.lab-automation.component)" || return 1
    fi
    if [[ "$owner" != "cos-demo" ]]; then
        log_warn "${name} is not owned by the COS demo; refusing to change it."
        return 1
    fi
}

cos_prepare_settings() {
    local subnet
    mkdir -p "$COS_STATE_DIR" || return 1
    chmod 700 "$COS_STATE_DIR" || return 1
    [[ -f "$COS_SETTINGS" ]] && return 0
    subnet="$(cm_pick_subnet_prefix)" || { log_warn "Could not choose a free subnet for ${COS_NETWORK}."; return 1; }
    (
        umask 077
        printf 'SUBNET_PREFIX=%q\n' "$subnet" > "$COS_SETTINGS"
    )
}

cos_ensure_infrastructure() {
    local _
    if ! cos_lxc network show "local:${COS_NETWORK}" >/dev/null 2>&1; then
        log_info "Creating bridge ${COS_NETWORK} (${SUBNET_PREFIX}.0/24)."
        cos_lxc network create "local:${COS_NETWORK}" \
            ipv4.address="${SUBNET_PREFIX}.1/24" ipv4.nat=true ipv6.address=none \
            ipv4.dhcp.ranges="${SUBNET_PREFIX}.10-${SUBNET_PREFIX}.99" \
            user.lab-automation.component=cos-demo || return 1
    else
        cos_owned network "$COS_NETWORK" || return 1
    fi

    if ! cos_lxc info "local:${COS_VM}" >/dev/null 2>&1; then
        [[ -n "$LXD_STORAGE_POOL" ]] || { log_warn "No LXD storage pool selected. Run through orchestrate.sh."; return 1; }
        log_info "Creating VM ${COS_VM} (4 vCPU, 12 GiB RAM, 60 GiB disk)."
        cos_lxc launch ubuntu:24.04 "local:${COS_VM}" --vm --network "$COS_NETWORK" \
            --storage "$LXD_STORAGE_POOL" -c limits.cpu=4 -c limits.memory=12GiB \
            -d root,size=60GiB -c user.lab-automation.component=cos-demo || return 1
    else
        cos_owned instance "$COS_VM" || return 1
        if [[ "$(cos_lxc list "local:${COS_VM}" -c s -f csv)" != "RUNNING" ]]; then
            cos_lxc start "local:${COS_VM}" || return 1
        fi
    fi

    for _ in {1..60}; do
        cos_lxc exec "local:${COS_VM}" -- true >/dev/null 2>&1 && return 0
        sleep 5
    done
    log_warn "The LXD agent in ${COS_VM} did not start within 5 minutes."
    return 1
}

cos_host_check() {
    local key="$1" value="$2" current
    current="$(cos_lxc config get local: "$key")" || return 1
    if [[ -n "$current" && "$current" != "$value" ]]; then
        log_warn "Host LXD ${key} is already '${current}'; unset it to use the COS demo, then rerun menu 11."
        return 1
    fi
}

# Record only values we change from unset; equal pre-existing values are not ours.
cos_host_set() {
    local key="$1" value="$2" current
    cos_host_check "$key" "$value" || return 1
    current="$(cos_lxc config get local: "$key")" || return 1
    [[ "$current" == "$value" ]] && return 0
    [[ -z "$current" ]] || { log_warn "Host LXD ${key} changed during setup; rerun menu 11."; return 1; }
    (
        umask 077
        mkdir -p "${COS_STATE_DIR}/host-config" &&
            printf '%s\n' "$value" > "${COS_STATE_DIR}/host-config/${key}"
    ) || return 1
    if ! cos_lxc config set local: "${key}=${value}"; then
        rm -f -- "${COS_STATE_DIR}/host-config/${key}" || return 1
        return 1
    fi
}

cos_metrics_address() { echo "${SUBNET_PREFIX}.1:${COS_METRICS_PORT}"; }
cos_loki_url() { echo "http://${SUBNET_PREFIX}.200/cos-loki-0"; }

# Binding to the COS bridge limits exposure; it is not a firewall rule.
cos_enable_host_metrics() {
    local address authentication saved_address=""
    cos_host_check core.metrics_address "$(cos_metrics_address)" || return 1
    cos_host_check core.metrics_authentication false || return 1
    address="$(cos_lxc config get local: core.metrics_address)" || return 1
    authentication="$(cos_lxc config get local: core.metrics_authentication)" || return 1
    # LXD can omit an explicit true because it is the default. Only a partial
    # demo install may finish configuring an existing, authenticated listener.
    if [[ -n "$address" && -z "$authentication" ]]; then
        if [[ -f "${COS_STATE_DIR}/host-config/core.metrics_address" ]]; then
            saved_address="$(cat "${COS_STATE_DIR}/host-config/core.metrics_address")" || return 1
        fi
        if [[ "$address" != "$saved_address" || -f "${COS_STATE_DIR}/host-config/core.metrics_authentication" ]]; then
            log_warn "Host LXD core.metrics_authentication defaults to true for the existing metrics endpoint; refusing to disable it."
            return 1
        fi
    fi
    cos_host_set core.metrics_address "$(cos_metrics_address)" || return 1
    cos_host_set core.metrics_authentication false
}

# The LXD dashboard filters Loki events by instance="<Prometheus job>".
cos_enable_host_logs() {
    local _
    cos_host_check loki.api.url "$(cos_loki_url)" || return 1
    cos_host_check loki.instance "$LXD_JOB" || return 1
    cos_host_set loki.instance "$LXD_JOB" || return 1
    # LXD checks Loki's /ready only once, and Loki is briefly not ready after a restart.
    for _ in {1..12}; do
        cos_host_set loki.api.url "$(cos_loki_url)" && return 0
        sleep 10
    done
    log_warn "Host LXD could not reach Loki at $(cos_loki_url)/ready; rerun menu 11."
    return 1
}

cos_disable_host_monitoring() {
    local key saved current record
    if [[ ! -d "${COS_STATE_DIR}/host-config" ]]; then
        log_warn "No saved COS ownership record; host LXD monitoring settings are left unchanged."
        return 0
    fi
    for key in loki.api.url loki.instance core.metrics_address core.metrics_authentication; do
        record="${COS_STATE_DIR}/host-config/${key}"
        [[ -f "$record" ]] || continue
        saved="$(cat "$record")" || return 1
        [[ -n "$saved" ]] || { log_warn "Empty COS ownership record for ${key}; refusing cleanup."; return 1; }
        current="$(cos_lxc config get local: "$key")" || return 1
        if [[ "$current" == "$saved" ]]; then
            cos_lxc config unset local: "$key" || return 1
        elif [[ -n "$current" ]]; then
            log_warn "Host LXD ${key} changed since COS configured it; leaving it unchanged."
        fi
        rm -f -- "$record" || return 1
    done
    rmdir -- "${COS_STATE_DIR}/host-config"
}

cos_run_setup() {
    cos_lxc file push "$COS_SETTINGS" "local:${COS_VM}/root/cos.env" --mode 0600 || return 1
    cos_lxc file push "${SCRIPT_DIR}/scripts/cos_guest.sh" "local:${COS_VM}/root/cos-setup.sh" --mode 0700 || return 1
    log_info "Installing COS Lite inside ${COS_VM}; output is also saved to ${COS_STATE_DIR}/setup.log"
    cos_lxc exec "local:${COS_VM}" -- bash /root/cos-setup.sh 2>&1 | tee -a "${COS_STATE_DIR}/setup.log"
    local -a status=("${PIPESTATUS[@]}")
    if (( status[0] != 0 || status[1] != 0 )); then
        log_warn "COS setup or writing setup.log failed."
        return 1
    fi
    cos_lxc file pull "local:${COS_VM}/root/cos-access.env" "$COS_ACCESS" || return 1
    chmod 600 "$COS_ACCESS"
}

cos_check_web() {
    local path code
    for path in cos-catalogue cos-grafana/api/health; do
        code="$(curl -sS --noproxy '*' --max-time 10 -o /dev/null -w '%{http_code}' \
            "http://${COS_IP}/${path}")" || code="unreachable"
        if [[ "$code" != "200" ]]; then
            log_warn "http://${COS_IP}/${path} is not reachable from this host (HTTP ${code})."
            return 1
        fi
    done
}

cos_print_access() {
    print_section "COS Lite demo"
    print_kv "Catalogue" "http://${COS_IP}/cos-catalogue"
    print_kv "Grafana" "http://${COS_IP}/cos-grafana"
    print_kv "Grafana login" "admin / ${GRAFANA_PASSWORD}"
    print_kv "LXD dashboard" "http://${COS_IP}${DASHBOARD_PATH}"
    print_kv "Prometheus" "http://${COS_IP}/cos-prometheus-0"
    print_kv "Alertmanager" "http://${COS_IP}/cos-alertmanager"
    print_kv "Monitored" "this host's LXD: metrics from $(cos_metrics_address), events to Loki"
    print_kv "Access" "Browsers on this host only; remote browsers need a route to ${SUBNET_PREFIX}.0/24."
}

cos_install() {
    if [[ ! -f "$COS_SETTINGS" ]] && cos_lxc info "local:${COS_VM}" >/dev/null 2>&1; then
        log_warn "${COS_VM} exists but its saved settings are missing; destroy it from menu 8 first."
        return 1
    fi
    cos_prepare_settings || return 1
    # shellcheck source=/dev/null
    source "$COS_SETTINGS"
    cos_ensure_infrastructure || return 1
    cos_enable_host_metrics || return 1
    if ! cos_run_setup; then
        log_warn "Fix the reported problem and rerun menu 11; existing resources are kept."
        return 1
    fi
    # shellcheck source=/dev/null
    source "$COS_ACCESS"
    cos_enable_host_logs || return 1
    cos_check_web || return 1
    log_success "COS Lite demo is ready."
    cos_print_access
}

cos_installed() {
    [[ -f "$COS_SETTINGS" || -d "${COS_STATE_DIR}/host-config" ]] \
        || cos_lxc info "local:${COS_VM}" >/dev/null 2>&1 \
        || cos_lxc network show "local:${COS_NETWORK}" >/dev/null 2>&1
}

cos_destroy() {
    local vm_exists=false network_exists=false
    if ! cos_lxc info local: >/dev/null 2>&1; then
        log_warn "Local LXD is unavailable; the COS demo and its host settings were not removed."
        return 1
    fi
    if cos_lxc info "local:${COS_VM}" >/dev/null 2>&1; then
        vm_exists=true
        cos_owned instance "$COS_VM" || return 1
    fi
    if cos_lxc network show "local:${COS_NETWORK}" >/dev/null 2>&1; then
        network_exists=true
        cos_owned network "$COS_NETWORK" || return 1
    fi
    cos_disable_host_monitoring || return 1
    if [[ "$vm_exists" == "true" ]]; then
        cos_lxc delete --force "local:${COS_VM}" || return 1
    fi
    if [[ "$network_exists" == "true" ]]; then
        cos_lxc network delete "local:${COS_NETWORK}" || return 1
    fi
    rm -f -- "$COS_SETTINGS" "$COS_ACCESS" "${COS_STATE_DIR}/setup.log" || return 1
    log_success "COS Lite demo removed; only unchanged host LXD settings recorded by this demo were reset."
}
