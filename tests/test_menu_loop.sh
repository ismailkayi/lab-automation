#!/bin/bash
# Variables set here are read by the sourced orchestrator functions.
# shellcheck disable=SC2034
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../orchestrate.sh
source "${REPO_ROOT}/orchestrate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "Expected '$2' in '$1'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "Did not expect '$2' in '$1'"; }
count_of() { grep -c -F -- "$2" <<< "$1" || true; }

# Replaces everything main() needs from the host. The OpenTofu mock prints the usual init noise.
mock_startup() {
    ensure_tools() { return 0; }
    detect_lxd_defaults() { LXD_NETWORK_NAME=mockbr0; LXD_STORAGE_POOL=default; }
    tofu() {
        case "${1:-} ${2:-}" in
            "init -input=false")
                echo "Initializing the backend..."
                echo "OpenTofu has been successfully initialized!"
                return "${TOFU_INIT_RC:-0}"
                ;;
            "workspace list") echo "  default" ;;
            *) fail "Unexpected OpenTofu call: $*" ;;
        esac
    }
}

# Runs main with the given input and stores its output and exit status. The status is captured without
# an || list because bash ignores errexit everywhere below one, which would hide errexit regressions.
run_main() {
    set +e
    output="$(main <<< "$1" 2>&1)"
    status=$?
    set -e
}

# Startup is quiet: no LXD summary and no OpenTofu output unless the init fails.
(
    mock_startup
    run_main "0"
    [[ "$status" == 0 ]] || fail "Exit must succeed, got $status"
    assert_contains "$output" "CANONICAL LAB DEPLOYMENT ENGINE"
    assert_contains "$output" "FULL LAB DEPLOYMENTS"
    assert_contains "$output" "Exiting."
    for text in "Initializing" "OpenTofu has been" "LXD Environment" "Selected network" "Selected storage pool"; do
        assert_not_contains "$output" "$text"
    done
)
(
    mock_startup
    TOFU_INIT_RC=1
    run_main "0"
    [[ "$status" == 1 ]] || fail "A failed OpenTofu init must stop the script, got $status"
    assert_contains "$output" "Initializing the backend"
    assert_contains "$output" "OpenTofu initialization failed"
    assert_not_contains "$output" "FULL LAB DEPLOYMENTS"
)
(
    mock_startup
    SCRIPT_DIR="$TMP/first-run"
    mkdir -p "$SCRIPT_DIR"
    run_main "0"
    assert_contains "$output" "first run only"
    mkdir -p "$SCRIPT_DIR/.terraform/providers"
    run_main "0"
    assert_not_contains "$output" "first run only"
)
(
    lxc() {
        case "${1:-} ${2:-}" in
            "info ") return 0 ;;
            "network list") echo "lxdbr0,YES,10.0.0.1/24" ;;
            "network show") echo "type: bridge" ;;
            "network get") echo "10.0.0.1/24" ;;
            "storage show") return 0 ;;
            *) fail "Unexpected LXD call: $*" ;;
        esac
    }
    output="$(detect_lxd_defaults 2>&1)"
    [[ -z "$output" ]] || fail "LXD defaults must be detected silently, got: $output"
    detect_lxd_defaults
    # shellcheck disable=SC2154 # exported by detect_lxd_defaults in orchestrate.sh
    [[ "$LXD_NETWORK_NAME $LXD_STORAGE_POOL $TF_VAR_lxd_network_name" == "lxdbr0 default lxdbr0" ]] ||
        fail "LXD defaults must still be selected and exported"
)

# The menu lists every option up to the last accepted number.
(
    menu="$(print_main_menu)"
    for number in $(seq 1 "$MAIN_MENU_LAST_OPTION"); do
        assert_contains "$menu" "${number}) "
    done
    assert_not_contains "$menu" "$((MAIN_MENU_LAST_OPTION + 1))) "
    assert_contains "$menu" "0) Exit"
)

# The menu comes back after every action and 0 leaves it.
(
    mock_startup
    run_menu_action() { echo "ran action $1"; }
    run_main $'8\n9\n0'
    [[ "$status" == 0 ]] || fail "Leaving with 0 must succeed, got $status"
    assert_contains "$output" "ran action 8"
    assert_contains "$output" "ran action 9"
    [[ "$(count_of "$output" "FULL LAB DEPLOYMENTS")" == 3 ]] || fail "The menu must be shown after each action"
    [[ "$(count_of "$output" "CANONICAL LAB DEPLOYMENT ENGINE")" == 3 ]] || fail "The banner must head each menu"
)

# Empty and invalid input ask again without repeating the menu; spaces and a leading zero are accepted.
(
    mock_startup
    run_menu_action() { echo "ran action $1"; }
    run_main $'\nabc\n13\n99\n-1\n1 2\n  8  \n08\n0'
    [[ "$status" == 0 ]] || fail "Exit must succeed, got $status"
    [[ "$(count_of "$output" "Invalid selection. Enter a number from 0 to 12.")" == 5 ]] ||
        fail "Five invalid entries expected: $output"
    [[ "$(count_of "$output" "ran action 8")" == 2 ]] || fail "'  8  ' and '08' must run option 8"
    [[ "$(count_of "$output" "FULL LAB DEPLOYMENTS")" == 3 ]] || fail "Invalid input must not repeat the menu"
)

# A failing action is reported and does not end the session; the last status survives the end of input.
(
    mock_startup
    run_menu_action() { echo "ran action $1"; [[ "$1" != 4 ]] || exit 3; }
    run_main $'4\n8\n0'
    [[ "$status" == 0 ]] || fail "A later successful exit must win, got $status"
    assert_contains "$output" "The action ended with exit status 3"
    assert_contains "$output" "ran action 8"
    run_main $'8\n4'
    [[ "$status" == 3 ]] || fail "End of input after a failed action must keep its status, got $status"
    run_main $'4\n8'
    [[ "$status" == 0 ]] || fail "End of input after a successful action must succeed, got $status"
)

# errexit stays active inside an action and state does not leak into the next one.
(
    mock_startup
    run_menu_action() { false; echo "NOT REACHED"; }
    run_main $'8\n0'
    assert_not_contains "$output" "NOT REACHED"
    assert_contains "$output" "The action ended with exit status 1"
)
(
    mock_startup
    run_menu_action() { echo "seen=${SEEN:-none}"; SEEN=yes; }
    run_main $'8\n8\n0'
    [[ "$(count_of "$output" "seen=none")" == 2 ]] || fail "Actions must not share variables: $output"
)

# Piped input is never consumed by the pause, so scripted runs need no extra lines.
(
    { pause_before_menu > "$TMP/pause-output" 2>&1; read -r next_line; } <<< "left for the menu"
    [[ "$next_line" == "left for the menu" ]] || fail "The pause must not read piped input, got '$next_line'"
    assert_not_contains "$(< "$TMP/pause-output")" "Press Enter"
)

# In an interactive terminal the output of every action stays on screen until Enter is pressed;
# only then is the screen cleared and the menu shown.
(
    mock_startup
    stdin_is_tty() { return 0; }
    discard_pending_input() { :; }
    clear_screen() { echo "[screen cleared]"; }
    run_menu_action() { echo "ran action $1"; [[ "$1" != 4 ]] || exit 3; }
    run_main $'8\n\n4\n\n0'
    [[ "$status" == 0 ]] || fail "Leaving with 0 must succeed, got $status"
    [[ "$(count_of "$output" "Press Enter to return to the main menu")" == 2 ]] ||
        fail "Each action must wait for Enter, and 0 must not: $output"
    [[ "$(count_of "$output" "[screen cleared]")" == 3 ]] ||
        fail "The screen must be cleared at startup and after each Enter: $output"
    [[ "$(count_of "$output" "FULL LAB DEPLOYMENTS")" == 3 ]] || fail "The menu must be shown after each Enter"
    before_pause="${output%%Press Enter*}"
    assert_contains "$before_pause" "ran action 8"
    [[ "$(count_of "$before_pause" "FULL LAB DEPLOYMENTS")" == 1 ]] ||
        fail "The menu must not appear before Enter is pressed: $before_pause"
    after_pause="${output#*Press Enter to return to the main menu...}"
    [[ "$after_pause" == *"[screen cleared]"*"CANONICAL LAB DEPLOYMENT ENGINE"*"FULL LAB DEPLOYMENTS"* ]] ||
        fail "The screen must be cleared before the menu: $after_pause"
    failed_run="${output#*ran action 4}"
    [[ "$failed_run" == *"The action ended with exit status 3"*"Press Enter"* ]] ||
        fail "A failure must be reported before the pause: $failed_run"
)
(
    mock_startup
    stdin_is_tty() { return 0; }
    discard_pending_input() { :; }
    clear_screen() { :; }
    run_menu_action() { exit 3; }
    run_main $'4'
    [[ "$status" == 3 ]] || fail "End of input at the pause must keep the last status, got $status"
    assert_contains "$output" "Press Enter to return to the main menu"
    [[ "$(count_of "$output" "FULL LAB DEPLOYMENTS")" == 1 ]] || fail "No menu may follow the end of input"
)

# Every main menu number reaches its function; an unknown number is refused.
(
    mock_startup
    cluster_manager_menu() { echo "called cluster_manager_menu"; }
    lab_overview() { echo "called lab_overview"; }
    destroy_menu() { echo "called destroy_menu"; }
    landscape_install() { echo "called landscape_install"; }
    cos_install() { echo "called cos_install"; }
    maas_install() { echo "called maas_install"; }
    run_main $'7\n8\n9\n10\n11\n12\n0'
    previous=-1
    for name in cluster_manager_menu lab_overview destroy_menu landscape_install cos_install maas_install; do
        assert_contains "$output" "called ${name}"
        before="${output%%"called ${name}"*}"
        (( ${#before} > previous )) || fail "$name must run in menu order"
        previous=${#before}
    done
    status=0
    output="$(run_menu_action 13 2>&1)" || status=$?
    [[ "$status" == 1 ]] || fail "An unknown action must fail, got $status"
    assert_contains "$output" "Invalid selection."
)

# Cancelling inside a lab flow returns to the main menu instead of ending the script.
(
    mock_startup
    run_main $'4\n0\n0'
    [[ "$status" == 0 ]] || fail "Cancelling a lab flow must not fail, got $status"
    assert_contains "$output" "Existing Training Labs"
    assert_contains "$output" "Cancelled."
    [[ "$(count_of "$output" "FULL LAB DEPLOYMENTS")" == 2 ]] || fail "The main menu must come back after Cancel"
    assert_contains "$output" "Exiting."
)

# Destroy lists the environments again after each removal, with fresh numbers.
destroy_fixture() {
    : > "$TMP/calls"
    touch "$TMP/cos-installed" "$TMP/maas-installed"
    cm_installed() { return 1; }
    landscape_instances() { :; }
    LANDSCAPE_SETTINGS="$TMP/missing-landscape.env"
    tofu() {
        [[ "$*" == "workspace list" ]] || fail "Unexpected OpenTofu call: $*"
        cat "$TMP/workspaces"
    }
    printf '  default\n' > "$TMP/workspaces"
    cos_installed() { [[ -f "$TMP/cos-installed" ]]; }
    maas_installed() { [[ -f "$TMP/maas-installed" ]]; }
    cos_destroy() { rm -f "$TMP/cos-installed"; echo "cos destroyed" >> "$TMP/calls"; }
    maas_destroy() { rm -f "$TMP/maas-installed"; echo "maas destroyed" >> "$TMP/calls"; }
}
(
    destroy_fixture
    output="$(destroy_menu <<< $'1\nyes\n1\nyes' 2>&1)" || fail "Destroying every environment must succeed"
    [[ "$(cat "$TMP/calls")" == $'cos destroyed\nmaas destroyed' ]] ||
        fail "Both demos must be destroyed once each: $(cat "$TMP/calls")"
    assert_contains "$output" "0) Back to the main menu"
    assert_contains "$output" "No active lab environments"
    [[ "$(count_of "$output" "ACTIVE ENVIRONMENTS")" == 2 ]] || fail "The list must be shown again after a destroy"
)
(
    destroy_fixture
    rm -f "$TMP/maas-installed"
    output="$(destroy_menu <<< $'5\n1\nno\n0' 2>&1)" || fail "Backing out must succeed"
    assert_contains "$output" "Invalid selection."
    assert_contains "$output" "Cancelled."
    [[ ! -s "$TMP/calls" ]] || fail "Nothing may be destroyed without 'yes'"
    [[ "$(count_of "$output" "ACTIVE ENVIRONMENTS")" == 3 ]] || fail "Invalid and declined entries must list again"
)
(
    destroy_fixture
    rm -f "$TMP/maas-installed"
    status=0
    destroy_menu < /dev/null > "$TMP/eof-output" 2>&1 || status=$?
    [[ "$status" == 0 ]] || fail "End of input must leave the destroy menu, got $status"
    cos_destroy() { return 1; }
    status=0
    destroy_menu <<< $'1\nyes' > /dev/null 2>&1 || status=$?
    [[ "$status" == 1 ]] || fail "A failed destroy must be reported, got $status"
)
(
    destroy_fixture
    rm -f "$TMP/cos-installed" "$TMP/maas-installed"
    printf '  default\n  group1_training-microcloud\n' > "$TMP/workspaces"
    get_microcloud_node_count_from_state() { echo 4; }
    destroy_environment() {
        echo "destroyed $1 $2 $3 $6 $7" >> "$TMP/calls"
        printf '  default\n' > "$TMP/workspaces"
    }
    output="$(destroy_menu <<< $'1\nyes' 2>&1)" || fail "Destroying a lab must succeed"
    [[ "$(cat "$TMP/calls")" == "destroyed group1_training-microcloud group1 microcloud training 4" ]] ||
        fail "The lab must be destroyed with its metadata: $(cat "$TMP/calls")"
    assert_contains "$output" "successfully destroyed"
    assert_contains "$output" "No active lab environments"
)

echo "PASS: quiet startup, menu loop, interactive pause, input handling, failure status, action isolation, menu wiring and destroy loop"
