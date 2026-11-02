#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../orchestrate.sh
source "${REPO_ROOT}/orchestrate.sh"
TMP="$(mktemp -d)"
trap 'rm -f -- "$TMP/settings.env" "$TMP/settings.bak" "$TMP/calls" "$TMP/setup.log"; rmdir -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "Expected '$2' in '$1'"; }

export LANDSCAPE_STATE_DIR="$TMP"
LANDSCAPE_SETTINGS="$TMP/settings.env"
lxc() { fail "Unexpected real LXD call: $*"; }
landscape_prepare_settings
[[ "$(stat -c %a "$TMP")" == "700" ]] || fail "State directory must be private"
[[ "$(stat -c %a "$LANDSCAPE_SETTINGS")" == "600" ]] || fail "Settings must be private"
original="$(cat "$LANDSCAPE_SETTINGS")"
landscape_prepare_settings
[[ "$(cat "$LANDSCAPE_SETTINGS")" == "$original" ]] || fail "Resume changed credentials"
# shellcheck source=/dev/null
source "$LANDSCAPE_SETTINGS"
[[ -n "$ADMIN_PASSWORD" && -n "$REGISTRATION_KEY" ]] || fail "Missing generated credentials"

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
    : > "$TMP/calls"
    landscape_wait_agent() { echo "agent $1" >> "$TMP/calls"; }
    landscape_lxc() {
        echo "$*" >> "$TMP/calls"
        [[ "$1 $2" == "config get" ]] && echo "16GiB"
        return 0
    }
    landscape_set_memory 8GiB >/dev/null
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" $'stop local:lab-landscape --timeout 120\nconfig set local:lab-landscape limits.memory=8GiB\nstart local:lab-landscape\nagent lab-landscape'
)

(
    landscape_lxc() {
        [[ "$1 $2" == "config get" ]] || fail "An unchanged RAM allocation must not restart the VM"
        echo "8GiB"
    }
    landscape_set_memory 8GiB
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
    landscape_ensure_instance "$LANDSCAPE_VM" server
    landscape_ensure_instance lab-landscape-client-1 client
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "--network demo-bridge --storage demo-pool"
    assert_contains "$calls" "--vm -c limits.cpu=2 -c limits.memory=16GiB -d root,size=40GiB"
    assert_contains "$calls" "limits.memory=512MiB -d root,size=8GiB"
    assert_contains "$calls" "config device set local:lab-landscape eth0 ipv4.address=10.1.1.2"
)

(
    landscape_lxc() {
        case "$1 $2" in
            "info local:lab-landscape") return 0 ;;
            "config get") echo "someone-else" ;;
            *) fail "An unowned instance must not be modified: $*" ;;
        esac
    }
    if landscape_ensure_instance "$LANDSCAPE_VM" server >/dev/null; then
        fail "Existing unowned instance must be refused"
    fi
)

(
    sleep() { :; }
    landscape_lxc() { return 1; }
    if landscape_check_services >/dev/null; then
        fail "Inactive required services must fail readiness"
    fi
)

(
    landscape_lxc() {
        [[ "$*" == *'for service; do systemctl is-active --quiet "$service" || exit 1; done'* ]] \
            || fail "Readiness must check every service, not systemctl is-active with multiple units"
        assert_contains "$*" "snap.landscape-task-handler.server.service"
        assert_contains "$*" "snap.landscape-task-handler.worker.service"
        assert_contains "$*" "snap.landscape-outbox.outbox.service"
    }
    landscape_check_services
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
    landscape_ensure_instance() { echo "ensure $1 $2" >> "$TMP/calls"; }
    landscape_ip() { echo "10.1.1.2"; }
    landscape_lxc() { [[ "$*" != *"test -f /var/lib/lab-landscape/ready"* ]]; }
    landscape_run_setup() { :; }
    landscape_set_memory() { echo "memory $1" >> "$TMP/calls"; }
    landscape_check_web() { :; }
    landscape_check_services() { :; }
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
    landscape_check_services() { return 1; }
    if landscape_install >/dev/null 2>&1; then
        fail "Healthy HTTPS must not hide a failed required service"
    fi
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
    assert_contains "$calls" "memory 8GiB"
    assert_contains "$calls" $'ensure lab-landscape-client-1 client\nregister lab-landscape-client-1'
    assert_contains "$calls" "register lab-landscape-client-2"
    assert_contains "$calls" "register lab-landscape-client-3"
    assert_contains "$output" "Login"
)

(
    landscape_status() { echo "STOPPED"; }
    landscape_instances() { printf 'lab-landscape\nlab-landscape-client-1\nlab-landscape-client-2\n'; }
    output="$(lab_overview_landscape)"
    assert_contains "$output" "STOPPED"
    assert_contains "$output" "$ADMIN_PASSWORD"
    assert_contains "$output" "2 container(s)"
)

echo "PASS: Landscape settings, isolation, sizing, install, destroy and overview"
