#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../orchestrate.sh
source "${REPO_ROOT}/orchestrate.sh"
TMP="$(mktemp -d)"
trap 'rm -f -- "$TMP/settings.env" "$TMP/settings.bak" "$TMP/calls" "$TMP/setup.log" "$TMP/cm.env"; rmdir -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "Expected '$2' in '$1'"; }

export LANDSCAPE_STATE_DIR="$TMP"
LANDSCAPE_SETTINGS="$TMP/settings.env"
lxc() { fail "Unexpected real LXD call: $*"; }
sudo() { fail "Landscape deployment must not need to modify the host"; }
landscape_prepare_settings
[[ "$(stat -c %a "$TMP")" == "700" ]] || fail "State directory must be private"
[[ "$(stat -c %a "$LANDSCAPE_SETTINGS")" == "600" ]] || fail "Settings must be private"
original="$(cat "$LANDSCAPE_SETTINGS")"
landscape_prepare_settings
[[ "$(cat "$LANDSCAPE_SETTINGS")" == "$original" ]] || fail "Resume changed credentials"
# shellcheck source=/dev/null
source "$LANDSCAPE_SETTINGS"
[[ -n "$ADMIN_PASSWORD" && -n "$REGISTRATION_KEY" ]] || fail "Missing generated credentials"

for _ in $(seq 200); do
    [[ "$(landscape_random_secret)" =~ ^[A-Za-z0-9]{24}$ ]] || fail "Landscape secrets must be alphanumeric"
    [[ "$(cm_random_password)" =~ ^[A-Za-z0-9]{24}$ ]] || fail "Cluster Manager secrets must be alphanumeric"
done
grep -q -- '--admin_password="$ADMIN_PASSWORD" --registration_key="$REGISTRATION_KEY"' \
    "${REPO_ROOT}/scripts/landscape_guest.sh" || fail "bootstrap-account must bind secrets with ="
grep -q -- '--registration-key="$REGISTRATION_KEY"' "${REPO_ROOT}/scripts/landscape_client.sh" ||
    fail "landscape-config must bind the registration key with ="

(
    unset LANDSCAPE_PRO_TOKEN
    landscape_read_pro_token <<< "  C1abc 123  " >/dev/null
    [[ "$LANDSCAPE_PRO_TOKEN" == "C1abc123" ]] || fail "Token must be read once with whitespace removed"
    landscape_read_pro_token <<< "second" >/dev/null
    [[ "$LANDSCAPE_PRO_TOKEN" == "C1abc123" ]] || fail "Token must not be asked twice"
    unset LANDSCAPE_PRO_TOKEN
    landscape_read_pro_token < /dev/null >/dev/null
    [[ -z "$LANDSCAPE_PRO_TOKEN" ]] || fail "Enter/EOF must skip the token"
    LANDSCAPE_PRO_TOKEN=""
    output="$(landscape_read_pro_token <<< "unexpected")"
    [[ -z "$output" ]] || fail "An exported (even empty) token must skip the question"
)

# Run the real client script with stub commands to check the Pro paths.
run_client_script() {
    local dir="$1" token="$2"
    printf 'FQDN=demo\nSERVER_IP=10.1.1.2\nREGISTRATION_KEY=key\nPRO_TOKEN=%q\n' "$token" > "$dir/root/landscape-client.env"
    echo cert > "$dir/root/landscape-server.pem"
    : > "$dir/calls"
    rm -f "$dir/registered"
    sed -e "s#/root/#${dir}/root/#g" -e "s#/etc/hosts#${dir}/hosts#g" \
        -e "s#/etc/landscape/server.pem#${dir}/server.pem#g" \
        "${REPO_ROOT}/scripts/landscape_client.sh" > "$dir/client.sh"
    PATH="${dir}/bin:$PATH" STUB_DIR="$dir" bash "$dir/client.sh"
}
(
    ctmp="$(mktemp -d)"
    trap 'rm -rf -- "$ctmp"' EXIT
    mkdir -p "$ctmp/bin" "$ctmp/root"
    touch "$ctmp/hosts" "$ctmp/enabled"
    printf '#!/bin/sh\nexit 0\n' > "$ctmp/bin/cloud-init"
    printf '#!/bin/sh\necho installed\n' > "$ctmp/bin/dpkg-query"
    printf '#!/bin/sh\necho demo-client\n' > "$ctmp/bin/hostname"
    cat > "$ctmp/bin/landscape-config" <<'STUB'
#!/bin/bash
[[ "$1" == "--is-registered" ]] && exec test -f "$STUB_DIR/registered"
echo "landscape-config $*" >> "$STUB_DIR/calls"
touch "$STUB_DIR/registered"
STUB
    cat > "$ctmp/bin/pro" <<'STUB'
#!/bin/bash
case "$1 $2" in
    "api u.pro.status.is_attached.v1")
        [[ -f "$STUB_DIR/attached" ]] && v=true || v=false
        echo "{\"data\": {\"attributes\": {\"is_attached\": $v}}}" ;;
    "api u.pro.status.enabled_services.v1")
        python3 -c 'import json, sys; print(json.dumps({"data": {"attributes": {"enabled_services": [{"name": n.strip()} for n in open(sys.argv[1]) if n.strip()]}}}))' "$STUB_DIR/enabled" ;;
    attach*) echo "pro $*" >> "$STUB_DIR/calls"; [[ "$2" == "GOOD" ]] || exit 1; touch "$STUB_DIR/attached" ;;
    enable*) echo "pro $*" >> "$STUB_DIR/calls"; echo "$2" >> "$STUB_DIR/enabled" ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$ctmp/bin/"*

    output="$(run_client_script "$ctmp" BAD 2>&1)" || fail "A wrong Pro token must not abort client setup: $output"
    assert_contains "$output" "WARNING: Ubuntu Pro attach failed"
    calls="$(cat "$ctmp/calls")"
    assert_contains "$calls" "pro attach BAD --no-auto-enable"
    assert_contains "$calls" "landscape-config --silent"
    [[ "$calls" != *"pro enable"* ]] || fail "ESM must not be enabled on an unattached client"
    [[ ! -e "$ctmp/root/landscape-client.env" ]] || fail "Client env with the token must be removed"

    run_client_script "$ctmp" GOOD >/dev/null 2>&1 || fail "Client setup with a valid token failed"
    calls="$(cat "$ctmp/calls")"
    assert_contains "$calls" $'pro attach GOOD --no-auto-enable\npro enable esm-infra --assume-yes\npro enable esm-apps --assume-yes'

    echo esm-infra > "$ctmp/enabled"
    run_client_script "$ctmp" "" >/dev/null 2>&1 || fail "Resume of an attached client failed"
    calls="$(cat "$ctmp/calls")"
    [[ "$calls" != *"pro attach"* ]] || fail "An attached client must not be attached again"
    [[ "$calls" != *"enable esm-infra"* ]] || fail "Enabled ESM services must not be enabled again"
    assert_contains "$calls" "pro enable esm-apps --assume-yes"
)

(
    lxc() { cat >/dev/null; }
    {
        landscape_lxc exec local:lab-landscape -- true
        read -r remaining
        [[ "$remaining" == "preserved-input" ]] || fail "LXD commands must not consume later menu/token input"
    } <<< "preserved-input"
)

(
    landscape_lxc() {
        [[ "$*" == 'list local:^lab-landscape$ -c s -f csv' ]] || fail "Status query must not match the client: $*"
        echo "RUNNING"
    }
    [[ "$(landscape_status "$LANDSCAPE_VM")" == "RUNNING" ]] || fail "Wrong instance status"
)

(
    landscape_lxc() {
        [[ "$*" == "list local:lab-landscape --format json" ]] || fail "Unexpected IP query: $*"
        echo '[{"name":"lab-landscape-extra","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.1.1.99"}]}}}},{"name":"lab-landscape","state":{"network":{"lo":{"addresses":[{"family":"inet","scope":"local","address":"127.0.0.1"}]},"enp5s0":{"addresses":[{"family":"inet6","scope":"global","address":"fd00::2"},{"family":"inet","scope":"global","address":"10.1.1.2"}]}}}}]'
    }
    [[ "$(landscape_ip lab-landscape)" == "10.1.1.2" ]] || fail "IP lookup must match the exact instance"
)

(
    landscape_lxc() { echo '[{"name":"lab-landscape","state":{}}]'; }
    if landscape_ip lab-landscape >/dev/null 2>&1; then
        fail "Missing IPv4 must not succeed"
    fi
)

(
    export LXD_NETWORK_NAME="demo-bridge"
    export LXD_STORAGE_POOL="demo-pool"
    landscape_wait_agent() { :; }
    landscape_ip() { echo "10.1.1.2"; }
    landscape_lxc() {
        printf '%s\n' "$*" >> "$TMP/calls"
        [[ "$1" != "info" ]]
    }
    : > "$TMP/calls"
    landscape_ensure_instance "$LANDSCAPE_VM" server ubuntu:24.04
    landscape_ensure_instance lab-landscape-client-2204 client ubuntu:22.04
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "launch ubuntu:24.04 local:lab-landscape --network demo-bridge --storage demo-pool"
    assert_contains "$calls" "--vm -c limits.cpu=2 -c limits.memory=8GiB -d root,size=40GiB"
    assert_contains "$calls" "launch ubuntu:22.04 local:lab-landscape-client-2204"
    assert_contains "$calls" "limits.memory=512MiB -d root,size=8GiB"
    assert_contains "$calls" "config device set local:lab-landscape eth0 ipv4.address=10.1.1.2"
    [[ "$calls" != *"device set local:lab-landscape-client"* ]] || fail "Client addresses must not be reserved"
)

(
    landscape_lxc() {
        case "$1 $2" in
            "info local:lab-landscape") return 0 ;;
            "config get") echo "someone-else" ;;
            *) fail "An unowned instance must not be modified: $*" ;;
        esac
    }
    if landscape_ensure_instance "$LANDSCAPE_VM" server ubuntu:24.04 >/dev/null; then
        fail "Existing unowned instance must be refused"
    fi
)

(
    landscape_lxc() { return 1; }
    if landscape_destroy >/dev/null 2>&1; then
        fail "Destroy must fail when LXD is unavailable"
    fi
    [[ -f "$LANDSCAPE_SETTINGS" ]] || fail "Unavailable LXD must not cause credentials to be deleted"
)

(
    : > "$TMP/calls"
    landscape_lxc() {
        case "$1" in
            list)
                [[ "$*" == "list local: user.lab-automation.component=landscape-demo -c n -f csv" ]] \
                    || fail "Destroy must select only labelled demo instances: $*"
                printf 'lab-landscape\nlab-landscape-client-1\nlab-landscape-client-2\n' ;;
            exec)
                [[ "${*: -1}" == "detach" ]] || fail "Destroy must only ask for a Pro detach: $*"
                echo "pro-detach $2" >> "$TMP/calls"
                case "$2" in
                    local:lab-landscape) echo "not attached" ;;
                    local:lab-landscape-client-1) echo "detached" ;;
                    *) return 1 ;;
                esac ;;
            *) echo "$*" >> "$TMP/calls" ;;
        esac
    }
    cp "$LANDSCAPE_SETTINGS" "$TMP/settings.bak"
    output="$(landscape_destroy 2>&1)"
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" $'pro-detach local:lab-landscape\ndelete --force local:lab-landscape\n'
    assert_contains "$calls" $'pro-detach local:lab-landscape-client-1\ndelete --force local:lab-landscape-client-1'
    assert_contains "$calls" $'pro-detach local:lab-landscape-client-2\ndelete --force local:lab-landscape-client-2'
    assert_contains "$output" "Ubuntu Pro detached from lab-landscape-client-1"
    assert_contains "$output" "Could not check Ubuntu Pro on lab-landscape-client-2"
    [[ "$output" != *"on lab-landscape;"* ]] || fail "Unattached instances must not warn"
    [[ ! -f "$LANDSCAPE_SETTINGS" ]] || fail "Destroy must remove demo credentials"
    mv "$TMP/settings.bak" "$LANDSCAPE_SETTINGS"
)

(
    : > "$TMP/calls"
    landscape_lxc() {
        case "$1 $2" in
            "file pull") echo "cert" > "$4" ;;
            "file push")
                [[ -s "$3" ]] || fail "Pushed file must exist: $3"
                [[ "$3" != *client.env ]] || grep -qx 'PRO_TOKEN=T0K' "$3" || fail "Client env must carry the Pro token"
                echo "push $4" >> "$TMP/calls" ;;
            "exec local:lab-landscape-client-1") echo "exec" >> "$TMP/calls" ;;
        esac
    }
    LANDSCAPE_PRO_TOKEN=T0K landscape_setup_client 10.1.1.2 lab-landscape-client-1
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "push local:lab-landscape-client-1/root/landscape-client.env"
    assert_contains "$calls" "push local:lab-landscape-client-1/root/landscape-server.pem"
    assert_contains "$calls" "exec"
    compgen -G "$TMP/client.*" >/dev/null && fail "Temporary client files must be removed"
    landscape_lxc() { [[ "$1" != "exec" ]]; }
    if landscape_setup_client 10.1.1.2 lab-landscape-client-1 >/dev/null 2>&1; then
        fail "Client setup failure must propagate"
    fi
    compgen -G "$TMP/client.*" >/dev/null && fail "Temporary client files must be removed after failure"
    true
)

install_stubs() {
    LANDSCAPE_PRO_TOKEN=""
    landscape_prepare_settings() { :; }
    landscape_ensure_instance() { echo "ensure $1 $2 $3" >> "$TMP/calls"; }
    landscape_ip() { echo "10.1.1.2"; }
    landscape_lxc() { :; }
    landscape_run_setup() { echo "setup $1" >> "$TMP/calls"; }
    landscape_check_web() { echo "access $1" >> "$TMP/calls"; }
    landscape_setup_client() { echo "register $2" >> "$TMP/calls"; }
}

(
    install_stubs
    landscape_run_setup() { return 1; }
    if landscape_install >/dev/null 2>&1; then
        fail "Server setup failure must propagate"
    fi
)

(
    install_stubs
    landscape_check_web() { return 1; }
    if output="$(landscape_install 2>&1)"; then
        fail "Normal URL access failure must prevent reporting a ready demo"
    fi
    [[ "$output" != *"demo is ready"* ]] || fail "Unreachable URL must not report success"
)

(
    install_stubs
    landscape_setup_client() { return 1; }
    if landscape_install >/dev/null 2>&1; then
        fail "Client registration failure must propagate"
    fi
)

(
    : > "$TMP/calls"
    install_stubs
    landscape_lxc() { echo "not attached"; }
    output="$(landscape_install)"
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" $'ensure lab-landscape server ubuntu:24.04\nensure lab-landscape-client-2604 client ubuntu:26.04\nensure lab-landscape-client-2404 client ubuntu:24.04\nensure lab-landscape-client-2204 client ubuntu:22.04\nsetup 10.1.1.2\naccess 10.1.1.2'
    assert_contains "$calls" $'register lab-landscape-client-2604\nregister lab-landscape-client-2404\nregister lab-landscape-client-2204'
    assert_contains "$output" "Login"
    assert_contains "$output" "https://10.1.1.2/"
    [[ "$output" != *"https://landscape.demo.internal"* ]] || fail "Browser URL must not require a hosts entry"
    assert_contains "$output" "lab-landscape-client-2604 lab-landscape-client-2404 lab-landscape-client-2204"
    assert_contains "$output" "no token entered"
)

(
    install_stubs
    landscape_lxc() { echo "attached; enabled: esm-apps, esm-infra"; }
    output="$(landscape_install)"
    [[ "$output" != *"no token entered"* ]] || fail "Already attached clients must not get the missing-token warning"
)

(
    : > "$TMP/calls"
    install_stubs
    unset LANDSCAPE_PRO_TOKEN
    landscape_ensure_instance() { echo "ensure $1 token=${LANDSCAPE_PRO_TOKEN-unset}" >> "$TMP/calls"; }
    landscape_setup_client() { echo "register $2 token=${LANDSCAPE_PRO_TOKEN}" >> "$TMP/calls"; }
    landscape_lxc() {
        [[ "$1 ${*: -1}" == "exec $LANDSCAPE_PRO_PY" ]] || fail "Summary must only query Pro status: $*"
        [[ "$2" == "local:lab-landscape-client-2204" ]] && return 1
        echo "attached; enabled: esm-apps, esm-infra"
    }
    output="$(landscape_install <<< "C1token")"
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "ensure lab-landscape token=C1token"
    assert_contains "$calls" "register lab-landscape-client-2204 token=C1token"
    grep -q C1token "$LANDSCAPE_SETTINGS" && fail "The Pro token must not be saved"
    [[ "$output" != *C1token* ]] || fail "The Pro token must not be printed"
    [[ "$output" != *"no token entered"* ]] || fail "A supplied token must not be reported as missing"
    assert_contains "$output" "Pro lab-landscape-client-2604"
    assert_contains "$output" "attached; enabled: esm-apps, esm-infra"
    assert_contains "$output" "status unknown"
)

(
    landscape_status() { echo "STOPPED"; }
    landscape_instances() { printf 'lab-landscape\nlab-landscape-client-2604\nlab-landscape-client-2204\n'; }
    output="$(lab_overview_landscape)"
    assert_contains "$output" "STOPPED"
    assert_contains "$output" "$ADMIN_PASSWORD"
    assert_contains "$output" "2 container(s)"
)

(
    landscape_status() { echo "RUNNING"; }
    landscape_ip() { echo "10.1.1.2"; }
    landscape_instances() { echo "lab-landscape"; }
    output="$(lab_overview_landscape)"
    assert_contains "$output" "https://10.1.1.2/"
    [[ "$output" != *"hosts entry"* ]] || fail "Overview URL must not require hosts changes"
)

(
    sleep() { :; }
    curl() {
        [[ "$*" != *"--resolve"* && "$*" != *"--connect-to"* ]] || fail "Access check must not override routing"
        [[ "${*: -1}" == "https://10.1.1.2/" ]] || fail "Access check must use the advertised URL"
        [[ "$*" == *"--location"* ]] || fail "Access check must follow redirects"
        echo "200 10.1.1.2"
    }
    landscape_check_web 10.1.1.2
    curl() { return 7; }
    if landscape_check_web 10.1.1.2 >/dev/null; then
        fail "Unreachable normal URL must fail"
    fi
    curl() { echo "503 10.1.1.2"; }
    if landscape_check_web 10.1.1.2 >/dev/null; then
        fail "A failing HTTP response must fail"
    fi
    curl() { echo "200 10.1.1.99"; }
    if landscape_check_web 10.1.1.2 >/dev/null; then
        fail "A response from a different server must fail"
    fi
)

(
    : > "$TMP/calls"
    landscape_lxc() {
        case "$1" in
            file) echo "push $4" >> "$TMP/calls" ;;
            exec) echo "exec $*" >> "$TMP/calls"; echo "guest output"; return 3 ;;
        esac
    }
    : > "$TMP/setup.log"
    if landscape_run_setup 10.1.1.2 >/dev/null; then
        fail "Guest setup failure must propagate through tee"
    fi
    assert_contains "$(cat "$TMP/setup.log")" "guest output"
    assert_contains "$(cat "$TMP/calls")" "push local:lab-landscape/root/landscape-setup.sh"
    assert_contains "$(cat "$TMP/calls")" "exec local:lab-landscape --env SERVER_IP=10.1.1.2 -- bash /root/landscape-setup.sh"
    landscape_lxc() { return 0; }
    tee() { cat >/dev/null; return 1; }
    if landscape_run_setup 10.1.1.2 >/dev/null; then
        fail "A setup.log write failure must propagate"
    fi
)

# Run the real guest helper on a copy of service.conf.
(
    gtmp="$(mktemp -d)"
    trap 'rm -rf -- "$gtmp"' EXIT
    guest="${REPO_ROOT}/scripts/landscape_guest.sh"
    printf '[stores]\nhost = localhost\n\n[system]\nroot_url = https://landscape.demo.internal/\n' > "$gtmp/service.conf"
    eval "$(sed -n '/^configure_service_conf() {/,/^}/p' "$guest" | sed "s#/etc/landscape/service.conf#${gtmp}/service.conf#")"
    export SERVER_IP=10.1.1.2
    [[ "$(configure_service_conf)" == "changed" ]] || fail "A hostname root_url must be replaced"
    python3 - "$gtmp/service.conf" <<'PY' || fail "service.conf must use the IP root_url and keep other settings"
import configparser, sys
c = configparser.ConfigParser(interpolation=None)
c.read(sys.argv[1])
assert c["system"]["root_url"] == "https://10.1.1.2/"
assert c["features"]["ubuntu_pro_licensing"] == "true"
assert c["stores"]["host"] == "localhost"
PY
    [[ -z "$(configure_service_conf)" ]] || fail "An unchanged service.conf must not restart Landscape"
    resume="$(sed -n '/^if \[\[ -f \/var\/lib\/lab-landscape\/ready \]\]; then/,/^fi/p' "$guest")"
    assert_contains "$resume" $'configure_debarchive\n    configure_service_dependencies\n    service_conf="$(configure_service_conf)"\n    if [[ "$service_conf" == "changed" ]]; then\n        lsctl restart'
    assert_contains "$resume" "wait_debarchive"
    grep -q 'landscape-debarchive.debarchive' "$guest" || fail "Debarchive must be a checked service"
    grep -qF -- '--root_url "https://${SERVER_IP}/"' "$guest" || fail "The account root URL must use the server IP"
)

(
    CM_SETTINGS="$TMP/cm.env"
    cm_lxc() { return 1; }
    if cm_installed; then
        fail "Missing Cluster Manager resources must not be listed"
    fi
    touch "$CM_SETTINGS"
    cm_installed || fail "Partial Cluster Manager state must be listed"
    rm "$CM_SETTINGS"
    cm_lxc() { [[ "$*" == "info local:lab-cluster-manager" ]]; }
    cm_installed || fail "Cluster Manager VM must be discovered without saved settings"
    cm_lxc() { [[ "$*" == "network show local:lab-cmbr0" ]]; }
    cm_installed || fail "A leftover Cluster Manager bridge must be discovered"
)

(
    export CM_STATE_DIR="$TMP"
    CM_SETTINGS="$TMP/cm.env"
    touch "$CM_SETTINGS"
    cm_lxc() { return 1; }
    if cm_remove >/dev/null; then
        fail "Unavailable LXD must prevent Cluster Manager cleanup"
    fi
    [[ -f "$CM_SETTINGS" ]] || fail "Keep credentials when LXD is unavailable"
    cm_lxc() {
        case "$1 $2" in
            "info local:"|"info local:lab-cluster-manager"|"network show") return 0 ;;
            "config get") echo "cluster-manager" ;;
            "network get") echo "unrelated" ;;
            *) fail "An unowned bridge must prevent all deletions: $*" ;;
        esac
    }
    if cm_remove >/dev/null; then
        fail "Unowned Cluster Manager resources must not be deleted"
    fi
    [[ -f "$CM_SETTINGS" ]] || fail "Keep credentials when ownership verification fails"
    : > "$TMP/calls"
    cm_lxc() {
        echo "$*" >> "$TMP/calls"
        case "$1 $2" in
            "config get"|"network get") echo "cluster-manager" ;;
        esac
        return 0
    }
    cm_remove >/dev/null
    assert_contains "$(cat "$TMP/calls")" $'delete --force local:lab-cluster-manager\nnetwork delete local:lab-cmbr0'
    [[ ! -f "$CM_SETTINGS" ]] || fail "Successful cleanup must remove Cluster Manager credentials"
)

(
    : > "$TMP/calls"
    tofu() { :; }
    cm_installed() { return 0; }
    cm_remove() { echo "cm removed" >> "$TMP/calls"; }
    landscape_instances() { :; }
    output="$(destroy_menu <<< $'1\nyes' 2>&1)" || fail "Cluster Manager destroy must succeed"
    assert_contains "$output" "Cluster Manager (lab-cluster-manager + lab-cmbr0)"
    assert_contains "$(cat "$TMP/calls")" "cm removed"
)

echo "PASS: Landscape settings, dash-safe secrets, Pro token/ESM/detach, Debarchive, IP root URL, sizing, IP access, mixed clients, overview and instructor service cleanup"
