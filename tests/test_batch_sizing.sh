#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../orchestrate.sh
source "${REPO_ROOT}/orchestrate.sh"

TEST_LOG=$(mktemp /tmp/lab-batch-sizing.XXXXXX)
trap 'rm -f -- "$TEST_LOG"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_equal() {
    [[ "$2" == "$1" ]] || fail "$3: expected '$1', got '$2'"
}

expect_failure() {
    local message="$1"
    shift
    if ("$@") >"$TEST_LOG" 2>&1; then
        fail "expected failure from $*"
    fi
    grep -Fq "$message" "$TEST_LOG" || fail "missing failure diagnostic: $message"
}

mock_host_cpu=96
mock_host_memory_mib=524288
mock_instances=""
mock_cpu=4
mock_memory="2GiB"
mock_list_failure=false
mock_config_failure=false

get_host_cpu_count() { echo "$mock_host_cpu"; }
get_host_memory_mib() { echo "$mock_host_memory_mib"; }
get_storage_available_gib() { echo 2000; }
get_management_network_capacity() { echo 253; }
count_management_network_instances() { echo 0; }

lxc() {
    if [[ "${1:-}" == "list" ]]; then
        [[ "$mock_list_failure" == false ]] || return 1
        printf '%s\n' "$mock_instances"
        return 0
    fi
    if [[ "${1:-} ${2:-}" == "config get" ]]; then
        [[ "$mock_config_failure" == false ]] || return 1
        [[ "$3" == "foreign-node" ]] || fail "resumed batch nodes must not be counted twice"
        case "$4" in
            limits.cpu) echo "$mock_cpu" ;;
            limits.memory) echo "$mock_memory" ;;
            *) fail "unexpected limit query: $*" ;;
        esac
        return 0
    fi
    fail "unexpected LXD command: $*"
}

DEPLOYMENT_SCOPE=batch
DEPLOYMENT_MODE=full
scenario=microcloud
BATCH_LAB_COUNT=12
BATCH_WORKSPACE_NAMES=(student01_microcloud)
MICROCLOUD_NODE_COUNT=3

assert_equal "4" "$BATCH_CPU_OVERCOMMIT_LIMIT" "internal CPU ceiling"
assert_equal "96 524288 384 455902 0 0" "$(get_batch_capacity)" "empty-host capacity"
assert_equal "32 37991" "$(get_batch_sizing_budget)" "per-lab CPU/RAM budgets"

mock_instances=$'foreign-node\nstudent01-microcloud-node-1'
assert_equal "4 2048" "$(get_existing_lxd_commitments)" "foreign and resumed allocations"
mock_list_failure=true
expect_failure "Could not list existing LXD instances" get_batch_capacity
mock_list_failure=false
mock_config_failure=true
expect_failure "Could not read effective resource limits" get_batch_capacity
mock_config_failure=false
mock_cpu=""
expect_failure "needs explicit, readable CPU and memory limits" get_batch_capacity
mock_cpu=4
mock_memory="unknown"
expect_failure "needs explicit, readable CPU and memory limits" get_batch_capacity
mock_instances=""
mock_memory="2GiB"

expect_failure "CPU limit must be positive" cpu_limit_to_count "0"
expect_failure "Cannot interpret CPU limit" cpu_limit_to_count "3-0"
expect_failure "Cannot interpret memory limit" memory_limit_to_mib ""
assert_equal "1" "$(memory_limit_to_mib "1B")" "memory commitment rounded up"

mock_host_cpu=0
expect_failure "Invalid host capacity" get_batch_sizing_budget
mock_host_cpu=96
mock_host_memory_mib=3072
expect_failure "No remaining host CPU/RAM budget" get_batch_sizing_budget
mock_host_memory_mib=524288

for profile in conservative balanced performance; do
    configure_microcloud_sizing 3 >"$TEST_LOG" <<< "$profile"
    print_batch_capacity_plan >>"$TEST_LOG"
done
configure_microcloud_sizing 3 >"$TEST_LOG" <<< "balanced"
assert_equal "8" "$MICROCLOUD_NODE_CPU" "12-lab balanced CPU recommendation"
assert_equal "12288" "$MICROCLOUD_NODE_MEMORY_MB" "12-lab balanced RAM recommendation"
assert_equal "36 288 442368 2160" "$(get_batch_resource_request 12)" "aggregate balanced resources"
print_batch_capacity_plan >>"$TEST_LOG"
grep -Fq "288 vCPU (3.00:1)" "$TEST_LOG" || fail "actual CPU sharing must be reported"

BATCH_LAB_COUNT=2
configure_microcloud_sizing 3 >"$TEST_LOG" <<< "balanced"
larger_cpu="$MICROCLOUD_NODE_CPU"
larger_memory="$MICROCLOUD_NODE_MEMORY_MB"
BATCH_LAB_COUNT=12
configure_microcloud_sizing 3 >"$TEST_LOG" <<< "balanced"
(( MICROCLOUD_NODE_CPU < larger_cpu && MICROCLOUD_NODE_MEMORY_MB < larger_memory )) \
    || fail "more labs must receive smaller recommendations"

mock_instances="foreign-node"
mock_cpu=96
mock_memory="64GiB"
configure_microcloud_sizing 3 >"$TEST_LOG" <<< "balanced"
assert_equal "6" "$MICROCLOUD_NODE_CPU" "existing CPU allocations reduce recommendations"
assert_equal "8192" "$MICROCLOUD_NODE_MEMORY_MB" "existing RAM allocations reduce recommendations"
mock_instances=""

configure_microcloud_sizing 3 >"$TEST_LOG" <<< $'custom\n8\n12\n40\n50'
assert_equal "8" "$MICROCLOUD_NODE_CPU" "custom MicroCloud CPU preserved"
assert_equal "12288" "$MICROCLOUD_NODE_MEMORY_MB" "custom MicroCloud RAM preserved"
print_batch_capacity_plan >>"$TEST_LOG"
expect_failure "33 vCPU per lab" configure_microcloud_sizing 3 <<< $'custom\n11\n12\n40\n50'
expect_failure "49152 MiB RAM per lab" configure_microcloud_sizing 3 <<< $'custom\n8\n16\n40\n50'

MICROCLOUD_NODE_COUNT=4
MICROCLOUD_NODE_CPU=8
MICROCLOUD_NODE_MEMORY_MB=8192
print_batch_capacity_plan >"$TEST_LOG"
grep -Fq "384 vCPU (4.00:1)" "$TEST_LOG" || fail "exact 4:1 boundary should pass"
mock_instances="foreign-node"
mock_cpu=1
mock_memory="1MiB"
expect_failure "exceeds the internal 4:1 ceiling" print_batch_capacity_plan
mock_instances=""

BATCH_LAB_COUNT=2
MICROCLOUD_NODE_COUNT=3
MICROCLOUD_NODE_CPU=1
MICROCLOUD_NODE_MEMORY_MB=1024
mock_instances="foreign-node"
mock_cpu=1
mock_memory="$((455902 - 6 * 1024))MiB"
print_batch_capacity_plan >"$TEST_LOG"
mock_memory="$((455902 - 6 * 1024 + 1))MiB"
expect_failure "exceeds the host VM budget" print_batch_capacity_plan
mock_instances=""

BATCH_LAB_COUNT=12
scenario=k8s-snap
k8s_control_plane_count=3
k8s_worker_count=1
for profile in conservative balanced performance; do
    configure_k8s_sizing 3 1 >"$TEST_LOG" <<< "$profile"
    print_batch_capacity_plan >>"$TEST_LOG"
done
expect_failure "Values were not resized" configure_k8s_sizing 3 1 <<< $'custom\n11\n8\n1\n8'
configure_k8s_sizing 3 1 >"$TEST_LOG" <<< $'custom\n4\n8\n4\n4'
assert_equal "4 8 4 4" \
    "$K8S_CONTROL_PLANE_CPU $K8S_CONTROL_PLANE_MEMORY_GIB $K8S_WORKER_CPU $K8S_WORKER_MEMORY_GIB" \
    "custom Kubernetes sizing preserved"

scenario=k8s-juju
k8s_juju_cp_count=1
k8s_juju_worker_count=1
assert_equal "30 33895" "$(get_batch_sizing_budget)" "Juju controller cost reserved before sizing"
for profile in conservative balanced performance; do
    configure_k8s_sizing 1 1 >"$TEST_LOG" <<< "$profile"
    K8S_JUJU_CP_CPU="$K8S_CONTROL_PLANE_CPU"
    K8S_JUJU_CP_MEMORY_GIB="$K8S_CONTROL_PLANE_MEMORY_GIB"
    K8S_JUJU_WORKER_CPU="$K8S_WORKER_CPU"
    K8S_JUJU_WORKER_MEMORY_GIB="$K8S_WORKER_MEMORY_GIB"
    print_batch_capacity_plan >>"$TEST_LOG"
done
expect_failure "Values were not resized" configure_k8s_sizing 1 1 <<< $'custom\n16\n8\n16\n8'

mock_host_cpu=2
mock_host_memory_mib=12288
BATCH_LAB_COUNT=2
scenario=microcloud
configure_microcloud_sizing 3 >"$TEST_LOG" <<< "balanced"
assert_equal "1 1024" "$MICROCLOUD_NODE_CPU $MICROCLOUD_NODE_MEMORY_MB" "small batch minimum sizing"
scenario=k8s-snap
configure_k8s_sizing 1 1 >"$TEST_LOG" <<< "balanced"
assert_equal "2 2 1 1" \
    "$K8S_CONTROL_PLANE_CPU $K8S_CONTROL_PLANE_MEMORY_GIB $K8S_WORKER_CPU $K8S_WORKER_MEMORY_GIB" \
    "small Kubernetes recommendations fit the remaining capacity"

mock_host_cpu=96
mock_host_memory_mib=524288
DEPLOYMENT_SCOPE=single
scenario=microcloud
configure_microcloud_sizing 3 >"$TEST_LOG" <<< "balanced"
assert_equal "24 131072" "$MICROCLOUD_NODE_CPU $MICROCLOUD_NODE_MEMORY_MB" "single MicroCloud sizing unchanged"
expect_failure "only 77 vCPU remain" configure_microcloud_sizing 3 <<< $'custom\n96\n12\n40\n50'
scenario=k8s-snap
configure_k8s_sizing 1 1 >"$TEST_LOG" <<< $'custom\n60\n2\n60\n2'
assert_equal "60 16" "$K8S_CONTROL_PLANE_CPU $K8S_WORKER_CPU" "single Kubernetes fitting unchanged"

mock_main_environment() {
    ensure_tools() { return 0; }
    detect_lxd_defaults() { LXD_NETWORK_NAME=mockbr0; LXD_STORAGE_POOL=default; }
    get_host_cpu_count() { echo 96; }
    get_host_memory_mib() { echo 524288; }
    get_storage_available_gib() { echo 2000; }
    list_host_ipv4_subnets() { echo "10.16.43.0/24"; }
    tofu() {
        case "${1:-} ${2:-}" in
            "init -input=false") return 0 ;;
            "workspace list") echo "default"; return 0 ;;
            *)
                echo "Unexpected infrastructure command: tofu $*" >&2
                return 1
                ;;
        esac
    }
    lxc() {
        case "${1:-} ${2:-}" in
            "list --format") return 0 ;;
            "network get")
                if [[ "$3" == "mockbr0" && "$4" == "ipv4.address" ]]; then
                    echo "10.16.43.1/24"
                fi
                return 0
                ;;
            "network show")
                [[ "$3" == "mockbr0" ]] || return 1
                echo "used_by: []"
                return 0
                ;;
            *)
                echo "Unexpected infrastructure command: lxc $*" >&2
                return 1
                ;;
        esac
    }
}

export REPO_ROOT
export -f mock_main_environment
expect_failure "Cancelled." env TERM=xterm bash -c 'source "$REPO_ROOT/orchestrate.sh"; mock_main_environment; main' \
    <<< $'4\n1\n2\n12\nautostudent\n3\n1\nbalanced\nno'
grep -q 'autostudent12.*new' "$TEST_LOG" || fail "batch name must follow count without a CPU ratio input"
grep -q 'CPU commit ceiling.*384 vCPU (4:1 internal limit)' "$TEST_LOG" \
    || fail "interactive batch must use the automatic ceiling"
grep -q 'Requested CPU.*288 vCPU' "$TEST_LOG" || fail "interactive MicroCloud recommendations must fit 12 labs"
expect_failure "Cancelled." env TERM=xterm bash -c 'source "$REPO_ROOT/orchestrate.sh"; mock_main_environment; main' \
    <<< $'5\n1\n2\n12\nautosnap\n3\n1\nbalanced\nno'
expect_failure "Cancelled." env TERM=xterm bash -c 'source "$REPO_ROOT/orchestrate.sh"; mock_main_environment; main' \
    <<< $'6\n1\n2\n12\nautojuju\n1\n1\nbalanced\nno'
grep -q 'Juju controller per lab.*already reserved' "$TEST_LOG" \
    || fail "interactive Juju sizing must include controller capacity"

if grep -q 'Maximum CPU overcommit ratio' "$REPO_ROOT/orchestrate.sh"; then
    fail "the CPU ratio prompt must not remain"
fi

echo "All automatic batch sizing tests passed."
