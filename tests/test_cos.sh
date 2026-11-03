#!/bin/bash
# Variables set here are read by the sourced COS functions.
# shellcheck disable=SC2034
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../orchestrate.sh
source "${REPO_ROOT}/orchestrate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "Expected '$2' in '$1'"; }

COS_STATE_DIR="$TMP/state"
COS_SETTINGS="$COS_STATE_DIR/settings.env"
COS_ACCESS="$COS_STATE_DIR/access.env"
lxc() { fail "Unexpected real LXD call: $*"; }
curl() { fail "Unexpected real HTTP call: $*"; }

# Settings are private and kept on resume.
(
    cm_pick_subnet_prefix() { echo "172.31.7"; }
    cos_prepare_settings
    [[ "$(stat -c %a "$COS_STATE_DIR")" == "700" ]] || fail "State directory must be private"
    [[ "$(stat -c %a "$COS_SETTINGS")" == "600" ]] || fail "Settings must be private"
    cm_pick_subnet_prefix() { echo "172.31.8"; }
    cos_prepare_settings
    grep -qx 'SUBNET_PREFIX=172.31.7' "$COS_SETTINGS" || fail "Resume must keep the chosen subnet"
)
SUBNET_PREFIX=172.31.7

# The stub keeps host values across calls, including reads in command substitutions.
host_config_stub() {
    COS_STATE_DIR="$(mktemp -d "$TMP/host.XXXXXX")"
    : > "$TMP/calls"
    cos_lxc() {
        case "$1 $2" in
            "config get") echo "${HOST[$4]:-}" ;;
            "config set")
                echo "set $4" >> "$TMP/calls"
                HOST["${4%%=*}"]="${4#*=}" ;;
            "config unset")
                echo "unset $4" >> "$TMP/calls"
                unset 'HOST[$4]' ;;
            *) fail "Unexpected LXD call: $*" ;;
        esac
    }
}
(
    declare -A HOST=()
    host_config_stub
    LXD_JOB=lxd
    cos_enable_host_metrics
    cos_enable_host_logs
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "core.metrics_address=172.31.7.1:8444"
    assert_contains "$calls" "core.metrics_authentication=false"
    assert_contains "$calls" $'set loki.instance=lxd\nset loki.api.url=http://172.31.7.200/cos-loki-0'
    [[ "$(stat -c %a "$COS_STATE_DIR/host-config")" == 700 ]] || fail "Ownership directory must be private"
    for key in core.metrics_address core.metrics_authentication loki.api.url loki.instance; do
        [[ "$(cat "$COS_STATE_DIR/host-config/$key")" == "${HOST[$key]}" ]] || fail "Must record the value written for $key"
        [[ "$(stat -c %a "$COS_STATE_DIR/host-config/$key")" == 600 ]] || fail "Ownership record must be private"
    done

    : > "$TMP/calls"
    cos_enable_host_metrics
    cos_enable_host_logs
    [[ ! -s "$TMP/calls" ]] || fail "Resume must not set existing COS values again"
    cos_disable_host_monitoring
    [[ "${#HOST[@]}" == 0 ]] || fail "Cleanup must restore initially unset values"
    [[ ! -d "$COS_STATE_DIR/host-config" ]] || fail "Cleanup must remove ownership records"
)

# Conflicts in either member of a pair must be detected before writing either key.
(
    declare -A HOST=()
    host_config_stub
    HOST[core.metrics_address]=":9100"
    if cos_enable_host_metrics >/dev/null 2>&1; then
        fail "A foreign metrics address must be refused"
    fi
    [[ ! -s "$TMP/calls" ]] || fail "A foreign metrics address must not be changed"

    for address in "" "172.31.7.1:8444"; do
        HOST=([core.metrics_address]="$address" [core.metrics_authentication]=true)
        if cos_enable_host_metrics > "$TMP/result" 2>&1; then
            fail "Explicit metrics authentication must not be disabled"
        fi
        assert_contains "$(cat "$TMP/result")" "core.metrics_authentication"
        [[ ! -s "$TMP/calls" ]] || fail "Authentication conflict must not change either metrics key"
        [[ "${HOST[core.metrics_authentication]}" == true ]] || fail "Metrics authentication must stay enabled"
    done

    HOST=()
    HOST[loki.api.url]="http://other-loki:3100"
    LXD_JOB=lxd
    if cos_enable_host_logs >/dev/null 2>&1; then
        fail "A foreign Loki URL must be refused"
    fi
    [[ ! -s "$TMP/calls" ]] || fail "loki.instance must not change when the Loki URL is foreign"

    for url in "" "http://172.31.7.200/cos-loki-0"; do
        HOST=([loki.api.url]="$url" [loki.instance]=existing-label)
        if cos_enable_host_logs > "$TMP/result" 2>&1; then
            fail "An existing Loki instance label must be refused"
        fi
        assert_contains "$(cat "$TMP/result")" "loki.instance"
        [[ ! -s "$TMP/calls" ]] || fail "Instance label conflict must not change either Loki key"
        [[ "${HOST[loki.instance]}" == existing-label ]] || fail "The existing instance label must be kept"
    done
)

# Default-true authentication may be omitted by LXD even after an explicit set.
(
    declare -A HOST=([core.metrics_address]="172.31.7.1:8444")
    host_config_stub
    if cos_enable_host_metrics > "$TMP/result" 2>&1; then
        fail "Default authentication on an existing endpoint must not be disabled"
    fi
    assert_contains "$(cat "$TMP/result")" "defaults to true"
    [[ ! -s "$TMP/calls" ]] || fail "An existing authenticated endpoint must stay unchanged"

    HOST=()
    cos_enable_host_metrics
    unset 'HOST[core.metrics_authentication]'
    : > "$TMP/calls"
    if cos_enable_host_metrics > "$TMP/result" 2>&1; then
        fail "Re-enabling default authentication after install must be preserved on resume"
    fi
    [[ ! -s "$TMP/calls" ]] || fail "Resume must not disable re-enabled authentication"
)
(
    declare -A HOST=()
    host_config_stub
    cos_host_set core.metrics_address "172.31.7.1:8444"
    cos_enable_host_metrics
    [[ "${HOST[core.metrics_authentication]}" == false ]] ||
        fail "A partial install that created only the endpoint must still resume"
)

# Equal pre-existing values are usable, but are not owned by the demo.
(
    declare -A HOST=([core.metrics_address]="172.31.7.1:8444" [core.metrics_authentication]=false
        [loki.api.url]="http://172.31.7.200/cos-loki-0" [loki.instance]=lxd)
    host_config_stub
    LXD_JOB=lxd
    cos_enable_host_metrics
    cos_enable_host_logs
    cos_disable_host_monitoring >/dev/null
    [[ ! -s "$TMP/calls" ]] || fail "Matching pre-existing values must not be changed or removed"
    [[ ! -d "$COS_STATE_DIR/host-config" ]] || fail "Pre-existing values must not be claimed"
)
(
    declare -A HOST=([core.metrics_authentication]=false [loki.instance]=lxd)
    host_config_stub
    LXD_JOB=lxd
    cos_enable_host_metrics
    cos_enable_host_logs
    : > "$TMP/calls"
    cos_disable_host_monitoring
    [[ "$(cat "$TMP/calls")" == $'unset loki.api.url\nunset core.metrics_address' ]] ||
        fail "Cleanup must only unset keys written by the demo"
    [[ "${HOST[core.metrics_authentication]}" == false && "${HOST[loki.instance]}" == lxd ]] ||
        fail "Pre-existing secondary values must be preserved"
)

# An ownership record must be saved before changing host configuration.
(
    declare -A HOST=()
    host_config_stub
    printf 'not a directory\n' > "$COS_STATE_DIR/host-config"
    if cos_enable_host_metrics >/dev/null 2>&1; then
        fail "An unwritable ownership record must fail installation"
    fi
    [[ ! -s "$TMP/calls" ]] || fail "Do not change host settings without a persistent ownership record"
)
(
    declare -A HOST=()
    host_config_stub
    cos_lxc() { [[ "$1 $2" == "config get" ]]; }
    if cos_host_set core.metrics_authentication false; then
        fail "A failed LXD write must fail installation"
    fi
    [[ ! -f "$COS_STATE_DIR/host-config/core.metrics_authentication" ]] ||
        fail "A rejected write must not claim ownership"
)

# LXD checks Loki's /ready once, so a briefly unready Loki is retried.
(
    declare -A HOST=()
    host_config_stub
    LXD_JOB=lxd
    sleep() { echo "sleep" >> "$TMP/calls"; }
    cos_lxc() {
        case "$1 $2 ${4%%=*}" in
            "config get "*) echo "" ;;
            "config set loki.api.url")
                echo "url" >> "$TMP/calls"
                [[ "$(grep -c '^url$' "$TMP/calls")" -ge 3 ]] ;;
            "config set "*) : ;;
        esac
    }
    : > "$TMP/calls"
    cos_enable_host_logs
    [[ "$(grep -c '^url$' "$TMP/calls")" == 3 ]] || fail "An unready Loki must be retried until LXD accepts it"
    cos_lxc() { [[ "$1 $2" != "config set" || "$4" == loki.instance=* ]]; }
    if output="$(cos_enable_host_logs 2>&1)"; then
        fail "A Loki that never becomes ready must fail"
    fi
    assert_contains "$output" "could not reach Loki"
)

# Cleanup checks every key independently, including operator changes after installation.
(
    declare -A HOST=()
    host_config_stub
    LXD_JOB=lxd
    cos_enable_host_metrics
    cos_enable_host_logs
    HOST[core.metrics_authentication]=true
    HOST[loki.instance]=operator-label
    : > "$TMP/calls"
    cos_disable_host_monitoring > "$TMP/result"
    [[ "$(cat "$TMP/calls")" == $'unset loki.api.url\nunset core.metrics_address' ]] ||
        fail "Changed authentication and instance label must be preserved"
    [[ "${HOST[core.metrics_authentication]}" == true && "${HOST[loki.instance]}" == operator-label ]] ||
        fail "Cleanup must keep the operator's secondary values"
    assert_contains "$(cat "$TMP/result")" "core.metrics_authentication"
    assert_contains "$(cat "$TMP/result")" "loki.instance"
)
(
    declare -A HOST=()
    host_config_stub
    LXD_JOB=lxd
    cos_enable_host_metrics
    cos_enable_host_logs
    HOST[core.metrics_address]=":9100"
    HOST[loki.api.url]="http://other-loki:3100"
    : > "$TMP/calls"
    cos_disable_host_monitoring >/dev/null
    [[ "${HOST[core.metrics_address]}" == ":9100" && "${HOST[loki.api.url]}" == "http://other-loki:3100" ]] ||
        fail "Changed endpoints must be preserved"
    [[ "$(cat "$TMP/calls")" != *"unset core.metrics_address"* && "$(cat "$TMP/calls")" != *"unset loki.api.url"* ]] ||
        fail "Changed endpoints must not be unset"
)

# Unreadable/failed resets retain ownership records so destroy can be retried.
(
    declare -A HOST=()
    host_config_stub
    cos_enable_host_metrics
    cos_lxc() { return 1; }
    if cos_disable_host_monitoring >/dev/null 2>&1; then
        fail "Unreadable host settings must fail the reset"
    fi
    [[ -f "$COS_STATE_DIR/host-config/core.metrics_address" ]] || fail "Failed cleanup must keep ownership records"
    cos_lxc() {
        [[ "$1 $2" == "config get" ]] && { echo "${HOST[$4]:-}"; return 0; }
        return 1
    }
    if cos_disable_host_monitoring >/dev/null 2>&1; then
        fail "A failed unset must fail the reset"
    fi
    [[ -f "$COS_STATE_DIR/host-config/core.metrics_address" ]] || fail "Failed unset must be retriable"
)

# A partial install may have set only the instance label before the Loki connection fails.
(
    declare -A HOST=()
    host_config_stub
    cos_host_set loki.instance lxd
    : > "$TMP/calls"
    cos_disable_host_monitoring
    [[ "$(cat "$TMP/calls")" == "unset loki.instance" ]] || fail "Cleanup must undo partial installs"
)

# The guest output is logged, and failures propagate through tee.
(
    SCRIPT_DIR="$REPO_ROOT"
    : > "$TMP/calls"
    cos_lxc() {
        case "$1 $2" in
            "file push") echo "push $4" >> "$TMP/calls" ;;
            "file pull") fail "Access data must not be pulled after a failed setup" ;;
            exec*) echo "$*" >> "$TMP/calls"; echo "guest output"; return 3 ;;
        esac
    }
    if cos_run_setup >/dev/null; then
        fail "Guest setup failure must propagate through tee"
    fi
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "push local:lab-cos/root/cos.env"
    assert_contains "$calls" "push local:lab-cos/root/cos-setup.sh"
    assert_contains "$calls" "exec local:lab-cos -- bash /root/cos-setup.sh"
    assert_contains "$(cat "$COS_STATE_DIR/setup.log")" "guest output"

    cos_lxc() {
        case "$1 $2" in
            "file pull") printf 'COS_IP=172.31.7.200\n' > "$4" ;;
        esac
    }
    cos_run_setup >/dev/null
    [[ "$(stat -c %a "$COS_ACCESS")" == "600" ]] || fail "Access data must be private"
    rm -f "$COS_ACCESS"
)

# The web check needs HTTP 200 from Catalogue and Grafana.
(
    COS_IP=172.31.7.200
    curl() {
        [[ "$*" == *"--noproxy"* ]] || fail "The web check must bypass proxies"
        echo 200
    }
    cos_check_web
    curl() { [[ "${*: -1}" == *catalogue ]] && echo 200 || echo 502; }
    if cos_check_web >/dev/null 2>&1; then
        fail "An unhealthy Grafana must fail the web check"
    fi
    curl() { return 7; }
    if cos_check_web >/dev/null 2>&1; then
        fail "An unreachable COS must fail the web check"
    fi
)

install_stubs() {
    cos_prepare_settings() { :; }
    cos_ensure_infrastructure() { echo "infra" >> "$TMP/calls"; }
    cos_enable_host_metrics() { echo "metrics" >> "$TMP/calls"; }
    cos_run_setup() {
        echo "setup" >> "$TMP/calls"
        printf 'COS_IP=172.31.7.200\nGRAFANA_PASSWORD=Secret123\nLXD_JOB=lxd\nDASHBOARD_PATH=/cos-grafana/d/lxd/lxd\n' > "$COS_ACCESS"
    }
    cos_enable_host_logs() { echo "logs $LXD_JOB" >> "$TMP/calls"; }
    cos_check_web() { echo "web" >> "$TMP/calls"; }
    cos_lxc() { return 1; }
}

(
    install_stubs
    : > "$TMP/calls"
    output="$(cos_install)"
    assert_contains "$(cat "$TMP/calls")" $'infra\nmetrics\nsetup\nlogs lxd\nweb'
    assert_contains "$output" "COS Lite demo is ready"
    assert_contains "$output" "http://172.31.7.200/cos-grafana/d/lxd/lxd"
    assert_contains "$output" "admin / Secret123"
    assert_contains "$output" "172.31.7.1:8444"
)

(
    install_stubs
    cos_check_web() { return 1; }
    if output="$(cos_install 2>&1)"; then
        fail "An unreachable COS must fail the install"
    fi
    [[ "$output" != *"demo is ready"* ]] || fail "An unreachable COS must not be reported as ready"
)

(
    install_stubs
    cos_run_setup() { return 1; }
    cos_enable_host_logs() { fail "Loki must not be configured after a failed setup"; }
    if output="$(cos_install 2>&1)"; then
        fail "A failed guest setup must fail the install"
    fi
    assert_contains "$output" "rerun menu 11"
)

(
    install_stubs
    mv "$COS_SETTINGS" "$TMP/settings.bak"
    cos_lxc() { [[ "$*" == "info local:lab-cos" ]]; }
    cos_ensure_infrastructure() { fail "A VM without settings must not be reused"; }
    if cos_install >/dev/null 2>&1; then
        fail "A VM without saved settings must be refused"
    fi
    mv "$TMP/settings.bak" "$COS_SETTINGS"
)

# Instance and bridge: created with the owner label, or refused when someone else owns them.
(
    export LXD_STORAGE_POOL=demo-pool
    : > "$TMP/calls"
    cos_lxc() {
        echo "$*" >> "$TMP/calls"
        case "$1 $2" in
            "network show"|"info local:lab-cos") return 1 ;;
        esac
        return 0
    }
    cos_ensure_infrastructure >/dev/null
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "network create local:lab-cosbr0 ipv4.address=172.31.7.1/24 ipv4.nat=true"
    assert_contains "$calls" "ipv4.dhcp.ranges=172.31.7.10-172.31.7.99 user.lab-automation.component=cos-demo"
    assert_contains "$calls" "launch ubuntu:24.04 local:lab-cos --vm --network lab-cosbr0 --storage demo-pool"
    assert_contains "$calls" "-c limits.cpu=4 -c limits.memory=12GiB -d root,size=60GiB -c user.lab-automation.component=cos-demo"

    cos_lxc() {
        case "$1 $2" in
            "network show") return 0 ;;
            "network get") echo "someone-else" ;;
            *) fail "An unowned bridge must stop the install: $*" ;;
        esac
    }
    if cos_ensure_infrastructure >/dev/null 2>&1; then
        fail "An unowned bridge must be refused"
    fi
)

# Destroy: keep everything when LXD is down or a resource is not ours.
(
    cos_lxc() { return 1; }
    if output="$(cos_destroy 2>&1)"; then
        fail "Destroy must fail when LXD is unavailable"
    fi
    assert_contains "$output" "Local LXD is unavailable"
    [[ -f "$COS_SETTINGS" ]] || fail "Unavailable LXD must not delete the settings"

    cos_lxc() {
        case "$1 $2" in
            "info local:"|"info local:lab-cos"|"network show") return 0 ;;
            "config get") echo "cos-demo" ;;
            "network get") echo "someone-else" ;;
            *) fail "An unowned bridge must prevent all changes: $*" ;;
        esac
    }
    if cos_destroy >/dev/null 2>&1; then
        fail "An unowned bridge must be refused"
    fi
    [[ -f "$COS_SETTINGS" ]] || fail "A refused destroy must keep the settings"
)

destroy_stub() {
    cos_lxc() {
        echo "$*" >> "$TMP/calls"
        case "$1 $2" in
            "config get")
                case "$4" in
                    loki.api.url) echo "http://172.31.7.200/cos-loki-0" ;;
                    loki.instance) echo "${DESTROY_INSTANCE:-lxd}" ;;
                    core.metrics_address) echo "172.31.7.1:8444" ;;
                    core.metrics_authentication) echo "${DESTROY_AUTH:-false}" ;;
                    *) echo "cos-demo" ;;
                esac ;;
            "network get")
                [[ "$4" == "ipv4.address" ]] && echo "172.31.7.1/24" || echo "cos-demo" ;;
        esac
        return 0
    }
}
seed_owned_records() {
    local key
    mkdir -p "$COS_STATE_DIR/host-config"
    for key in loki.api.url loki.instance core.metrics_address core.metrics_authentication; do
        cos_lxc config get local: "$key" > "$COS_STATE_DIR/host-config/$key"
    done
}
(
    destroy_stub
    seed_owned_records
    : > "$TMP/calls"
    printf 'COS_IP=172.31.7.200\n' > "$COS_ACCESS"
    output="$(cos_destroy)"
    calls="$(cat "$TMP/calls")"
    for key in loki.api.url loki.instance core.metrics_address core.metrics_authentication; do
        assert_contains "$calls" "config unset local: $key"
    done
    assert_contains "$calls" $'delete --force local:lab-cos\nnetwork delete local:lab-cosbr0'
    [[ ! -f "$COS_SETTINGS" && ! -f "$COS_ACCESS" ]] || fail "Destroy must remove the saved COS data"
    assert_contains "$output" "COS Lite demo removed"

    # Ownership records suffice even without settings.env or access.env.
    seed_owned_records
    : > "$TMP/calls"
    cos_destroy >/dev/null
    assert_contains "$(cat "$TMP/calls")" "config unset local: core.metrics_address"
    assert_contains "$(cat "$TMP/calls")" "config unset local: loki.instance"

    seed_owned_records
    DESTROY_AUTH=true
    DESTROY_INSTANCE=operator-label
    : > "$TMP/calls"
    output="$(cos_destroy)"
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "delete --force local:lab-cos"
    [[ "$calls" != *"config unset local: core.metrics_authentication"* ]] || fail "Destroy must preserve changed authentication"
    [[ "$calls" != *"config unset local: loki.instance"* ]] || fail "Destroy must preserve a changed instance label"
    assert_contains "$output" "core.metrics_authentication changed"
    assert_contains "$output" "loki.instance changed"

    # Never infer ownership from a matching endpoint when records are missing.
    : > "$TMP/calls"
    output="$(cos_destroy)"
    [[ "$(cat "$TMP/calls")" != *"config unset"* ]] || fail "Without records, destroy must preserve every host key"
    assert_contains "$output" "No saved COS ownership record"
)
(
    destroy_stub
    seed_owned_records
    cos_lxc() { return 1; }
    cos_installed || fail "Leftover host ownership records must remain discoverable for cleanup"
    cos_owned() { :; }
    cos_lxc() {
        echo "$*" >> "$TMP/calls"
        [[ "$1 $2" != "config get" ]]
    }
    : > "$TMP/calls"
    if cos_destroy >/dev/null 2>&1; then
        fail "Host cleanup failure must abort destroy"
    fi
    [[ "$(cat "$TMP/calls")" != *"delete"* ]] || fail "Failed host cleanup must keep the VM and bridge"
    [[ -f "$COS_STATE_DIR/host-config/loki.api.url" ]] || fail "Failed destroy must retain ownership records"
)

# Overview.
(
    cos_lxc() { echo "RUNNING"; }
    printf 'COS_IP=172.31.7.200\nGRAFANA_PASSWORD=Secret123\nLXD_JOB=lxd\nDASHBOARD_PATH=/cos-grafana/d/lxd/lxd\n' > "$COS_ACCESS"
    output="$(lab_overview_cos)"
    assert_contains "$output" "http://172.31.7.200/cos-catalogue (VM: RUNNING)"
    assert_contains "$output" "admin / Secret123"
    assert_contains "$output" "http://172.31.7.200/cos-grafana/d/lxd/lxd"
    rm -f "$COS_ACCESS"
    output="$(lab_overview_cos)"
    assert_contains "$output" "installation not finished"
    cos_lxc() { return 1; }
    output="$(lab_overview_cos)"
    assert_contains "$output" "not installed (menu 11)"
)
sed -n '/^lab_overview() {/,/^}/p' "${REPO_ROOT}/scripts/lab_overview.sh" | grep -qx '    lab_overview_cos' ||
    fail "The lab overview must show the COS demo"

# Menu wiring.
(
    : > "$TMP/calls"
    tofu() { :; }
    cm_installed() { return 1; }
    landscape_instances() { :; }
    LANDSCAPE_SETTINGS="$TMP/missing"
    cos_installed() { return 0; }
    cos_destroy() { echo "cos removed" >> "$TMP/calls"; }
    output="$(destroy_menu <<< $'1\nyes' 2>&1)" || fail "COS destroy must succeed"
    assert_contains "$output" "COS Lite demo (lab-cos + lab-cosbr0)"
    assert_contains "$output" "resets only unchanged host LXD settings recorded by this demo"
    assert_contains "$(cat "$TMP/calls")" "cos removed"

    : > "$TMP/calls"
    output="$(destroy_menu <<< $'1\nno' 2>&1)" || fail "Cancelling must not fail"
    [[ ! -s "$TMP/calls" ]] || fail "Only 'yes' may destroy the COS demo"
)
grep -q '^echo " 11) COS Lite' "${REPO_ROOT}/orchestrate.sh" || fail "Menu option 11 must install COS Lite"
grep -A2 'action" == "11"' "${REPO_ROOT}/orchestrate.sh" | grep -q cos_install || fail "Option 11 must call cos_install"

# Guest script: pinned COS Lite track, LXD scrape job and dashboard import.
guest="${REPO_ROOT}/scripts/cos_guest.sh"
bash -n "$guest" || fail "Guest script has a syntax error"
grep -q 'COS_LITE_REF="track/3.1"' "$guest" || fail "COS Lite must use the pinned Terraform track"
grep -q 'metrics_path=/1.0/metrics' "$guest" || fail "Prometheus must scrape the LXD metrics path"
grep -q 'dashboards/import' "$guest" || fail "The LXD dashboard must be imported"
steps="$(grep -c '^step "' "$guest")"
grep -q "\[\${STEP}/${steps}\]" "$guest" || fail "Step counter must match the ${steps} steps"

echo "PASS: COS settings, host LXD metrics/Loki ownership, setup logging, web check, install order, destroy safety, overview and menu wiring"
