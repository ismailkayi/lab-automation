#!/bin/bash
# Instructor-only Landscape demo; sourced by orchestrate.sh.

LANDSCAPE_VM="lab-landscape"
LANDSCAPE_FQDN="landscape.demo.internal"
LANDSCAPE_CLIENT_PREFIX="lab-landscape-client"
LANDSCAPE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-automation/landscape"
LANDSCAPE_SETTINGS="${LANDSCAPE_STATE_DIR}/settings.env"

landscape_lxc() { lxc --project default "$@" </dev/null; }

# Runs inside an instance; prints "not attached", "attached; enabled: ..." or, with "detach", "detached".
LANDSCAPE_PRO_PY='
import json, subprocess, sys
def api(endpoint):
    out = subprocess.run(["pro", "api", endpoint], capture_output=True, text=True, check=True).stdout
    return json.loads(out)["data"]["attributes"]
if not api("u.pro.status.is_attached.v1")["is_attached"]:
    print("not attached")
elif sys.argv[1:] == ["detach"]:
    subprocess.run(["pro", "detach", "--assume-yes"], capture_output=True, check=True)
    print("detached")
else:
    names = [s["name"] for s in api("u.pro.status.enabled_services.v1")["enabled_services"]]
    print("attached; enabled: " + (", ".join(names) or "none"))
'

landscape_pro() { landscape_lxc exec "local:$1" -- python3 -c "$LANDSCAPE_PRO_PY" "${@:2}"; }

# Asked once per run; an exported LANDSCAPE_PRO_TOKEN (even empty) skips the question.
landscape_read_pro_token() {
    local token=""
    [[ -n "${LANDSCAPE_PRO_TOKEN+set}" ]] && return 0
    echo "An Ubuntu Pro token attaches the demo clients and enables ESM Infra and ESM Apps."
    echo "A free personal token (up to 5 machines) is available at https://ubuntu.com/pro."
    read -r -p "Ubuntu Pro token (press Enter to skip): " token || token=""
    LANDSCAPE_PRO_TOKEN="${token//[[:space:]]/}"
}

landscape_status() { landscape_lxc list "local:^${1}$" -c s -f csv; }

landscape_owned() {
    local owner
    owner="$(landscape_lxc config get "local:$1" user.lab-automation.component)" || return 1
    if [[ "$owner" != "landscape-demo" ]]; then
        log_warn "$1 is not owned by this Landscape demo; refusing to change it."
        return 1
    fi
}

# Letters and digits only: a leading "-" would be parsed as an option by bootstrap-account.
landscape_random_secret() {
    python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(24)))'
}

landscape_prepare_settings() {
    local password key
    mkdir -p "$LANDSCAPE_STATE_DIR" || return 1
    chmod 700 "$LANDSCAPE_STATE_DIR" || return 1
    [[ -f "$LANDSCAPE_SETTINGS" ]] && return 0
    password="$(landscape_random_secret)" || return 1
    key="$(landscape_random_secret)" || return 1
    (
        umask 077
        printf 'FQDN=%q\nADMIN_EMAIL=%q\nADMIN_PASSWORD=%q\nREGISTRATION_KEY=%q\n' \
            "$LANDSCAPE_FQDN" "instructor@landscape.internal" \
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
    local name="$1" kind="$2" image="$3" _ ip
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
            options=(--vm -c limits.cpu=2 -c limits.memory=8GiB -d "root,size=40GiB")
        else
            options=(-c limits.cpu=1 -c limits.memory=512MiB -d "root,size=8GiB")
        fi
        landscape_lxc launch "$image" "local:${name}" \
            --network "$LXD_NETWORK_NAME" --storage "$LXD_STORAGE_POOL" \
            -c user.lab-automation.component=landscape-demo "${options[@]}" || return 1
    fi
    landscape_wait_agent "$name" || return 1
    [[ "$kind" == "server" ]] || return 0
    for _ in {1..60}; do
        if ip="$(landscape_ip "$name" 2>/dev/null)"; then
            break
        fi
        sleep 2
    done
    [[ -n "${ip:-}" ]] || { log_warn "No IPv4 address for ${name}."; return 1; }
    # Keep the advertised browser URL stable across server restarts.
    landscape_lxc config device set "local:${name}" eth0 ipv4.address="$ip"
}

landscape_run_setup() {
    local ip="$1"
    local -a versions=()
    version_env_args versions LANDSCAPE_
    landscape_lxc file push "$LANDSCAPE_SETTINGS" "local:${LANDSCAPE_VM}/root/landscape.env" --mode 0600 || return 1
    landscape_lxc file push "${SCRIPT_DIR}/scripts/landscape_guest.sh" \
        "local:${LANDSCAPE_VM}/root/landscape-setup.sh" --mode 0700 || return 1
    log_info "Installing or checking the Landscape server; output is also saved to ${LANDSCAPE_STATE_DIR}/setup.log"
    landscape_lxc exec "local:${LANDSCAPE_VM}" --env "SERVER_IP=${ip}" "${versions[@]}" -- bash /root/landscape-setup.sh 2>&1 \
        | tee -a "${LANDSCAPE_STATE_DIR}/setup.log"
    local -a status=("${PIPESTATUS[@]}")
    if (( status[0] != 0 || status[1] != 0 )); then
        log_warn "Landscape setup or writing setup.log failed."
        return 1
    fi
}

landscape_check_web() {
    local ip="$1" _ response
    for _ in {1..60}; do
        response="$(curl -ksS --noproxy "$ip" --connect-timeout 5 --max-time 10 \
            --location --max-redirs 5 --output /dev/null --write-out '%{http_code} %{remote_ip}' \
            "https://${ip}/")" || response="unreachable"
        [[ "$response" == "200 ${ip}" ]] && return 0
        sleep 5
    done
    log_warn "Landscape at https://${ip}/ did not become ready (last HTTP status and peer: ${response})."
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
    local ip release client pro missing_pro=0
    local -a clients=() releases=()
    if [[ ! -f "$LANDSCAPE_SETTINGS" ]] && landscape_lxc info "local:${LANDSCAPE_VM}" >/dev/null 2>&1; then
        log_warn "The Landscape instance exists but saved settings are missing; refusing to replace its credentials."
        return 1
    fi
    landscape_prepare_settings || return 1
    landscape_read_pro_token
    # shellcheck source=/dev/null
    source "$LANDSCAPE_SETTINGS"
    landscape_ensure_instance "$LANDSCAPE_VM" server "$LANDSCAPE_VM_IMAGE" || return 1
    # One client per Ubuntu release gives the demo a mixed inventory. Clients boot while the server installs.
    IFS=, read -r -a releases <<< "$LANDSCAPE_CLIENT_RELEASES"
    for release in "${releases[@]}"; do
        client="${LANDSCAPE_CLIENT_PREFIX}-${release//./}"
        landscape_ensure_instance "$client" client "ubuntu:${release}" || return 1
        clients+=("$client")
    done
    ip="$(landscape_ip "$LANDSCAPE_VM")" || return 1
    if ! landscape_run_setup "$ip"; then
        log_warn "Fix the reported problem and rerun menu 10; existing resources are kept."
        return 1
    fi
    landscape_check_web "$ip" || return 1
    for client in "${clients[@]}"; do
        log_info "Registering ${client}"
        landscape_setup_client "$ip" "$client" || return 1
    done
    log_success "Landscape ${LANDSCAPE_RELEASE} demo is ready."
    print_section "Landscape demo"
    print_kv "URL" "https://${ip}/ (accept the private demo's self-signed certificate)"
    print_kv "Login" "${ADMIN_EMAIL} / ${ADMIN_PASSWORD}"
    print_kv "Server IP" "$ip"
    print_kv "Access" "Use the IP URL above; no hosts entry is needed. Remote browsers need the lab VPN/tunnel."
    print_kv "Registered clients" "${clients[*]}"
    for client in "${clients[@]}"; do
        pro="$(landscape_pro "$client" 2>/dev/null)" || pro="status unknown"
        [[ "$pro" == "not attached" ]] && missing_pro=1
        print_kv "Pro ${client}" "$pro"
    done
    if [[ -z "${LANDSCAPE_PRO_TOKEN:-}" ]] && (( missing_pro )); then
        print_kv "Ubuntu Pro" "no token entered; unattached clients may lack inventory and management actions. Rerun menu 10 to add one."
    fi
}

landscape_destroy() {
    local instances instance
    instances="$(landscape_instances)" || {
        log_warn "Could not list Landscape demo instances; nothing was removed."
        return 1
    }
    for instance in $instances; do
        # Detach first so deleted demo machines do not keep using Pro token seats.
        case "$(landscape_pro "$instance" detach 2>/dev/null)" in
            detached) log_info "Ubuntu Pro detached from ${instance}." ;;
            "not attached") ;;
            *) log_warn "Could not check Ubuntu Pro on ${instance}; if it was attached, remove it at https://ubuntu.com/pro/dashboard." ;;
        esac
        landscape_lxc delete --force "local:${instance}" || return 1
    done
    rm -f -- "$LANDSCAPE_SETTINGS" "${LANDSCAPE_STATE_DIR}/setup.log" || return 1
    log_success "Landscape demo removed."
}
