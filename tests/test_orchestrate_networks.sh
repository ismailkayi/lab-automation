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

deleted_network=""
mock_owner="another_workspace"
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
        return 0
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

delete_owned_microcloud_network "mc-demo-test-up" "demo_workspace" >/dev/null
assert_equal "" "$deleted_network" "unowned network cleanup"

mock_owner="demo_workspace"
delete_owned_microcloud_network "mc-demo-test-up" "demo_workspace" >/dev/null
assert_equal "mc-demo-test-up" "$deleted_network" "owned network cleanup"

echo "All orchestrator network helper tests passed."
