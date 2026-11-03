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
        echo "$*" >> "$TMP/calls"
        if [[ "$1" == "list" ]]; then
            [[ "$*" == "list local: user.lab-automation.component=landscape-demo -c n -f csv" ]] \
                || fail "Destroy must select only labelled demo instances: $*"
            printf 'lab-landscape\nlab-landscape-client-1\n'
        fi
    }
    cp "$LANDSCAPE_SETTINGS" "$TMP/settings.bak"
    landscape_destroy >/dev/null
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "delete --force local:lab-landscape"
    assert_contains "$calls" "delete --force local:lab-landscape-client-1"
    [[ ! -f "$LANDSCAPE_SETTINGS" ]] || fail "Destroy must remove demo credentials"
    mv "$TMP/settings.bak" "$LANDSCAPE_SETTINGS"
)

(
    : > "$TMP/calls"
    landscape_lxc() {
        case "$1 $2" in
            "file pull") echo "cert" > "$4" ;;
            "file push") [[ -s "$3" ]] || fail "Pushed file must exist: $3"; echo "push $4" >> "$TMP/calls" ;;
            "exec local:lab-landscape-client-1") echo "exec" >> "$TMP/calls" ;;
        esac
    }
    landscape_setup_client 10.1.1.2 lab-landscape-client-1
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
    landscape_prepare_settings() { :; }
    landscape_ensure_instance() { echo "ensure $1 $2 $3" >> "$TMP/calls"; }
    landscape_ip() { echo "10.1.1.2"; }
    landscape_lxc() { :; }
    landscape_run_setup() { echo "setup" >> "$TMP/calls"; }
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
    output="$(landscape_install)"
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" $'ensure lab-landscape server ubuntu:24.04\nensure lab-landscape-client-2604 client ubuntu:26.04\nensure lab-landscape-client-2404 client ubuntu:24.04\nensure lab-landscape-client-2204 client ubuntu:22.04\nsetup\naccess 10.1.1.2'
    assert_contains "$calls" $'register lab-landscape-client-2604\nregister lab-landscape-client-2404\nregister lab-landscape-client-2204'
    assert_contains "$output" "Login"
    assert_contains "$output" "https://10.1.1.2/"
    [[ "$output" != *"https://landscape.demo.internal"* ]] || fail "Browser URL must not require a hosts entry"
    assert_contains "$output" "lab-landscape-client-2604 lab-landscape-client-2404 lab-landscape-client-2204"
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
            exec) echo "guest output"; return 3 ;;
        esac
    }
    : > "$TMP/setup.log"
    if landscape_run_setup >/dev/null; then
        fail "Guest setup failure must propagate through tee"
    fi
    assert_contains "$(cat "$TMP/setup.log")" "guest output"
    assert_contains "$(cat "$TMP/calls")" "push local:lab-landscape/root/landscape-setup.sh"
    landscape_lxc() { return 0; }
    tee() { cat >/dev/null; return 1; }
    if landscape_run_setup >/dev/null; then
        fail "A setup.log write failure must propagate"
    fi
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

echo "PASS: Landscape settings, dash-safe secrets, sizing, IP access, mixed clients, overview and instructor service cleanup"
