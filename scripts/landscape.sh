#!/bin/bash
# Instructor-only Landscape demo; sourced by orchestrate.sh.

LANDSCAPE_VM="lab-landscape"
LANDSCAPE_CLIENT_PREFIX="lab-landscape-client"
LANDSCAPE_CLIENT_COUNT=3
LANDSCAPE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-automation/landscape"
LANDSCAPE_SETTINGS="${LANDSCAPE_STATE_DIR}/settings.env"

landscape_lxc() { lxc --project default "$@" </dev/null; }

landscape_status() { landscape_lxc list "local:^${1}$" -c s -f csv; }

landscape_owned() {
    local owner
    owner="$(landscape_lxc config get "local:$1" user.lab-automation.component)" || return 1
    if [[ "$owner" != "landscape-demo" ]]; then
        log_warn "$1 is not owned by this Landscape demo; refusing to change it."
        return 1
    fi
}

landscape_prepare_settings() {
    local password key
    mkdir -p "$LANDSCAPE_STATE_DIR" || return 1
    chmod 700 "$LANDSCAPE_STATE_DIR" || return 1
    [[ -f "$LANDSCAPE_SETTINGS" ]] && return 0
    password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')" || return 1
    key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')" || return 1
    (
        umask 077
        printf 'FQDN=%q\nADMIN_EMAIL=%q\nADMIN_PASSWORD=%q\nREGISTRATION_KEY=%q\n' \
            "landscape.demo.internal" "instructor@landscape.internal" \
            "$password" "$key" \
            > "$LANDSCAPE_SETTINGS"
    )
}

landscape_wait_agent() {
    local instance="$1" _
    for _ in {1..84}; do
        landscape_lxc exec "local:${instance}" -- true >/dev/null 2>&1 && return 0
        sleep 5
    done
    log_warn "Timed out waiting for the LXD agent in ${instance}."
    return 1
}

landscape_ip() {
    landscape_lxc list "local:$1" --format json | python3 -c '
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
' "$1"
}

landscape_ensure_instance() {
    local name="$1" kind="$2" _ ip
    local -a options=()
    if landscape_lxc info "local:${name}" >/dev/null 2>&1; then
        landscape_owned "$name" || return 1
        if [[ "$(landscape_status "$name")" != "RUNNING" ]]; then
            landscape_lxc start "local:${name}" || return 1
        fi
    else
        [[ -n "$LXD_NETWORK_NAME" && -n "$LXD_STORAGE_POOL" ]] || {
            log_warn "No LXD network/storage selected. Run through orchestrate.sh."
            return 1
        }
        if [[ "$kind" == "server" ]]; then
            options=(--vm -c limits.cpu=2 -c limits.memory=16GiB -d "root,size=40GiB")
        else
            options=(-c limits.cpu=1 -c limits.memory=512MiB -d "root,size=8GiB")
        fi
        landscape_lxc launch ubuntu:24.04 "local:${name}" \
            --network "$LXD_NETWORK_NAME" --storage "$LXD_STORAGE_POOL" \
            -c user.lab-automation.component=landscape-demo "${options[@]}" || return 1
    fi
    landscape_wait_agent "$name" || return 1
    for _ in {1..60}; do
        if ip="$(landscape_ip "$name" 2>/dev/null)"; then
            break
        fi
        sleep 2
    done
    [[ -n "${ip:-}" ]] || { log_warn "No IPv4 address for ${name}."; return 1; }
    if [[ "$kind" == "server" ]]; then
        # --network creates a local eth0 device; reserve its current DHCP address.
        landscape_lxc config device set "local:${name}" eth0 ipv4.address="$ip" || return 1
    fi
}

landscape_set_memory() {
    local memory="$1" current
    current="$(landscape_lxc config get "local:${LANDSCAPE_VM}" limits.memory)" || return 1
    [[ "$current" == "$memory" ]] && return 0
    # Cold resize avoids LXD ballooning timeouts after the large initial DB import.
    log_info "Restarting ${LANDSCAPE_VM} to set RAM to ${memory}."
    landscape_lxc stop "local:${LANDSCAPE_VM}" --timeout 120 || return 1
    landscape_lxc config set "local:${LANDSCAPE_VM}" limits.memory="$memory" || return 1
    landscape_lxc start "local:${LANDSCAPE_VM}" || return 1
    landscape_wait_agent "$LANDSCAPE_VM"
}

landscape_run_setup() (
    local unit="lab-landscape-setup" result="" status="" offset=0 chunk
    local log="/var/log/lab-landscape-setup.log" deadline=$((SECONDS + 3600))
    chunk="$(mktemp "${LANDSCAPE_STATE_DIR}/output.XXXXXX")" || return 1
    trap 'rm -f -- "$chunk"' EXIT
    offset="$(landscape_lxc exec "local:${LANDSCAPE_VM}" -- bash -c \
        'if [[ -f "$1" ]]; then stat -c %s "$1"; else echo 0; fi' -- "$log")" || return 1

    status="$(landscape_lxc exec "local:${LANDSCAPE_VM}" -- systemctl is-active "$unit" 2>/dev/null)" || :
    if [[ "$status" != "active" && "$status" != "activating" ]]; then
        landscape_lxc exec "local:${LANDSCAPE_VM}" -- rm -f /root/landscape-setup.result || return 1
        landscape_lxc exec "local:${LANDSCAPE_VM}" -- systemd-run \
            --unit="$unit" --collect /bin/bash -c \
            '/root/landscape-setup.sh; result=$?; echo "$result" > /root/landscape-setup.result; exit "$result"' || return 1
    fi
    while (( SECONDS < deadline )); do
        status="$(landscape_lxc exec "local:${LANDSCAPE_VM}" -- systemctl is-active "$unit" 2>/dev/null)" || :
        result="$(landscape_lxc exec "local:${LANDSCAPE_VM}" -- cat /root/landscape-setup.result 2>/dev/null)" || :
        if landscape_lxc exec "local:${LANDSCAPE_VM}" -- \
            tail -c "+$((offset + 1))" "$log" 2>/dev/null | cat > "$chunk"; then
            cat "$chunk"
            offset=$((offset + $(stat -c %s "$chunk")))
        fi
        if [[ -n "$result" ]]; then
            if [[ "$result" == "0" ]]; then
                return 0
            fi
            log_warn "Landscape setup failed (exit ${result}). See ${LANDSCAPE_STATE_DIR}/setup.log and ${log} inside the VM."
            return 1
        fi
        if [[ "$status" == "failed" || "$status" == "inactive" || "$status" == "unknown" ]]; then
            log_warn "Landscape setup stopped unexpectedly. Inspect journalctl -u ${unit} inside the VM."
            return 1
        fi
        sleep 5
    done
    log_warn "Setup monitoring timed out; the guest job may still be running. Rerun menu 10 to reconnect."
    return 1
)

landscape_check_web() {
    local ip="$1" _ code
    for _ in {1..60}; do
        code="$(curl -ksS --max-time 10 --output /dev/null --write-out '%{http_code}' \
            --resolve "${FQDN}:443:${ip}" "https://${FQDN}/")" || code="unreachable"
        [[ "$code" =~ ^(200|301|302|303)$ ]] && return 0
        sleep 5
    done
    log_warn "Landscape HTTPS did not become ready (last response: ${code})."
    return 1
}

landscape_check_services() {
    local _
    for _ in {1..60}; do
        if landscape_lxc exec "local:${LANDSCAPE_VM}" -- bash -c \
            'for service; do systemctl is-active --quiet "$service" || exit 1; done' -- \
            snap.landscape-task-handler.server.service snap.landscape-task-handler.worker.service \
            snap.landscape-outbox.outbox.service; then
            return 0
        fi
        sleep 5
    done
    log_warn "Required Landscape services are not active. Inspect Task Handler and Outbox with 'snap services' inside the VM."
    return 1
}

landscape_setup_client() {
    local ip="$1" client="$2" tmp rc=0
    tmp="$(mktemp -d "${LANDSCAPE_STATE_DIR}/client.XXXXXX")" || return 1
    {
        (
            umask 077
            printf 'FQDN=%q\nSERVER_IP=%q\nREGISTRATION_KEY=%q\nPRO_TOKEN=%q\n' \
                "$FQDN" "$ip" "$REGISTRATION_KEY" "${LANDSCAPE_PRO_TOKEN:-}" > "$tmp/client.env"
        ) &&
        landscape_lxc file pull "local:${LANDSCAPE_VM}/etc/ssl/certs/landscape_server_ca.crt" "$tmp/server.pem" &&
        landscape_lxc file push "$tmp/client.env" "local:${client}/root/landscape-client.env" --mode 0600 &&
        landscape_lxc file push "$tmp/server.pem" "local:${client}/root/landscape-server.pem" --mode 0600 &&
        landscape_lxc file push "${SCRIPT_DIR}/scripts/landscape_client.sh" \
            "local:${client}/root/landscape-client-setup.sh" --mode 0700 &&
        landscape_client_exec "$client"
    } || rc=1
    rm -f -- "$tmp/client.env" "$tmp/server.pem"
    rmdir -- "$tmp"
    return "$rc"
}

landscape_client_exec() {
    # Snap lxc drops exec output when stdout is a regular file; a pipe keeps it working.
    landscape_lxc exec "local:$1" -- bash /root/landscape-client-setup.sh 2>&1 | cat
    return "${PIPESTATUS[0]}"
}

landscape_instances() {
    landscape_lxc list local: user.lab-automation.component=landscape-demo -c n -f csv
}

landscape_install() {
    local ip i client status
    if [[ ! -f "$LANDSCAPE_SETTINGS" ]] && landscape_lxc info "local:${LANDSCAPE_VM}" >/dev/null 2>&1; then
        log_warn "The Landscape instance exists but saved settings are missing; refusing to replace its credentials."
        return 1
    fi
    landscape_prepare_settings || return 1
    # shellcheck source=/dev/null
    source "$LANDSCAPE_SETTINGS"
    landscape_ensure_instance "$LANDSCAPE_VM" server || return 1
    if ! landscape_lxc exec "local:${LANDSCAPE_VM}" -- test -f /var/lib/lab-landscape/ready; then
        log_info "Using 16 GiB RAM during installation; the demo will run with 8 GiB afterwards."
        landscape_set_memory 16GiB || return 1
        status="$(landscape_lxc exec "local:${LANDSCAPE_VM}" -- systemctl is-active lab-landscape-setup 2>/dev/null)" || :
        if [[ "$status" != "active" && "$status" != "activating" ]]; then
            landscape_lxc file push "$LANDSCAPE_SETTINGS" "local:${LANDSCAPE_VM}/root/landscape.env" --mode 0600 || return 1
            landscape_lxc file push "${SCRIPT_DIR}/scripts/landscape_guest.sh" \
                "local:${LANDSCAPE_VM}/root/landscape-setup.sh" --mode 0700 || return 1
        fi
        if ! landscape_run_setup 2>&1 | tee -a "${LANDSCAPE_STATE_DIR}/setup.log"; then
            log_warn "Fix the reported problem and rerun menu 10; existing resources are kept."
            return 1
        fi
    fi
    landscape_set_memory 8GiB || return 1
    ip="$(landscape_ip "$LANDSCAPE_VM")" || return 1
    landscape_check_web "$ip" || return 1
    landscape_check_services || return 1
    for i in $(seq 1 "$LANDSCAPE_CLIENT_COUNT"); do
        client="${LANDSCAPE_CLIENT_PREFIX}-${i}"
        log_info "Registering ${client}"
        landscape_ensure_instance "$client" client || return 1
        landscape_setup_client "$ip" "$client" || return 1
    done
    log_success "Landscape 26.04 demo is ready."
    print_section "Landscape demo"
    print_kv "URL" "https://${FQDN}/ (self-signed certificate)"
    print_kv "Login" "${ADMIN_EMAIL} / ${ADMIN_PASSWORD}"
    print_kv "Browser /etc/hosts" "${ip} ${FQDN}"
    print_kv "Registered clients" "${LANDSCAPE_CLIENT_PREFIX}-1..${LANDSCAPE_CLIENT_COUNT}"
}

landscape_destroy() {
    local instances instance
    instances="$(landscape_instances)" || {
        log_warn "Could not list Landscape demo instances; nothing was removed."
        return 1
    }
    for instance in $instances; do
        landscape_lxc delete --force "local:${instance}" || return 1
    done
    rm -f -- "$LANDSCAPE_SETTINGS" "${LANDSCAPE_STATE_DIR}/setup.log" || return 1
    log_success "Landscape demo removed."
}
