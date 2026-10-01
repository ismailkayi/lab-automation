#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../orchestrate.sh
source "${REPO_ROOT}/orchestrate.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    [[ "$actual" == "$expected" ]] || fail "${description}: expected '${expected}', got '${actual}'"
}

assert_equal "172.28.44.19" "$(cidr_host_address "172.28.44.0/24" 19)" "CIDR host allocation"

validate_microcloud_cidr "172.28.44.0/24" 10 \
    || fail "a /24 should support ten MicroCloud node addresses"
validate_microcloud_cidr "10.10.0.0/28" 3 \
    || fail "a /28 should support three MicroCloud node addresses"

if validate_microcloud_cidr "10.10.0.1/24" 3 >/dev/null 2>&1; then
    fail "a CIDR with host bits set must be rejected"
fi
if validate_microcloud_cidr "10.10.0.0/28" 10 >/dev/null 2>&1; then
    fail "a subnet without enough node addresses must be rejected"
fi
if validate_microcloud_cidr "2001:db8::/64" 3 >/dev/null 2>&1; then
    fail "an IPv6 subnet must be rejected"
fi

subnets_overlap "172.28.44.0/24" "172.28.44.128/25" \
    || fail "overlapping subnets were not detected"
if subnets_overlap "172.28.44.0/24" "172.29.44.0/24"; then
    fail "separate subnets were reported as overlapping"
fi

list_host_ipv4_subnets() {
    printf '%s\n' "10.20.0.0/16" "192.168.50.0/24"
}

assert_microcloud_subnet_available "172.28.44.0/24" "test plane" \
    || fail "an unused subnet was reported as unavailable"
if assert_microcloud_subnet_available "10.20.30.0/24" "test plane" >/dev/null; then
    fail "a host-overlapping subnet was reported as available"
fi

uplink_name="$(resolve_microcloud_uplink_network_name "demo_microcloud")"
ovn_name="$(resolve_microcloud_plane_network_name "demo_microcloud" "ovn")"
ceph_name="$(resolve_microcloud_plane_network_name "demo_microcloud" "ceph")"

[[ "$uplink_name" =~ ^mc-demo-[0-9a-f]{4}-up$ ]] \
    || fail "uplink network name is not LXD-safe and deterministic"
assert_equal "${uplink_name%-up}-ov" "$ovn_name" "OVN network name"
assert_equal "${uplink_name%-up}-ce" "$ceph_name" "Ceph network name"
(( ${#uplink_name} <= 15 )) || fail "uplink network name exceeds the LXD limit"
(( ${#ovn_name} <= 15 )) || fail "OVN network name exceeds the LXD limit"
(( ${#ceph_name} <= 15 )) || fail "Ceph network name exceeds the LXD limit"

mapfile -t generated_labs < <(generate_batch_lab_names "student" 12 "microcloud")
assert_equal "student01 student01_microcloud inventory_student01_microcloud.yaml" "${generated_labs[0]}" "first batch lab name"
assert_equal "student12 student12_microcloud inventory_student12_microcloud.yaml" "${generated_labs[11]}" "last batch lab name"
assert_equal "8" "$(normalize_decimal "08")" "leading-zero decimal normalization"
if normalize_decimal "8labs" >/dev/null 2>&1; then
    fail "non-numeric batch input must be rejected"
fi
assert_equal "8" "$(cpu_limit_to_count "8")" "numeric CPU limit"
assert_equal "6" "$(cpu_limit_to_count "0-3,6,8")" "CPU set limit"
assert_equal "12288" "$(memory_limit_to_mib "12GiB")" "GiB memory conversion"
assert_equal "4096" "$(memory_limit_to_mib "4096MiB")" "MiB memory conversion"

scenario="microcloud"
DEPLOYMENT_MODE="full"
MICROCLOUD_NODE_COUNT=3
MICROCLOUD_NODE_CPU=8
MICROCLOUD_NODE_MEMORY_MB=12288
MICROCLOUD_ROOT_DISK_GIB=40
MICROCLOUD_CEPH_DISK_GIB=50
MICROCLOUD_LOCAL_DISK_GIB=20
assert_equal "36 288 442368 3240" "$(get_batch_resource_request 12)" "full MicroCloud batch resources"
DEPLOYMENT_MODE="training"
assert_equal "36 288 442368 3960" "$(get_batch_resource_request 12)" "training MicroCloud batch resources"
DEPLOYMENT_MODE="full"

deleted_network=""
mock_owner="another_workspace"
mock_network_exists=true
lxc() {
    if [[ "$1 $2 $3" == "config device get" ]]; then
        if [[ "$5" == "eth1" && "$6" == "hwaddr" ]]; then
            echo "02:00:aa:bb:cc:dd"
        fi
        return 0
    fi
    if [[ "$1" == "exec" ]]; then
        cat <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 link/loopback 00:00:00:00:00:00
2: enp6s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 link/ether 02:00:aa:bb:cc:dd
EOF
        return 0
    fi
    if [[ "$1 $2" == "network show" ]]; then
        [[ "$mock_network_exists" == true ]]
        return
    fi
    if [[ "$1 $2" == "network get" ]]; then
        echo "$mock_owner"
        return 0
    fi
    if [[ "$1 $2" == "network delete" ]]; then
        deleted_network="$3"
        return 0
    fi
    fail "unexpected mocked lxc command: $*"
}

assert_equal "enp6s0" "$(get_guest_interface_for_device "demo-node-1" "eth1")" "guest interface MAC mapping"

mock_network_exists=false
delete_owned_microcloud_network "mc-missing-up" "demo_workspace" >/dev/null \
    || fail "a missing network must be a successful cleanup no-op"
assert_equal "" "$deleted_network" "missing network cleanup"

mock_network_exists=true
delete_owned_microcloud_network "mc-demo-test-up" "demo_workspace" >/dev/null
assert_equal "" "$deleted_network" "unowned network cleanup"

mock_owner="demo_workspace"
delete_owned_microcloud_network "mc-demo-test-up" "demo_workspace" >/dev/null
assert_equal "mc-demo-test-up" "$deleted_network" "owned network cleanup"

BATCH_WORKSPACE_NAMES=(batch01_microcloud batch02_microcloud batch03_microcloud)
MICROCLOUD_NODE_COUNT=3
allocate_batch_microcloud_cidrs
assert_equal "3" "${#BATCH_OVN_UNDERLAY_CIDRS[@]}" "batch OVN CIDR count"
assert_equal "3" "${#BATCH_CEPH_GENERAL_CIDRS[@]}" "batch Ceph CIDR count"
[[ "${BATCH_OVN_UNDERLAY_CIDRS[0]}" != "${BATCH_OVN_UNDERLAY_CIDRS[1]}" ]] \
    || fail "batch OVN CIDRs must be unique"
[[ "${BATCH_CEPH_GENERAL_CIDRS[0]}" != "${BATCH_CEPH_GENERAL_CIDRS[1]}" ]] \
    || fail "batch Ceph CIDRs must be unique"

mock_workspace_exists=true
mock_default_select_succeeds=true
mock_workspace_delete_succeeds=true
tofu() {
    if [[ "${1:-} ${2:-} ${3:-}" == "workspace select default" ]]; then
        [[ "$mock_default_select_succeeds" == true ]]
        return
    fi
    if [[ "${1:-} ${2:-}" == "workspace delete" ]]; then
        if [[ "$mock_workspace_delete_succeeds" == true ]]; then
            mock_workspace_exists=false
            return 0
        fi
        return 1
    fi
    if [[ "${1:-} ${2:-}" == "workspace list" ]]; then
        echo "default"
        if [[ "$mock_workspace_exists" == true ]]; then
            echo "demo_workspace"
        fi
        return 0
    fi
    fail "unexpected mocked tofu command: $*"
}

mock_default_select_succeeds=false
if delete_tofu_workspace "demo_workspace" >/dev/null; then
    fail "workspace cleanup must fail if selecting default fails"
fi
[[ "$mock_workspace_exists" == true ]] || fail "failed default selection must preserve the workspace"

mock_default_select_succeeds=true
mock_workspace_delete_succeeds=false
if delete_tofu_workspace "demo_workspace" >/dev/null; then
    fail "workspace cleanup must fail if workspace deletion fails"
fi
[[ "$mock_workspace_exists" == true ]] || fail "failed deletion must preserve the workspace"

mock_workspace_delete_succeeds=true
delete_tofu_workspace "demo_workspace" >/dev/null \
    || fail "an empty workspace should be deleted successfully"
[[ "$mock_workspace_exists" == false ]] || fail "successful cleanup must remove the workspace"

get_host_cpu_count() { echo 96; }
get_host_memory_mib() { echo 524288; }
get_existing_lxd_commitments() { echo "0 0"; }
get_batch_resource_request() { echo "36 288 442368 3240"; }
get_management_network_capacity() { echo 253; }
count_management_network_instances() { echo 0; }
get_storage_available_gib() { echo 2000; }
BATCH_LAB_COUNT=12
assert_equal "4" "$BATCH_CPU_OVERCOMMIT_LIMIT" "automatic CPU overcommit ceiling"
BATCH_RAM_OVERHEAD_PERCENT=15
print_batch_capacity_plan >/dev/null \
    || fail "the intended 12-lab 3:1 CPU and non-overcommitted RAM plan should pass"

get_batch_resource_request() { echo "36 385 442368 3240"; }
if print_batch_capacity_plan >/dev/null; then
    fail "a batch above the internal 4:1 CPU commit ceiling must fail"
fi

get_batch_resource_request() { echo "36 288 460000 3240"; }
if print_batch_capacity_plan >/dev/null; then
    fail "a batch above the physical RAM budget must fail"
fi

deploy_lab() {
    if [[ "$1" == "student02" ]]; then
        return 1
    fi
}

BATCH_LAB_COUNT=3
BATCH_USER_PREFIXES=(student01 student02 student03)
BATCH_WORKSPACE_NAMES=(student01_microcloud student02_microcloud student03_microcloud)
BATCH_INVENTORY_FILES=(inventory_student01_microcloud.yaml inventory_student02_microcloud.yaml inventory_student03_microcloud.yaml)
BATCH_OVN_UNDERLAY_CIDRS=()
BATCH_CEPH_GENERAL_CIDRS=()
if run_batch_deployments >/tmp/test-batch-summary.log 2>&1; then
    fail "a failed batch lab must fail the batch"
fi
grep -q 'student01.*SUCCESS' /tmp/test-batch-summary.log \
    || fail "batch summary must report the successful lab"
grep -q 'student02.*FAILED' /tmp/test-batch-summary.log \
    || fail "batch summary must report the failed lab"
grep -q 'student03.*NOT STARTED' /tmp/test-batch-summary.log \
    || fail "batch summary must report labs not started after a failure"
rm -f /tmp/test-batch-summary.log

echo "All orchestrator network helper tests passed."
