#!/bin/bash

# ==============================================================================
# CANONICAL LAB ORCHESTRATOR RUNNER (OpenTofu + Ansible)
# Phase 2: Multi-Environment, SSH Injection, Interactive Deletion
# ==============================================================================

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY_PATH="$HOME/.ssh/id_rsa_lab"
LXD_NETWORK_NAME=""
LXD_STORAGE_POOL=""
MICROCLOUD_NODE_CPU="2"
MICROCLOUD_NODE_MEMORY_MB="4096"
MICROCLOUD_ROOT_DISK_GIB="40"
MICROCLOUD_CEPH_DISK_GIB="50"
MICROCLOUD_LOCAL_DISK_GIB="20"
MICROCLOUD_NODE_COUNT="3"
MICROCLOUD_MAX_NODES="10"
MICROCLOUD_NETWORK_MODE="standard-2nic"
MICROCLOUD_OVN_UNDERLAY_CIDR=""
MICROCLOUD_CEPH_GENERAL_CIDR=""
MICROCLOUD_OVN_UNDERLAY_NETWORK_NAME=""
MICROCLOUD_CEPH_NETWORK_NAME=""
DEPLOYMENT_MODE="full"
K8S_CONTROL_PLANE_CPU="2"
K8S_CONTROL_PLANE_MEMORY_GIB="4"
K8S_WORKER_CPU="2"
K8S_WORKER_MEMORY_GIB="4"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

print_divider() {
    printf '%s\n' "----------------------------------------------------------"
}

print_section() {
    local title="$1"
    echo ""
    print_divider
    echo "$title"
    print_divider
}

print_kv() {
    local key="$1"
    local value="$2"
    printf '  %-30s %b\n' "$key" "$value"
}

round_down_even() {
    local value="$1"
    local minimum="${2:-2}"

    if (( value < minimum )); then
        echo "$minimum"
        return
    fi

    if (( value % 2 != 0 )); then
        value=$(( value - 1 ))
    fi

    echo "$value"
}

pick_floor_tier() {
    local limit="$1"
    shift
    local first_tier="$1"
    local selected="$first_tier"
    local tier=""

    for tier in "$@"; do
        if (( tier <= limit )); then
            selected="$tier"
        else
            break
        fi
    done

    echo "$selected"
}

pick_next_tier() {
    local current="$1"
    local limit="$2"
    shift 2
    local tier=""

    for tier in "$@"; do
        if (( tier > current && tier <= limit )); then
            echo "$tier"
            return
        fi
    done

    echo "$current"
}

pick_previous_tier() {
    local current="$1"
    shift
    local previous="$1"
    local tier=""

    for tier in "$@"; do
        if (( tier >= current )); then
            break
        fi
        previous="$tier"
    done

    echo "$previous"
}

print_sizing_table_header() {
    printf '  %-18s %-6s %-8s %-8s %-8s %s\n' "Profile" "vCPU" "RAM" "Root" "Ceph" "Notes"
    printf '  %-18s %-6s %-8s %-8s %-8s %s\n' "------------------" "------" "--------" "--------" "--------" "----------------"
}

print_sizing_table_row() {
    local profile="$1"
    local cpu="$2"
    local memory="$3"
    local root="$4"
    local ceph="$5"
    local notes="$6"
    local color="${7:-}"

    if [[ -n "$color" ]]; then
        printf '%b  %-18s %-6s %-8s %-8s %-8s %s%b\n' "$color" "$profile" "$cpu" "$memory" "$root" "$ceph" "$notes" "$NC"
        return
    fi

    printf '  %-18s %-6s %-8s %-8s %-8s %s\n' "$profile" "$cpu" "$memory" "$root" "$ceph" "$notes"
}

fit_k8s_profile_to_host() {
    local cp_cpu="$1"
    local cp_ram_gb="$2"
    local worker_cpu="$3"
    local worker_ram_gb="$4"
    local cp_count="$5"
    local worker_count="$6"
    local usable_cpu="$7"
    local usable_ram_gb="$8"
    local total_cpu="0"
    local total_ram_gb="0"

    while true; do
        total_cpu=$(( (cp_count * cp_cpu) + (worker_count * worker_cpu) ))
        total_ram_gb=$(( (cp_count * cp_ram_gb) + (worker_count * worker_ram_gb) ))

        if (( total_cpu <= usable_cpu && total_ram_gb <= usable_ram_gb )); then
            break
        fi

        if (( worker_count > 0 && worker_cpu > 2 )); then
            worker_cpu=$(pick_previous_tier "$worker_cpu" 2 4 6 8 10 12 16)
            continue
        fi

        if (( cp_cpu > 2 )); then
            cp_cpu=$(pick_previous_tier "$cp_cpu" 2 4 6 8 10 12 16)
            continue
        fi

        if (( worker_count > 0 && worker_ram_gb > 4 )); then
            worker_ram_gb=$(pick_previous_tier "$worker_ram_gb" 4 8 12 16 24 32 48 64 96 128)
            continue
        fi

        if (( cp_ram_gb > 4 )); then
            cp_ram_gb=$(pick_previous_tier "$cp_ram_gb" 4 8 12 16 24 32 48 64 96 128)
            continue
        fi

        break
    done

    echo "${cp_cpu} ${cp_ram_gb} ${worker_cpu} ${worker_ram_gb}"
}

print_k8s_sizing_table_header() {
    printf '  %-14s %-22s %-22s %-20s %s\n' "Profile" "Control Plane" "Worker" "Cluster Total" "Notes"
    printf '  %-14s %-22s %-22s %-20s %s\n' "--------------" "----------------------" "----------------------" "--------------------" "----------------"
}

print_k8s_sizing_table_row() {
    local profile="$1"
    local cp_spec="$2"
    local worker_spec="$3"
    local cluster_total="$4"
    local notes="$5"
    local color="${6:-}"

    if [[ -n "$color" ]]; then
        printf '%b  %-14s %-22s %-22s %-20s %s%b\n' "$color" "$profile" "$cp_spec" "$worker_spec" "$cluster_total" "$notes" "$NC"
        return
    fi

    printf '  %-14s %-22s %-22s %-20s %s\n' "$profile" "$cp_spec" "$worker_spec" "$cluster_total" "$notes"
}

configure_k8s_sizing() {
    local cp_count="$1"
    local worker_count="$2"
    local node_count="$(( cp_count + worker_count ))"
    local cpu_total="0"
    local ram_total_mb="0"
    local host_ram_gb="0"
    local reserve_cpu="0"
    local reserve_ram_mb="0"
    local usable_cpu="0"
    local usable_ram_mb="0"
    local usable_ram_gb="0"
    local raw_cpu_per_node="0"
    local raw_ram_per_node_gb="0"
    local host_cpu_per_node="0"
    local host_ram_per_node_gb="0"
    local balancing_mode=""
    local worker_display=""
    local balanced_cp_cpu="2"
    local balanced_cp_ram_gb="4"
    local balanced_worker_cpu="2"
    local balanced_worker_ram_gb="4"
    local conservative_cp_cpu="2"
    local conservative_cp_ram_gb="4"
    local conservative_worker_cpu="2"
    local conservative_worker_ram_gb="4"
    local performance_cp_cpu="2"
    local performance_cp_ram_gb="4"
    local performance_worker_cpu="2"
    local performance_worker_ram_gb="4"
    local profile_cp_cpu="2"
    local profile_cp_ram_gb="4"
    local profile_worker_cpu="2"
    local profile_worker_ram_gb="4"
    local total_cpu_selected="0"
    local total_ram_selected_gb="0"

    if (( node_count < 1 )); then
        echo "Invalid topology. At least one Kubernetes node is required."
        exit 1
    fi

    cpu_total=$(nproc 2>/dev/null || echo 4)
    ram_total_mb=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    host_ram_gb=$(( (ram_total_mb + 1023) / 1024 ))

    reserve_cpu=$(( cpu_total / 5 ))
    if (( reserve_cpu < 2 )); then reserve_cpu=2; fi
    usable_cpu=$(( cpu_total - reserve_cpu ))
    if (( usable_cpu < node_count * 2 )); then usable_cpu=$(( node_count * 2 )); fi

    reserve_ram_mb=$(( ram_total_mb / 5 ))
    if (( reserve_ram_mb < 4096 )); then reserve_ram_mb=4096; fi
    usable_ram_mb=$(( ram_total_mb - reserve_ram_mb ))
    if (( usable_ram_mb < node_count * 4096 )); then usable_ram_mb=$(( node_count * 4096 )); fi
    usable_ram_gb=$(( usable_ram_mb / 1024 ))

    raw_cpu_per_node=$(( usable_cpu / node_count ))
    raw_ram_per_node_gb=$(( usable_ram_gb / node_count ))
    host_cpu_per_node=$(( cpu_total / node_count ))
    host_ram_per_node_gb=$(( host_ram_gb / node_count ))

    balanced_cp_cpu=$(pick_floor_tier "$(round_down_even $(( (raw_cpu_per_node * 125) / 100 )) 2)" 2 4 6 8 10 12 16)
    balanced_worker_cpu=$(pick_floor_tier "$(round_down_even $(( (raw_cpu_per_node * 90) / 100 )) 2)" 2 4 6 8 10 12 16)

    balanced_cp_ram_gb=$(pick_floor_tier $(( (raw_ram_per_node_gb * 135) / 100 )) 4 8 12 16 24 32 48 64 96 128)
    balanced_worker_ram_gb=$(pick_floor_tier $(( (raw_ram_per_node_gb * 85) / 100 )) 4 8 12 16 24 32 48 64 96 128)

    read -r balanced_cp_cpu balanced_cp_ram_gb balanced_worker_cpu balanced_worker_ram_gb < <(
        fit_k8s_profile_to_host \
            "$balanced_cp_cpu" "$balanced_cp_ram_gb" "$balanced_worker_cpu" "$balanced_worker_ram_gb" \
            "$cp_count" "$worker_count" "$usable_cpu" "$usable_ram_gb"
    )

    conservative_cp_cpu=$(pick_previous_tier "$balanced_cp_cpu" 2 4 6 8 10 12 16)
    conservative_worker_cpu=$(pick_previous_tier "$balanced_worker_cpu" 2 4 6 8 10 12 16)
    conservative_cp_ram_gb=$(pick_previous_tier "$balanced_cp_ram_gb" 4 8 12 16 24 32 48 64 96 128)
    conservative_worker_ram_gb=$(pick_previous_tier "$balanced_worker_ram_gb" 4 8 12 16 24 32 48 64 96 128)

    performance_cp_cpu=$(pick_next_tier "$balanced_cp_cpu" "$(round_down_even "$host_cpu_per_node" "$balanced_cp_cpu")" 2 4 6 8 10 12 16)
    performance_worker_cpu=$(pick_next_tier "$balanced_worker_cpu" "$(round_down_even "$host_cpu_per_node" "$balanced_worker_cpu")" 2 4 6 8 10 12 16)
    performance_cp_ram_gb=$(pick_next_tier "$balanced_cp_ram_gb" "$(pick_floor_tier "$host_ram_per_node_gb" 4 8 12 16 24 32 48 64 96 128)" 4 8 12 16 24 32 48 64 96 128)
    performance_worker_ram_gb=$(pick_next_tier "$balanced_worker_ram_gb" "$(pick_floor_tier "$host_ram_per_node_gb" 4 8 12 16 24 32 48 64 96 128)" 4 8 12 16 24 32 48 64 96 128)

    # Performance must never be weaker than balanced.
    if ((
        (cp_count * performance_cp_cpu) + (worker_count * performance_worker_cpu) > usable_cpu ||
        (cp_count * performance_cp_ram_gb) + (worker_count * performance_worker_ram_gb) > usable_ram_gb
    )); then
        performance_cp_cpu="$balanced_cp_cpu"
        performance_cp_ram_gb="$balanced_cp_ram_gb"
        performance_worker_cpu="$balanced_worker_cpu"
        performance_worker_ram_gb="$balanced_worker_ram_gb"
    fi

    print_section "K8s Sizing Advisor"
    print_kv "Topology" "${cp_count} control-plane, ${worker_count} worker"
    print_kv "Host CPU cores" "${cpu_total}"
    print_kv "Host RAM" "${host_ram_gb} GB"
    echo ""
    print_k8s_sizing_table_header

    if (( worker_count > 0 )); then
        worker_display="${balanced_worker_cpu} vCPU / ${balanced_worker_ram_gb} GB"
    else
        worker_display="n/a (0 workers)"
    fi
    print_k8s_sizing_table_row "balanced" "${balanced_cp_cpu} vCPU / ${balanced_cp_ram_gb} GB" "$worker_display" "cpu=$((cp_count * balanced_cp_cpu + worker_count * balanced_worker_cpu)), ram=$((cp_count * balanced_cp_ram_gb + worker_count * balanced_worker_ram_gb))GB" "default" "$GREEN"

    if (( worker_count > 0 )); then
        worker_display="${conservative_worker_cpu} vCPU / ${conservative_worker_ram_gb} GB"
    else
        worker_display="n/a (0 workers)"
    fi
    print_k8s_sizing_table_row "conservative" "${conservative_cp_cpu} vCPU / ${conservative_cp_ram_gb} GB" "$worker_display" "cpu=$((cp_count * conservative_cp_cpu + worker_count * conservative_worker_cpu)), ram=$((cp_count * conservative_cp_ram_gb + worker_count * conservative_worker_ram_gb))GB" "lower footprint" "$YELLOW"

    if (( worker_count > 0 )); then
        worker_display="${performance_worker_cpu} vCPU / ${performance_worker_ram_gb} GB"
    else
        worker_display="n/a (0 workers)"
    fi
    print_k8s_sizing_table_row "performance" "${performance_cp_cpu} vCPU / ${performance_cp_ram_gb} GB" "$worker_display" "cpu=$((cp_count * performance_cp_cpu + worker_count * performance_worker_cpu)), ram=$((cp_count * performance_cp_ram_gb + worker_count * performance_worker_ram_gb))GB" "more headroom" "$BLUE"
    print_k8s_sizing_table_row "custom" "-" "-" "-" "manual sizing" "$CYAN"

    echo ""
    read -p "K8s sizing profile [conservative/balanced/performance/custom, default: balanced]: " balancing_mode
    balancing_mode="${balancing_mode:-balanced}"

    case "$balancing_mode" in
        balanced)
            profile_cp_cpu="$balanced_cp_cpu"
            profile_cp_ram_gb="$balanced_cp_ram_gb"
            profile_worker_cpu="$balanced_worker_cpu"
            profile_worker_ram_gb="$balanced_worker_ram_gb"
            ;;
        conservative)
            profile_cp_cpu="$conservative_cp_cpu"
            profile_cp_ram_gb="$conservative_cp_ram_gb"
            profile_worker_cpu="$conservative_worker_cpu"
            profile_worker_ram_gb="$conservative_worker_ram_gb"
            ;;
        performance)
            profile_cp_cpu="$performance_cp_cpu"
            profile_cp_ram_gb="$performance_cp_ram_gb"
            profile_worker_cpu="$performance_worker_cpu"
            profile_worker_ram_gb="$performance_worker_ram_gb"
            ;;
        custom)
            print_section "Custom K8s Sizing"
            print_kv "Input units" "memory is entered in GB"

            echo ""
            read -p "Control-plane vCPU per node [default: ${balanced_cp_cpu}]: " profile_cp_cpu_input
            profile_cp_cpu="${profile_cp_cpu_input:-$balanced_cp_cpu}"

            echo ""
            read -p "Control-plane memory in GB per node [default: ${balanced_cp_ram_gb}]: " profile_cp_ram_input
            profile_cp_ram_gb="${profile_cp_ram_input:-$balanced_cp_ram_gb}"

            if (( worker_count > 0 )); then
                echo ""
                read -p "Worker vCPU per node [default: ${balanced_worker_cpu}]: " profile_worker_cpu_input
                profile_worker_cpu="${profile_worker_cpu_input:-$balanced_worker_cpu}"

                echo ""
                read -p "Worker memory in GB per node [default: ${balanced_worker_ram_gb}]: " profile_worker_ram_input
                profile_worker_ram_gb="${profile_worker_ram_input:-$balanced_worker_ram_gb}"
            else
                profile_worker_cpu="2"
                profile_worker_ram_gb="4"
            fi
            ;;
        *)
            echo "Invalid sizing profile. Allowed values: conservative, balanced, performance, custom."
            exit 1
            ;;
    esac

    for val in "$profile_cp_cpu" "$profile_cp_ram_gb" "$profile_worker_cpu" "$profile_worker_ram_gb"; do
        if ! [[ "$val" =~ ^[0-9]+$ ]]; then
            echo "Invalid K8s sizing input. All values must be positive integers."
            exit 1
        fi
    done

    if (( profile_cp_cpu < 1 || profile_cp_ram_gb < 1 )); then
        echo "Invalid control-plane sizing bounds. Minimums: cpu>=1, memory>=1GB."
        exit 1
    fi

    if (( worker_count > 0 && (profile_worker_cpu < 1 || profile_worker_ram_gb < 1) )); then
        echo "Invalid worker sizing bounds. Minimums: cpu>=1, memory>=1GB."
        exit 1
    fi

    read -r profile_cp_cpu profile_cp_ram_gb profile_worker_cpu profile_worker_ram_gb < <(
        fit_k8s_profile_to_host \
            "$profile_cp_cpu" "$profile_cp_ram_gb" "$profile_worker_cpu" "$profile_worker_ram_gb" \
            "$cp_count" "$worker_count" "$usable_cpu" "$usable_ram_gb"
    )

    K8S_CONTROL_PLANE_CPU="$profile_cp_cpu"
    K8S_CONTROL_PLANE_MEMORY_GIB="$profile_cp_ram_gb"
    K8S_WORKER_CPU="$profile_worker_cpu"
    K8S_WORKER_MEMORY_GIB="$profile_worker_ram_gb"

    total_cpu_selected=$(( (cp_count * K8S_CONTROL_PLANE_CPU) + (worker_count * K8S_WORKER_CPU) ))
    total_ram_selected_gb=$(( (cp_count * K8S_CONTROL_PLANE_MEMORY_GIB) + (worker_count * K8S_WORKER_MEMORY_GIB) ))

    print_section "Selected K8s Sizing"
    print_k8s_sizing_table_header
    if (( worker_count > 0 )); then
        worker_display="${K8S_WORKER_CPU} vCPU / ${K8S_WORKER_MEMORY_GIB} GB"
    else
        worker_display="n/a (0 workers)"
    fi
    print_k8s_sizing_table_row "$balancing_mode" "${K8S_CONTROL_PLANE_CPU} vCPU / ${K8S_CONTROL_PLANE_MEMORY_GIB} GB" "$worker_display" "cpu=${total_cpu_selected}, ram=${total_ram_selected_gb}GB" "chosen" "$GREEN"
}

to_gib_int() {
    local raw="$1"
    local number=""
    local unit=""

    number=$(echo "$raw" | grep -Eo '[0-9]+([.][0-9]+)?' | head -n 1)
    unit=$(echo "$raw" | grep -Eo '[A-Za-z]+' | tail -n 1)

    if [[ -z "$number" || -z "$unit" ]]; then
        echo ""
        return
    fi

    awk -v n="$number" -v u="$unit" 'BEGIN {
        if (u == "TiB") print int(n * 1024)
        else if (u == "GiB") print int(n)
        else if (u == "MiB") print int(n / 1024)
        else print ""
    }'
}

get_storage_available_gib() {
    local storage_info=""
    local available_line=""
    local available_gib=""
    local df_gib=""

    storage_info=$(lxc storage info "$LXD_STORAGE_POOL" 2>/dev/null || true)
    available_line=$(echo "$storage_info" | awk -F': ' '/Space available:/ {print $2; exit}')
    available_gib=$(to_gib_int "$available_line")

    if [[ -n "$available_gib" ]]; then
        echo "$available_gib"
        return
    fi

    df_gib=$(df -BG . 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
    if [[ -n "$df_gib" && "$df_gib" =~ ^[0-9]+$ ]]; then
        echo "$df_gib"
    else
        echo "200"
    fi
}

configure_microcloud_sizing() {
    local node_count="$1"
    local cpu_total="0"
    local ram_total_mb="0"
    local storage_available_gib="0"
    local reserve_cpu="0"
    local reserve_ram_mb="0"
    local usable_cpu="0"
    local usable_ram_mb="0"
    local usable_disk_gib="0"
    local conservative_cpu="1"
    local conservative_memory_mb="3072"
    local conservative_root_gib="30"
    local conservative_ceph_gib="20"
    local balanced_cpu="2"
    local balanced_memory_mb="4096"
    local balanced_root_gib="40"
    local balanced_ceph_gib="50"
    local balanced_memory_gb="4"
    local conservative_memory_gb="3"
    local performance_cpu="4"
    local performance_memory_mb="8192"
    local performance_root_gib="50"
    local performance_ceph_gib="80"
    local performance_memory_gb="8"
    local sizing_mode=""
    local host_ram_gb="0"
    local host_ram_per_node_gb="0"
    local raw_balanced_cpu="0"
    local raw_balanced_memory_gb="0"
    local raw_balanced_ceph_gib="0"
    local performance_cpu_limit="0"
    local performance_cpu_cap="0"
    local performance_memory_cap_gb="0"
    local performance_ceph_cap_gib="0"
    local selected_memory_gb="0"
    local selected_total_cpu="0"
    local selected_total_memory_mb="0"
    local selected_total_disk_gib="0"
    local per_node_extra_disk_gib="0"

    cpu_total=$(nproc 2>/dev/null || echo 4)
    ram_total_mb=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    storage_available_gib=$(get_storage_available_gib)
    host_ram_gb=$(( (ram_total_mb + 1023) / 1024 ))
    host_ram_per_node_gb=$(( host_ram_gb / node_count ))

    reserve_cpu=$(( cpu_total / 5 ))
    if (( reserve_cpu < 2 )); then reserve_cpu=2; fi
    usable_cpu=$(( cpu_total - reserve_cpu ))

    reserve_ram_mb=$(( ram_total_mb / 5 ))
    if (( reserve_ram_mb < 4096 )); then reserve_ram_mb=4096; fi
    usable_ram_mb=$(( ram_total_mb - reserve_ram_mb ))

    usable_disk_gib=$(( storage_available_gib - 20 ))
    if [[ "$DEPLOYMENT_MODE" == "training" ]]; then
        per_node_extra_disk_gib="$MICROCLOUD_LOCAL_DISK_GIB"
    fi

    if (( usable_cpu < node_count )); then
        echo "Insufficient host CPU for ${node_count} MicroCloud nodes after host reserve (${usable_cpu} vCPU available)."
        exit 1
    fi

    if (( usable_ram_mb < node_count * 1024 )); then
        echo "Insufficient host RAM for ${node_count} MicroCloud nodes after host reserve (${usable_ram_mb} MB available)."
        exit 1
    fi

    if (( usable_disk_gib < node_count * (20 + 10 + per_node_extra_disk_gib) )); then
        echo "Insufficient storage for the minimum ${node_count}-node MicroCloud layout (${usable_disk_gib} GB available after reserve)."
        exit 1
    fi

    conservative_root_gib=30
    balanced_root_gib=40
    performance_root_gib=50

    raw_balanced_cpu=$(( usable_cpu / node_count ))
    balanced_cpu=$(round_down_even "$raw_balanced_cpu" 2)
    conservative_cpu=$(( balanced_cpu - 2 ))
    if (( conservative_cpu < 1 )); then conservative_cpu=1; fi
    performance_cpu_limit=$(round_down_even $(( usable_cpu / node_count )) "$balanced_cpu")
    performance_cpu=$(( balanced_cpu + 2 ))
    if (( performance_cpu > performance_cpu_limit )); then
        performance_cpu="$performance_cpu_limit"
    fi

    raw_balanced_memory_gb=$(( usable_ram_mb / (node_count * 1024) ))
    balanced_memory_gb=$(pick_floor_tier "$raw_balanced_memory_gb" 8 12 16 24 32 48 64 96 128)
    conservative_memory_gb=$(pick_previous_tier "$balanced_memory_gb" 4 8 12 16 24 32 48 64 96 128)
    performance_memory_cap_gb=$(pick_floor_tier "$host_ram_per_node_gb" 8 12 16 24 32 48 64 96 128)
    performance_memory_gb=$(pick_next_tier "$balanced_memory_gb" "$performance_memory_cap_gb" 4 8 12 16 24 32 48 64 96 128)

    raw_balanced_ceph_gib=$(( (usable_disk_gib / node_count) - balanced_root_gib - per_node_extra_disk_gib ))
    if (( raw_balanced_ceph_gib < 20 )); then raw_balanced_ceph_gib=20; fi
    balanced_ceph_gib=$(pick_floor_tier "$raw_balanced_ceph_gib" 20 50 100 150 200 250 300 400 500)
    conservative_ceph_gib=$(pick_previous_tier "$balanced_ceph_gib" 20 50 100 150 200 250 300 400 500)
    performance_ceph_cap_gib=$(( (usable_disk_gib / node_count) - performance_root_gib - per_node_extra_disk_gib ))
    if (( performance_ceph_cap_gib < 20 )); then performance_ceph_cap_gib=20; fi
    performance_cpu_cap=$(pick_floor_tier "$performance_ceph_cap_gib" 20 50 100 150 200 250 300 400 500)
    performance_ceph_gib=$(pick_next_tier "$balanced_ceph_gib" "$performance_cpu_cap" 20 50 100 150 200 250 300 400 500)

    balanced_memory_mb=$(( balanced_memory_gb * 1024 ))
    conservative_memory_mb=$(( conservative_memory_gb * 1024 ))
    performance_memory_mb=$(( performance_memory_gb * 1024 ))

    print_section "MicroCloud Sizing Advisor"
    print_kv "Node count" "${node_count}"
    print_kv "Host CPU cores" "${cpu_total}"
    print_kv "Host RAM" "${host_ram_gb} GB"
    print_kv "Storage (pool ${LXD_STORAGE_POOL})" "${storage_available_gib} GB"
    echo ""
    print_sizing_table_header
    print_sizing_table_row "balanced" "${balanced_cpu}" "${balanced_memory_gb} GB" "${balanced_root_gib} GB" "${balanced_ceph_gib} GB" "default" "$GREEN"
    print_sizing_table_row "conservative" "${conservative_cpu}" "${conservative_memory_gb} GB" "${conservative_root_gib} GB" "${conservative_ceph_gib} GB" "lower footprint" "$YELLOW"
    print_sizing_table_row "performance" "${performance_cpu}" "${performance_memory_gb} GB" "${performance_root_gib} GB" "${performance_ceph_gib} GB" "more headroom" "$BLUE"
    print_sizing_table_row "custom" "-" "-" "-" "-" "manual sizing" "$CYAN"

    echo ""
    read -p "MicroCloud sizing profile [conservative/balanced/performance/custom, default: balanced]: " sizing_mode
    sizing_mode="${sizing_mode:-balanced}"

    case "$sizing_mode" in
        balanced)
            MICROCLOUD_NODE_CPU="$balanced_cpu"
            MICROCLOUD_NODE_MEMORY_MB="$balanced_memory_mb"
            MICROCLOUD_ROOT_DISK_GIB="$balanced_root_gib"
            MICROCLOUD_CEPH_DISK_GIB="$balanced_ceph_gib"
            ;;
        conservative)
            MICROCLOUD_NODE_CPU="$conservative_cpu"
            MICROCLOUD_NODE_MEMORY_MB="$conservative_memory_mb"
            MICROCLOUD_ROOT_DISK_GIB="$conservative_root_gib"
            MICROCLOUD_CEPH_DISK_GIB="$conservative_ceph_gib"
            ;;
        performance)
            MICROCLOUD_NODE_CPU="$performance_cpu"
            MICROCLOUD_NODE_MEMORY_MB="$performance_memory_mb"
            MICROCLOUD_ROOT_DISK_GIB="$performance_root_gib"
            MICROCLOUD_CEPH_DISK_GIB="$performance_ceph_gib"
            ;;
        custom)
            print_section "Custom MicroCloud Sizing"
            print_kv "Input units" "memory and disks are entered in GB"
            echo ""
            read -p "Per-node vCPU [default: ${balanced_cpu}]: " MICROCLOUD_NODE_CPU_INPUT
            MICROCLOUD_NODE_CPU="${MICROCLOUD_NODE_CPU_INPUT:-$balanced_cpu}"

            echo ""
            read -p "Per-node memory in GB [default: ${balanced_memory_gb}]: " MICROCLOUD_NODE_MEMORY_GB_INPUT
            MICROCLOUD_NODE_MEMORY_GB="${MICROCLOUD_NODE_MEMORY_GB_INPUT:-$balanced_memory_gb}"
            if ! [[ "$MICROCLOUD_NODE_MEMORY_GB" =~ ^[0-9]+$ ]]; then
                echo "Invalid MicroCloud memory input. Enter memory as a whole number in GB."
                exit 1
            fi
            MICROCLOUD_NODE_MEMORY_MB=$(( MICROCLOUD_NODE_MEMORY_GB * 1024 ))

            echo ""
            read -p "Per-node root disk in GB [default: ${balanced_root_gib}]: " MICROCLOUD_ROOT_DISK_GIB_INPUT
            MICROCLOUD_ROOT_DISK_GIB="${MICROCLOUD_ROOT_DISK_GIB_INPUT:-$balanced_root_gib}"

            echo ""
            read -p "Per-node Ceph disk in GB [default: ${balanced_ceph_gib}]: " MICROCLOUD_CEPH_DISK_GIB_INPUT
            MICROCLOUD_CEPH_DISK_GIB="${MICROCLOUD_CEPH_DISK_GIB_INPUT:-$balanced_ceph_gib}"
            ;;
        *)
            echo "Invalid sizing profile. Allowed values: conservative, balanced, performance, custom."
            exit 1
            ;;
    esac

    for val in "$MICROCLOUD_NODE_CPU" "$MICROCLOUD_NODE_MEMORY_MB" "$MICROCLOUD_ROOT_DISK_GIB" "$MICROCLOUD_CEPH_DISK_GIB"; do
        if ! [[ "$val" =~ ^[0-9]+$ ]]; then
            echo "Invalid MicroCloud sizing input. All values must be positive integers."
            exit 1
        fi
    done

    if (( MICROCLOUD_NODE_CPU < 1 || MICROCLOUD_NODE_MEMORY_MB < 1024 || MICROCLOUD_ROOT_DISK_GIB < 20 || MICROCLOUD_CEPH_DISK_GIB < 10 )); then
        echo "Invalid MicroCloud sizing bounds. Minimums: cpu>=1, memory>=1GB, root>=20GB, ceph>=10GB."
        exit 1
    fi
    selected_memory_gb=$(( (MICROCLOUD_NODE_MEMORY_MB + 1023) / 1024 ))
    selected_total_cpu=$(( node_count * MICROCLOUD_NODE_CPU ))
    selected_total_memory_mb=$(( node_count * MICROCLOUD_NODE_MEMORY_MB ))
    selected_total_disk_gib=$(( node_count * (MICROCLOUD_ROOT_DISK_GIB + MICROCLOUD_CEPH_DISK_GIB + per_node_extra_disk_gib) ))

    if (( selected_total_cpu > usable_cpu )); then
        echo "Selected MicroCloud profile requires ${selected_total_cpu} vCPU, but only ${usable_cpu} vCPU are available after host reserve."
        exit 1
    fi

    if (( selected_total_memory_mb > usable_ram_mb )); then
        echo "Selected MicroCloud profile requires ${selected_total_memory_mb} MB RAM, but only ${usable_ram_mb} MB are available after host reserve."
        exit 1
    fi

    if (( selected_total_disk_gib > usable_disk_gib )); then
        echo "Selected MicroCloud profile requires ${selected_total_disk_gib} GB storage, but only ${usable_disk_gib} GB are available after host reserve."
        exit 1
    fi

    print_section "Selected MicroCloud Sizing"
    print_sizing_table_header
    print_sizing_table_row "${sizing_mode}" "${MICROCLOUD_NODE_CPU}" "${selected_memory_gb} GB" "${MICROCLOUD_ROOT_DISK_GIB} GB" "${MICROCLOUD_CEPH_DISK_GIB} GB" "chosen" "$GREEN"
}

detect_lxd_defaults() {
    local detected_network=""
    local detected_pool=""
    local candidate_name=""
    local candidate_type=""
    local ipv4_addr=""
    local bridge_inventory=""
    local current_user=""
    local group_list=""

    if ! command -v lxc &> /dev/null; then
        log_warn "LXD CLI (lxc) not found. Run ./prep_host.sh first."
        exit 1
    fi

    if ! lxc info >/dev/null 2>&1; then
        current_user="${SUDO_USER:-${USER:-$(id -un)}}"
        group_list=$(id -nG "$current_user" 2>/dev/null || true)

        log_warn "LXD is not reachable for the current user (${current_user})."
        if [[ " $group_list " != *" lxd "* ]]; then
            log_warn "User is not in the 'lxd' group."
            log_warn "Run: sudo usermod -aG lxd ${current_user}"
            log_warn "Then re-login (or run: newgrp lxd) and retry."
        elif [[ " $(id -nG) " != *" lxd "* ]]; then
            log_warn "The user is registered in the 'lxd' group, but this shell has not activated it."
            log_warn "Run 'newgrp lxd' or open a new login session, then retry."
        fi

        if sudo -n lxc info >/dev/null 2>&1; then
            log_warn "LXD works with sudo, which indicates a user permission issue."
        fi

        log_warn "If needed, run ./prep_host.sh to prepare host prerequisites."
        exit 1
    fi

    while IFS= read -r candidate_name; do
        [[ -z "$candidate_name" ]] && continue

        candidate_type=$(lxc network show "$candidate_name" 2>/dev/null | awk -F': ' '$1=="type" {print $2; exit}')
        [[ "$candidate_type" != "bridge" ]] && continue

        ipv4_addr=$(lxc network get "$candidate_name" ipv4.address 2>/dev/null || true)
        bridge_inventory+="\n- ${candidate_name} (ipv4=${ipv4_addr:-unknown})"

        if [[ "$candidate_name" == "lxdbr0" && -n "$ipv4_addr" && "$ipv4_addr" != "none" ]]; then
            detected_network="$candidate_name"
            break
        fi

        if [[ -z "$detected_network" && -n "$ipv4_addr" && "$ipv4_addr" != "none" ]]; then
            detected_network="$candidate_name"
        fi
    done < <(lxc network list --format csv | awk -F',' 'NF>0 {print $1}')

    if [[ -z "$detected_network" ]]; then
        log_warn "No usable LXD bridge network found (requires IPv4 address not 'none')."
        if [[ -n "$bridge_inventory" ]]; then
            log_warn "Detected bridge networks:${bridge_inventory}"
        fi

        log_info "Attempting to create fallback LXD bridge network: labbr0"
        if ! lxc network show labbr0 >/dev/null 2>&1; then
            if sudo lxc network create labbr0 ipv4.address=auto ipv6.address=none >/dev/null 2>&1; then
                log_info "Created fallback bridge: labbr0"
            else
                log_warn "Could not create fallback bridge automatically."
            fi
        fi

        ipv4_addr=$(lxc network get labbr0 ipv4.address 2>/dev/null || true)
        if [[ -n "$ipv4_addr" && "$ipv4_addr" != "none" ]]; then
            detected_network="labbr0"
            log_info "Using fallback LXD network: ${detected_network}"
        else
            log_warn "Run ./prep_host.sh to create/prepare a usable LXD bridge network."
            exit 1
        fi
    fi

    if lxc storage show default >/dev/null 2>&1; then
        detected_pool="default"
    else
        detected_pool=$(lxc storage list --format csv | awk -F',' 'NR==1 {print $1}')
    fi

    if [[ -z "$detected_pool" ]]; then
        log_warn "No LXD storage pool found (expected default or another pool)."
        log_warn "Run ./prep_host.sh to initialize LXD storage."
        exit 1
    fi

    LXD_NETWORK_NAME="$detected_network"
    LXD_STORAGE_POOL="$detected_pool"

    export TF_VAR_lxd_network_name="$LXD_NETWORK_NAME"
    export TF_VAR_lxd_storage_pool="$LXD_STORAGE_POOL"

    print_section "LXD Environment"
    print_kv "Selected network" "${LXD_NETWORK_NAME}"
    print_kv "Selected storage pool" "${LXD_STORAGE_POOL}"
}

cidr_host_address() {
    local cidr="$1"
    local offset="$2"

    python3 - "$cidr" "$offset" <<'PY'
import ipaddress
import sys

network = ipaddress.ip_network(sys.argv[1], strict=True)
print(network[int(sys.argv[2])])
PY
}

validate_microcloud_cidr() {
    local cidr="$1"
    local node_count="$2"

    python3 - "$cidr" "$node_count" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1)

node_count = int(sys.argv[2])
last_offset = node_count + 9
if network.version != 4:
    print("only IPv4 subnets are supported", file=sys.stderr)
    raise SystemExit(1)
if last_offset >= network.num_addresses - 1:
    print(
        f"{network} does not have enough usable addresses for {node_count} nodes "
        f"at offsets 10-{last_offset}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

subnets_overlap() {
    local first="$1"
    local second="$2"

    python3 - "$first" "$second" <<'PY'
import ipaddress
import sys

first = ipaddress.ip_network(sys.argv[1], strict=False)
second = ipaddress.ip_network(sys.argv[2], strict=False)
raise SystemExit(0 if first.overlaps(second) else 1)
PY
}

list_host_ipv4_subnets() {
    local network_name=""
    local network_cidr=""
    local tagged_cidr=""

    ip -o -4 route show table all 2>/dev/null \
        | awk '
            $1 == "default" { next }
            {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) {
                        print $i
                        break
                    }
                }
            }
        '

    while IFS= read -r network_name; do
        [[ -z "$network_name" ]] && continue
        network_cidr=$(lxc network get "$network_name" ipv4.address 2>/dev/null || true)
        if [[ "$network_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            echo "$network_cidr"
        fi
        tagged_cidr=$(lxc network get "$network_name" user.lab-automation.cidr 2>/dev/null || true)
        if [[ "$tagged_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            echo "$tagged_cidr"
        fi
    done < <(lxc network list --format csv | awk -F',' 'NF > 0 {print $1}')
}

assert_microcloud_subnet_available() {
    local candidate="$1"
    local plane_label="$2"
    local existing_subnet=""

    while IFS= read -r existing_subnet; do
        [[ -z "$existing_subnet" ]] && continue
        if subnets_overlap "$candidate" "$existing_subnet"; then
            log_warn "${plane_label} subnet ${candidate} overlaps host/LXD subnet ${existing_subnet}."
            return 1
        fi
    done < <(list_host_ipv4_subnets | sort -u)
}

configure_microcloud_network_mode() {
    local workspace_name="$1"
    local mode_choice=""
    local workspace_hash=""
    local subnet_slot="0"
    local default_ovn_cidr=""
    local default_ceph_cidr=""
    local ovn_external_cidr=""
    local ovn_cidr_input=""
    local ceph_cidr_input=""

    print_section "MicroCloud Network Mode"
    echo "  1) Standard - 2 NICs (default)"
    echo "     Management/cluster traffic plus a dedicated IP-free OVN uplink"
    echo "  2) Fully Segregated - 4 NICs (Dedicated OVN and Ceph Planes)"
    echo "     mgmt0, IP-free OVN uplink, OVN underlay, and Ceph general"
    echo ""
    read -p "Select network mode [default: 1]: " mode_choice

    case "${mode_choice:-1}" in
        1)
            MICROCLOUD_NETWORK_MODE="standard-2nic"
            MICROCLOUD_OVN_UNDERLAY_CIDR=""
            MICROCLOUD_CEPH_GENERAL_CIDR=""
            ;;
        2)
            MICROCLOUD_NETWORK_MODE="fully-segregated-4nic"
            workspace_hash=$(printf '%s' "$workspace_name" | md5sum | awk '{print $1}')
            subnet_slot=$((16#${workspace_hash:0:2} % 240 + 10))
            default_ovn_cidr="172.28.${subnet_slot}.0/24"
            default_ceph_cidr="172.29.${subnet_slot}.0/24"
            if [[ "$(lxc network get "$LXD_NETWORK_NAME" ipv4.address 2>/dev/null || true)" == 10.* ]]; then
                ovn_external_cidr="192.168.250.0/24"
            else
                ovn_external_cidr="10.250.1.0/24"
            fi

            echo ""
            read -p "OVN underlay IPv4 CIDR [default: ${default_ovn_cidr}]: " ovn_cidr_input
            MICROCLOUD_OVN_UNDERLAY_CIDR="${ovn_cidr_input:-$default_ovn_cidr}"
            read -p "Ceph general IPv4 CIDR [default: ${default_ceph_cidr}]: " ceph_cidr_input
            MICROCLOUD_CEPH_GENERAL_CIDR="${ceph_cidr_input:-$default_ceph_cidr}"

            if ! validate_microcloud_cidr "$MICROCLOUD_OVN_UNDERLAY_CIDR" "$MICROCLOUD_NODE_COUNT"; then
                log_warn "Invalid OVN underlay CIDR: ${MICROCLOUD_OVN_UNDERLAY_CIDR}"
                exit 1
            fi
            if ! validate_microcloud_cidr "$MICROCLOUD_CEPH_GENERAL_CIDR" "$MICROCLOUD_NODE_COUNT"; then
                log_warn "Invalid Ceph general CIDR: ${MICROCLOUD_CEPH_GENERAL_CIDR}"
                exit 1
            fi
            if subnets_overlap "$MICROCLOUD_OVN_UNDERLAY_CIDR" "$MICROCLOUD_CEPH_GENERAL_CIDR"; then
                log_warn "OVN underlay and Ceph general subnets must not overlap."
                exit 1
            fi
            if subnets_overlap "$MICROCLOUD_OVN_UNDERLAY_CIDR" "$ovn_external_cidr" \
                || subnets_overlap "$MICROCLOUD_CEPH_GENERAL_CIDR" "$ovn_external_cidr"; then
                log_warn "Dedicated plane subnets must not overlap the planned OVN external subnet ${ovn_external_cidr}."
                exit 1
            fi
            if ! assert_microcloud_subnet_available "$MICROCLOUD_OVN_UNDERLAY_CIDR" "OVN underlay"; then
                exit 1
            fi
            if ! assert_microcloud_subnet_available "$MICROCLOUD_CEPH_GENERAL_CIDR" "Ceph general"; then
                exit 1
            fi
            if ! assert_microcloud_subnet_available "$ovn_external_cidr" "OVN external"; then
                exit 1
            fi
            ;;
        *)
            echo "Invalid selection. Choose 1 or 2."
            exit 1
            ;;
    esac

    print_section "MicroCloud Network Plan"
    if [[ "$MICROCLOUD_NETWORK_MODE" == "fully-segregated-4nic" ]]; then
        print_kv "Mode" "Fully Segregated - 4 NICs"
        print_kv "mgmt0" "SSH, MicroCloud, and LXD management"
        print_kv "ovn-uplink" "IP-free external OVN uplink"
        print_kv "OVN external subnet" "$ovn_external_cidr"
        print_kv "ovn-underlay" "${MICROCLOUD_OVN_UNDERLAY_CIDR} (OVN Geneve)"
        print_kv "ceph-general" "${MICROCLOUD_CEPH_GENERAL_CIDR} (Ceph public + cluster)"
    else
        print_kv "Mode" "Standard - 2 NICs"
        print_kv "eth0" "Management, SSH, and cluster traffic"
        print_kv "eth1" "IP-free external OVN uplink"
    fi
}

workspace_exists() {
    local workspace_name="$1"
    tofu workspace list | tr -d '* ' | grep -qx "$workspace_name"
}

get_workspace_suffix() {
    local scenario_name="$1"
    local deployment_mode="$2"

    if [[ "$deployment_mode" == "training" ]]; then
        echo "training-${scenario_name}"
    else
        echo "$scenario_name"
    fi
}

get_lab_prefix_from_workspace() {
    local workspace_name="$1"
    local scenario_name="$2"
    local deployment_mode="$3"
    local expected_suffix=""

    expected_suffix="$(get_workspace_suffix "$scenario_name" "$deployment_mode")"
    if [[ "$workspace_name" == *"_${expected_suffix}" ]]; then
        echo "${workspace_name%_${expected_suffix}}"
    else
        # Legacy MicroCloud infra-only workspaces used the full-deployment suffix.
        echo "${workspace_name%_${scenario_name}}"
    fi
}

workspace_is_legacy_microcloud_training() {
    local workspace_name="$1"
    local previous_workspace=""
    local result=1

    [[ "$workspace_name" == *"_microcloud" ]] || return 1

    previous_workspace=$(tofu workspace show 2>/dev/null || echo "default")
    if tofu workspace select "$workspace_name" >/dev/null 2>&1; then
        if tofu state list 2>/dev/null | grep -q '^lxd_volume\.microcloud_local_disks\['; then
            result=0
        fi
        tofu workspace select "$previous_workspace" >/dev/null 2>&1 || true
    fi

    return "$result"
}

list_existing_labs_for_scenario() {
    local scenario_name="$1"
    local deployment_mode="$2"
    local expected_suffix=""
    local workspace_name=""

    expected_suffix="$(get_workspace_suffix "$scenario_name" "$deployment_mode")"

    while IFS= read -r workspace_name; do
        [[ -z "$workspace_name" || "$workspace_name" == "default" ]] && continue

        if [[ "$workspace_name" == *"_${expected_suffix}" ]]; then
            if [[ "$scenario_name" == "microcloud" && "$deployment_mode" == "full" ]] \
                && workspace_is_legacy_microcloud_training "$workspace_name"; then
                continue
            fi
            echo "$workspace_name"
            continue
        fi

        if [[ "$scenario_name" == "microcloud" && "$deployment_mode" == "training" ]] \
            && workspace_is_legacy_microcloud_training "$workspace_name"; then
            echo "$workspace_name"
        fi
    done < <(tofu workspace list | tr -d '* ')
}

parse_workspace_metadata() {
    local workspace_name="$1"
    local workspace_suffix="${workspace_name#*_}"
    local parsed_scenario=""
    local parsed_mode="full"

    if [[ "$workspace_suffix" == training-* ]]; then
        parsed_mode="training"
        workspace_suffix="${workspace_suffix#training-}"
    fi

    case "$workspace_suffix" in
        microcloud|k8s-snap|k8s-juju)
            parsed_scenario="$workspace_suffix"
            ;;
        *)
            return 1
            ;;
    esac

    if [[ "$parsed_scenario" == "microcloud" && "$parsed_mode" == "full" ]] \
        && workspace_is_legacy_microcloud_training "$workspace_name"; then
        parsed_mode="training"
    fi

    printf '%s %s %s\n' "${workspace_name%_*}" "$parsed_scenario" "$parsed_mode"
}

normalize_lab_prefix_input() {
    local raw_input="$1"
    local scenario_name="$2"
    local normalized_input="$raw_input"

    if [[ "$normalized_input" == *"_${scenario_name}" ]]; then
        normalized_input="${normalized_input%_${scenario_name}}"
    fi

    echo "$normalized_input"
}

get_k8s_sizing_from_state() {
    local workspace_name="$1"
    local lxd_prefix="${workspace_name//_/-}"
    local cp_node="${lxd_prefix}-cp-1"
    local worker_node="${lxd_prefix}-worker-1"
    local cp_cpu="2"
    local cp_mem_gib="4"
    local worker_cpu="2"
    local worker_mem_gib="4"
    local mem_raw=""

    cp_cpu=$(lxc config get "$cp_node" limits.cpu 2>/dev/null || echo 2)
    mem_raw=$(lxc config get "$cp_node" limits.memory 2>/dev/null || echo "4GiB")
    cp_mem_gib=$(echo "$mem_raw" | grep -Eo '[0-9]+')

    if lxc info "$worker_node" >/dev/null 2>&1; then
        worker_cpu=$(lxc config get "$worker_node" limits.cpu 2>/dev/null || echo 2)
        mem_raw=$(lxc config get "$worker_node" limits.memory 2>/dev/null || echo "4GiB")
        worker_mem_gib=$(echo "$mem_raw" | grep -Eo '[0-9]+')
    fi

    echo "${cp_cpu} ${cp_mem_gib} ${worker_cpu} ${worker_mem_gib}"
}

get_k8s_topology_from_state() {
    local workspace_name="$1"
    local previous_workspace=""
    local cp_count="0"
    local worker_count="0"

    previous_workspace=$(tofu workspace show 2>/dev/null || echo "default")
    tofu workspace select "$workspace_name" >/dev/null 2>&1

    cp_count=$(tofu state list 2>/dev/null | grep -c '^lxd_instance\.k8s_control_plane_nodes\[' || true)
    worker_count=$(tofu state list 2>/dev/null | grep -c '^lxd_instance\.k8s_worker_nodes\[' || true)

    tofu workspace select "$previous_workspace" >/dev/null 2>&1
    echo "${cp_count} ${worker_count}"
}

get_k8s_juju_topology_from_state() {
    local workspace_name="$1"
    local previous_workspace=""
    local cp_count="0"
    local worker_count="0"

    previous_workspace=$(tofu workspace show 2>/dev/null || echo "default")
    tofu workspace select "$workspace_name" >/dev/null 2>&1

    cp_count=$(tofu state list 2>/dev/null | grep -c '^lxd_instance\.k8s_juju_cp_nodes\[' || true)
    worker_count=$(tofu state list 2>/dev/null | grep -c '^lxd_instance\.k8s_juju_worker_nodes\[' || true)

    tofu workspace select "$previous_workspace" >/dev/null 2>&1
    echo "${cp_count} ${worker_count}"
}

get_microcloud_node_count_from_state() {
    local workspace_name="$1"
    local previous_workspace=""
    local node_count="0"

    previous_workspace=$(tofu workspace show 2>/dev/null || echo "default")
    tofu workspace select "$workspace_name" >/dev/null 2>&1
    node_count=$(tofu state list 2>/dev/null | grep -c '^lxd_instance\.microcloud_nodes\[' || true)
    tofu workspace select "$previous_workspace" >/dev/null 2>&1

    echo "$node_count"
}

destroy_environment() {
    local env_name="$1"
    local env_prefix="$2"
    local env_scenario="$3"
    local env_k8s_cp_count="${4:-3}"
    local env_k8s_worker_count="${5:-1}"
    local env_deployment_mode="${6:-full}"
    local env_microcloud_node_count="${7:-3}"
    local env_microcloud_infra_only="false"
    local env_microcloud_network_mode="standard-2nic"
    local env_ovn_underlay_network_name=""
    local env_ceph_network_name=""
    local env_ovn_underlay_cidr=""
    local env_ceph_general_cidr=""

    if [[ "$env_deployment_mode" == "training" ]]; then
        env_microcloud_infra_only="true"
    fi

    tofu workspace select "$env_name" >/dev/null 2>&1

    if [[ "$env_scenario" == "microcloud" ]]; then
        tag_legacy_microcloud_uplink_if_safe "$env_name"
        env_ovn_underlay_network_name=$(resolve_microcloud_plane_network_name "$env_name" "ovn")
        env_ceph_network_name=$(resolve_microcloud_plane_network_name "$env_name" "ceph")
        if [[ "$(lxc network get "$env_ovn_underlay_network_name" user.lab-automation.owner 2>/dev/null || true)" == "$env_name" \
            && "$(lxc network get "$env_ceph_network_name" user.lab-automation.owner 2>/dev/null || true)" == "$env_name" ]]; then
            env_ovn_underlay_cidr=$(lxc network get "$env_ovn_underlay_network_name" user.lab-automation.cidr 2>/dev/null || true)
            env_ceph_general_cidr=$(lxc network get "$env_ceph_network_name" user.lab-automation.cidr 2>/dev/null || true)
            if validate_microcloud_cidr "$env_ovn_underlay_cidr" "$env_microcloud_node_count" >/dev/null 2>&1 \
                && validate_microcloud_cidr "$env_ceph_general_cidr" "$env_microcloud_node_count" >/dev/null 2>&1; then
                env_microcloud_network_mode="fully-segregated-4nic"
            else
                log_warn "Four-NIC network metadata for ${env_name} is incomplete; using compatibility defaults for destroy."
                env_ovn_underlay_cidr=""
                env_ceph_general_cidr=""
            fi
        fi
    fi

    destroy_args=(
        -auto-approve
        -var="user_prefix=${env_prefix}"
        -var="scenario=${env_scenario}"
    )

    if [[ "$env_scenario" == "k8s-snap" ]]; then
        destroy_args+=(
            -var="k8s_control_plane_count=${env_k8s_cp_count}"
            -var="k8s_worker_count=${env_k8s_worker_count}"
        )
    fi

    if [[ "$env_scenario" == "k8s-juju" ]]; then
        destroy_args+=(
            -var="k8s_juju_cp_count=${env_k8s_cp_count}"
            -var="k8s_juju_worker_count=${env_k8s_worker_count}"
        )
    fi

    if [[ "$env_scenario" == "microcloud" ]]; then
        destroy_args+=(
            -var="microcloud_node_count=${env_microcloud_node_count}"
            -var="microcloud_infra_only=${env_microcloud_infra_only}"
            -var="microcloud_uplink_network_name=$(resolve_microcloud_uplink_network_name "$env_name")"
            -var="microcloud_network_mode=${env_microcloud_network_mode}"
            -var="microcloud_ovn_underlay_network_name=${env_ovn_underlay_network_name}"
            -var="microcloud_ceph_network_name=${env_ceph_network_name}"
            -var="microcloud_ovn_underlay_cidr=${env_ovn_underlay_cidr}"
            -var="microcloud_ceph_general_cidr=${env_ceph_general_cidr}"
        )
    fi

    tofu destroy "${destroy_args[@]}"

    if [[ "$env_scenario" == "microcloud" ]]; then
        cleanup_microcloud_orphans "$env_name"
    fi

    if ! tofu workspace select default >/dev/null 2>&1; then
        log_warn "Could not switch to default workspace before deleting ${env_name}."
        return
    fi

    if ! tofu workspace delete -force "$env_name" >/dev/null 2>&1; then
        log_warn "Could not delete workspace ${env_name}. It may still contain state entries."
    fi

    rm -f "inventory_${env_name}.yaml"
}

cleanup_microcloud_orphans() {
    local env_name="$1"
    local lxd_prefix="${env_name//_/-}"
    local uplink_network_legacy="mc-${lxd_prefix:0:8}-up"
    local uplink_network_name=""
    local ovn_underlay_network_name=""
    local ceph_network_name=""
    local profile_name="${lxd_prefix}-iac-base"
    local storage_pool="${LXD_STORAGE_POOL}"

    uplink_network_name=$(resolve_microcloud_uplink_network_name "$env_name")
    ovn_underlay_network_name=$(resolve_microcloud_plane_network_name "$env_name" "ovn")
    ceph_network_name=$(resolve_microcloud_plane_network_name "$env_name" "ceph")

    # If provider state is inconsistent, these resources can remain orphaned.
    for ((i = 1; i <= MICROCLOUD_MAX_NODES; i++)); do
        lxc delete -f "${lxd_prefix}-node-${i}" >/dev/null 2>&1 || true
    done

    for ((i = 1; i <= MICROCLOUD_MAX_NODES; i++)); do
        lxc storage volume delete "$storage_pool" "${lxd_prefix}-ceph-${i}" >/dev/null 2>&1 || true
    done

    for ((i = 1; i <= MICROCLOUD_MAX_NODES; i++)); do
        lxc storage volume delete "$storage_pool" "${lxd_prefix}-local-${i}" >/dev/null 2>&1 || true
    done

    delete_owned_microcloud_network "$uplink_network_name" "$env_name"
    delete_owned_microcloud_network "$uplink_network_legacy" "$env_name"
    delete_owned_microcloud_network "$ovn_underlay_network_name" "$env_name"
    delete_owned_microcloud_network "$ceph_network_name" "$env_name"
    lxc profile delete "$profile_name" >/dev/null 2>&1 || true
}

reconcile_microcloud_orphans_with_state() {
    local env_name="$1"
    local lxd_prefix="${env_name//_/-}"
    local profile_name="${lxd_prefix}-iac-base"
    local storage_pool="${LXD_STORAGE_POOL}"
    local state_list=""

    state_list=$(tofu state list 2>/dev/null || true)

    # Never auto-delete networks when not tracked in state.
    # Name-based deletion can remove another lab's live network.

    if ! grep -q '^lxd_profile\.lab_base$' <<< "$state_list"; then
        if lxc profile show "$profile_name" >/dev/null 2>&1; then
            log_warn "Removing orphan profile not tracked in state: ${profile_name}"
            lxc profile delete "$profile_name" >/dev/null 2>&1 || true
        fi
    fi

    for ((i = 0; i < MICROCLOUD_MAX_NODES; i++)); do
        local idx=$((i + 1))
        local vol_name="${lxd_prefix}-ceph-${idx}"
        local local_vol_name="${lxd_prefix}-local-${idx}"
        local node_name="${lxd_prefix}-node-${idx}"

        if ! grep -q "^lxd_volume\\.microcloud_ceph_disks\\[${i}\\]$" <<< "$state_list"; then
            if lxc storage volume show "$storage_pool" "$vol_name" >/dev/null 2>&1; then
                log_warn "Removing orphan volume not tracked in state: ${storage_pool}/${vol_name}"
                lxc storage volume delete "$storage_pool" "$vol_name" >/dev/null 2>&1 || true
            fi
        fi

        if ! grep -q "^lxd_volume\\.microcloud_local_disks\\[${i}\\]$" <<< "$state_list"; then
            if lxc storage volume show "$storage_pool" "$local_vol_name" >/dev/null 2>&1; then
                log_warn "Removing orphan volume not tracked in state: ${storage_pool}/${local_vol_name}"
                lxc storage volume delete "$storage_pool" "$local_vol_name" >/dev/null 2>&1 || true
            fi
        fi

        if ! grep -q "^lxd_instance\\.microcloud_nodes\\[${i}\\]$" <<< "$state_list"; then
            if lxc info "$node_name" >/dev/null 2>&1; then
                log_warn "Removing orphan instance not tracked in state: ${node_name}"
                lxc delete -f "$node_name" >/dev/null 2>&1 || true
            fi
        fi
    done
}

get_node_primary_ip() {
    local node="$1"
    local ip=""
    local lxc_row=""

    ip=$(lxc exec "$node" -- sh -c "ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if(\$i==\"src\") {print \$(i+1); exit}}'" 2>/dev/null || true)
    ip="$(echo "$ip" | tr -d '[:space:]')"

    if [[ -z "$ip" ]]; then
        lxc_row=$(lxc list --format csv 2>/dev/null | awk -F',' -v node="$node" '$1==node {print; exit}')
        ip=$(echo "$lxc_row" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
    fi

    echo "$ip"
}

list_lxd_instances_by_prefix() {
    local prefix="$1"

    lxc list --format csv 2>/dev/null | awk -F',' -v prefix="$prefix" 'index($1, prefix) == 1 {print $1}'
}

resolve_microcloud_uplink_network_name() {
    local ws_name="$1"
    local lxd_prefix="${ws_name//_/-}"
    local uplink_hash=""

    uplink_hash=$(printf '%s' "$lxd_prefix" | md5sum | awk '{print $1}')
    echo "mc-${lxd_prefix:0:4}-${uplink_hash:0:4}-up"
}

resolve_microcloud_plane_network_name() {
    local ws_name="$1"
    local plane="$2"
    local plane_suffix=""
    local lxd_prefix="${ws_name//_/-}"
    local network_hash=""

    case "$plane" in
        ovn) plane_suffix="ov" ;;
        ceph) plane_suffix="ce" ;;
        *)
            log_warn "Unknown MicroCloud network plane: ${plane}"
            return 1
            ;;
    esac

    network_hash=$(printf '%s' "$lxd_prefix" | md5sum | awk '{print $1}')
    echo "mc-${lxd_prefix:0:4}-${network_hash:0:4}-${plane_suffix}"
}

ensure_owned_microcloud_network() {
    local network_name="$1"
    local env_name="$2"
    local network_role="$3"
    local network_cidr="${4:-}"
    local owner=""
    local existing_role=""
    local network_type=""
    local ipv4_address=""
    local ipv6_address=""
    local existing_cidr=""
    local -a create_args=()

    if lxc network show "$network_name" >/dev/null 2>&1; then
        owner=$(lxc network get "$network_name" user.lab-automation.owner 2>/dev/null || true)
        existing_role=$(lxc network get "$network_name" user.lab-automation.role 2>/dev/null || true)
        network_type=$(lxc network show "$network_name" 2>/dev/null | awk -F': ' '$1 == "type" {print $2; exit}')
        ipv4_address=$(lxc network get "$network_name" ipv4.address 2>/dev/null || true)
        ipv6_address=$(lxc network get "$network_name" ipv6.address 2>/dev/null || true)
        existing_cidr=$(lxc network get "$network_name" user.lab-automation.cidr 2>/dev/null || true)

        if [[ "$owner" != "$env_name" || "$existing_role" != "$network_role" ]]; then
            log_warn "Refusing to reuse unowned LXD network ${network_name}."
            log_warn "Expected owner=${env_name}, role=${network_role}; found owner=${owner:-unset}, role=${existing_role:-unset}."
            exit 1
        fi
        if [[ "$network_type" != "bridge" || "$ipv4_address" != "none" || "$ipv6_address" != "none" ]]; then
            log_warn "Owned network ${network_name} is not an IP-free LXD bridge."
            exit 1
        fi
        if [[ "$existing_cidr" != "$network_cidr" ]]; then
            log_warn "Owned network ${network_name} has CIDR metadata ${existing_cidr:-unset}; expected ${network_cidr:-unset}."
            exit 1
        fi
        return
    fi

    log_info "Creating MicroCloud ${network_role} network: ${network_name}"
    create_args=(
        --type=bridge
        ipv4.address=none
        ipv6.address=none
        "user.lab-automation.owner=${env_name}"
        "user.lab-automation.role=${network_role}"
    )
    if [[ -n "$network_cidr" ]]; then
        create_args+=("user.lab-automation.cidr=${network_cidr}")
    fi
    lxc network create "$network_name" "${create_args[@]}"
}

tag_legacy_microcloud_uplink_if_safe() {
    local env_name="$1"
    local lxd_prefix="${env_name//_/-}"
    local current_name=""
    local legacy_name="mc-${lxd_prefix:0:8}-up"
    local network_name=""
    local owner=""
    local network_type=""
    local ipv4_address=""
    local ipv6_address=""
    local attached_node=""
    local attached_count="0"
    local safe_to_tag=true

    current_name=$(resolve_microcloud_uplink_network_name "$env_name")

    for network_name in "$current_name" "$legacy_name"; do
        [[ "$network_name" == "$current_name" || "$legacy_name" != "$current_name" ]] || continue
        lxc network show "$network_name" >/dev/null 2>&1 || continue

        owner=$(lxc network get "$network_name" user.lab-automation.owner 2>/dev/null || true)
        [[ "$owner" == "$env_name" ]] && continue
        if [[ -n "$owner" ]]; then
            log_warn "Network ${network_name} is owned by ${owner}; it will not be adopted or removed."
            continue
        fi

        network_type=$(lxc network show "$network_name" 2>/dev/null | awk -F': ' '$1 == "type" {print $2; exit}')
        ipv4_address=$(lxc network get "$network_name" ipv4.address 2>/dev/null || true)
        ipv6_address=$(lxc network get "$network_name" ipv6.address 2>/dev/null || true)
        if [[ "$network_type" != "bridge" || "$ipv4_address" != "none" || "$ipv6_address" != "none" ]]; then
            log_warn "Legacy network ${network_name} does not match the expected IP-free bridge shape; leaving it untouched."
            continue
        fi

        attached_count=0
        safe_to_tag=true
        while IFS= read -r attached_node; do
            [[ -z "$attached_node" ]] && continue
            attached_count=$((attached_count + 1))
            if [[ "$attached_node" != "${lxd_prefix}-node-"* ]]; then
                safe_to_tag=false
            fi
        done < <(
            lxc network show "$network_name" 2>/dev/null \
                | sed -n 's|^[[:space:]]*-[[:space:]]*/1.0/instances/\([^/?]*\).*|\1|p'
        )

        if [[ "$safe_to_tag" == true && "$attached_count" -gt 0 ]]; then
            log_info "Tagging legacy MicroCloud uplink network for safe cleanup: ${network_name}"
            lxc network set "$network_name" user.lab-automation.owner "$env_name"
            lxc network set "$network_name" user.lab-automation.role "ovn-uplink"
        else
            log_warn "Legacy network ${network_name} cannot be safely attributed to ${env_name}; leaving it untouched."
        fi
    done
}

delete_owned_microcloud_network() {
    local network_name="$1"
    local env_name="$2"
    local owner=""

    lxc network show "$network_name" >/dev/null 2>&1 || return
    owner=$(lxc network get "$network_name" user.lab-automation.owner 2>/dev/null || true)
    if [[ "$owner" != "$env_name" ]]; then
        log_warn "Skipping network cleanup for ${network_name}: owner is ${owner:-unset}, expected ${env_name}."
        return
    fi

    if lxc network delete "$network_name" >/dev/null 2>&1; then
        log_info "Removed owned MicroCloud network: ${network_name}"
    else
        log_warn "Could not remove owned MicroCloud network ${network_name}; check whether it is still in use."
    fi
}

microcloud_network_mode_label() {
    if [[ "$MICROCLOUD_NETWORK_MODE" == "fully-segregated-4nic" ]]; then
        echo "Fully Segregated - 4 NICs"
    else
        echo "Standard - 2 NICs"
    fi
}

get_guest_interface_for_device() {
    local node="$1"
    local device="$2"
    local mac=""

    mac=$(lxc config device get "$node" "$device" hwaddr 2>/dev/null || true)
    if [[ -z "$mac" ]]; then
        echo ""
        return
    fi

    lxc exec "$node" -- ip -o link show 2>/dev/null \
        | awk -F': ' -v mac="$mac" 'tolower($0) ~ tolower(mac) {print $2; exit}' \
        || true
}

verify_microcloud_network_planes() {
    local ws_name="$1"
    local node_count="$2"
    local lxd_prefix="${ws_name//_/-}"
    local node=""
    local iface=""
    local plane=""
    local cidr=""
    local expected_ip=""
    local actual_ip=""
    local peer_ip=""
    local route=""
    local default_route=""
    local management_iface=""
    local uplink_iface=""
    local uplink_state=""

    print_section "MicroCloud Network Validation"
    for ((i = 1; i <= node_count; i++)); do
        node="${lxd_prefix}-node-${i}"
        log_info "Waiting for $(microcloud_network_mode_label) configuration on ${node}..."
        if ! lxc exec "$node" -- cloud-init status --wait >/dev/null; then
            log_warn "cloud-init did not complete successfully on ${node}."
            exit 1
        fi

        management_iface=$(get_guest_interface_for_device "$node" "eth0")
        uplink_iface=$(get_guest_interface_for_device "$node" "eth1")
        if [[ -z "$management_iface" || -z "$uplink_iface" ]]; then
            log_warn "Could not map the management and OVN uplink devices by MAC address on ${node}."
            exit 1
        fi

        if [[ "$MICROCLOUD_NETWORK_MODE" == "fully-segregated-4nic" ]]; then
            for iface in ovn-underlay ceph-general; do
                if ! lxc exec "$node" -- ip link show dev "$iface" >/dev/null 2>&1; then
                    log_warn "Expected interface ${iface} is missing on ${node}."
                    exit 1
                fi
            done
        fi

        for iface in "$management_iface" "$uplink_iface"; do
            if ! lxc exec "$node" -- ip link show dev "$iface" >/dev/null 2>&1; then
                log_warn "Expected interface ${iface} is missing on ${node}."
                exit 1
            fi
        done

        uplink_state=$(lxc exec "$node" -- ip -br link show dev "$uplink_iface" 2>/dev/null | awk '{print $2}')
        if [[ "$uplink_state" != "UP" ]]; then
            log_warn "OVN uplink ${uplink_iface} is ${uplink_state:-unavailable}, expected UP on ${node}."
            exit 1
        fi

        if lxc exec "$node" -- ip -o addr show dev "$uplink_iface" | grep -Eq 'inet6? '; then
            log_warn "OVN uplink ${uplink_iface} unexpectedly has an IP address on ${node}."
            exit 1
        fi

        default_route=$(lxc exec "$node" -- ip -4 route show default 2>/dev/null || true)
        if [[ "$default_route" != *" dev ${management_iface}"* ]]; then
            log_warn "The default route on ${node} is not carried by ${management_iface}."
            exit 1
        fi

        [[ "$MICROCLOUD_NETWORK_MODE" == "fully-segregated-4nic" ]] || continue

        for plane in ovn-underlay ceph-general; do
            if [[ "$plane" == "ovn-underlay" ]]; then
                cidr="$MICROCLOUD_OVN_UNDERLAY_CIDR"
            else
                cidr="$MICROCLOUD_CEPH_GENERAL_CIDR"
            fi

            expected_ip=$(cidr_host_address "$cidr" $((i + 9)))
            actual_ip=$(
                lxc exec "$node" -- ip -4 -o addr show dev "$plane" scope global 2>/dev/null \
                    | awk '{split($4, address, "/"); print address[1]; exit}'
            )
            if [[ "$actual_ip" != "$expected_ip" ]]; then
                log_warn "${node} ${plane} has ${actual_ip:-no IPv4 address}; expected ${expected_ip}."
                exit 1
            fi
        done
    done

    if [[ "$MICROCLOUD_NETWORK_MODE" == "standard-2nic" ]]; then
        log_success "All MicroCloud nodes have an UP, IP-free Standard OVN uplink and a management default route."
        return
    fi

    for ((i = 1; i <= node_count; i++)); do
        node="${lxd_prefix}-node-${i}"
        for plane in ovn-underlay ceph-general; do
            if [[ "$plane" == "ovn-underlay" ]]; then
                cidr="$MICROCLOUD_OVN_UNDERLAY_CIDR"
            else
                cidr="$MICROCLOUD_CEPH_GENERAL_CIDR"
            fi
            expected_ip=$(cidr_host_address "$cidr" $((i + 9)))

            for ((j = 1; j <= node_count; j++)); do
                ((i == j)) && continue
                peer_ip=$(cidr_host_address "$cidr" $((j + 9)))
                route=$(lxc exec "$node" -- ip -4 route get "$peer_ip" 2>/dev/null || true)
                if [[ "$route" != *" dev ${plane}"* || "$route" != *" src ${expected_ip}"* ]]; then
                    log_warn "${node} has no ${plane} route to ${peer_ip} with source ${expected_ip}."
                    exit 1
                fi
                if ! lxc exec "$node" -- ping -I "$plane" -c 1 -W 2 "$peer_ip" >/dev/null; then
                    log_warn "${node} cannot reach ${peer_ip} over ${plane}."
                    exit 1
                fi
            done
        done
    done

    log_success "All MicroCloud nodes have persistent four-NIC addressing and all-to-all plane connectivity."
}

print_microcloud_summary() {
    local ws_name="$1"
    local lxd_prefix="${ws_name//_/-}"
    local first_node=""
    local health="UNKNOWN"
    local health_upper="UNKNOWN"
    local health_color="$YELLOW"
    local ip=""

    mapfile -t nodes < <(list_lxd_instances_by_prefix "${lxd_prefix}-node-" || true)

    if [[ ${#nodes[@]} -eq 0 ]]; then
        log_warn "Could not find MicroCloud nodes for summary output."
        return
    fi

    first_node="${nodes[0]}"
    health=$(lxc exec "$first_node" -- microcloud status 2>/dev/null | awk '/Status:/ {print $2; exit}')
    health="${health:-UNKNOWN}"
    health_upper=$(echo "$health" | tr '[:lower:]' '[:upper:]')

    if [[ "$health_upper" == "ONLINE" || "$health_upper" == "HEALTHY" ]]; then
        health_color="$GREEN"
    elif [[ "$health_upper" == "OFFLINE" || "$health_upper" == "ERROR" || "$health_upper" == "DEGRADED" ]]; then
        health_color="$RED"
    fi

    print_section "MicroCloud Deployment Summary"
    print_kv "Cluster health" "${health_color}${health}${NC}"
    print_kv "Node count" "${#nodes[@]}"
    print_kv "Network mode" "$(microcloud_network_mode_label)"
    if [[ "$MICROCLOUD_NETWORK_MODE" == "fully-segregated-4nic" ]]; then
        print_kv "OVN underlay" "$MICROCLOUD_OVN_UNDERLAY_CIDR"
        print_kv "Ceph general" "$MICROCLOUD_CEPH_GENERAL_CIDR"
    fi
    print_kv "UI port" "8443"
    echo ""
    printf '  %-28s %-16s %s\n' "Node" "IP" "UI"
    printf '  %-28s %-16s %s\n' "----------------------------" "----------------" "------------------------------"

    for node in "${nodes[@]}"; do
        ip=$(get_node_primary_ip "$node")
        ip="${ip:-N/A}"
        if [[ "$ip" == "N/A" ]]; then
            printf '  %-28s %-16s %s\n' "$node" "$ip" "-"
        else
            printf '  %-28s %-16s %s\n' "$node" "$ip" "https://${ip}:8443"
        fi
    done
}

print_microcloud_infra_summary() {
    local ws_name="$1"
    local lxd_prefix="${ws_name//_/-}"
    local ip=""

    mapfile -t nodes < <(list_lxd_instances_by_prefix "${lxd_prefix}-node-" || true)

    if [[ ${#nodes[@]} -eq 0 ]]; then
        log_warn "Could not find MicroCloud nodes for summary output."
        return
    fi

    print_section "MicroCloud Training Lab Summary"
    print_kv "Deployment type" "Training / Infrastructure Only"
    print_kv "Node count" "${#nodes[@]}"
    print_kv "Network mode" "$(microcloud_network_mode_label)"
    if [[ "$MICROCLOUD_NETWORK_MODE" == "fully-segregated-4nic" ]]; then
        print_kv "OVN underlay" "$MICROCLOUD_OVN_UNDERLAY_CIDR"
        print_kv "Ceph general" "$MICROCLOUD_CEPH_GENERAL_CIDR"
    fi
    print_kv "MicroCloud packages" "Not installed (student task)"
    print_kv "Cluster init" "Not performed (student task)"
    print_kv "Local storage disk" "${MICROCLOUD_LOCAL_DISK_GIB} GB per node (third disk)"
    echo ""
    printf '  %-28s %-16s %s\n' "Node" "IP" "Next Step"
    printf '  %-28s %-16s %s\n' "----------------------------" "----------------" "------------------------------"

    for node in "${nodes[@]}"; do
        ip=$(get_node_primary_ip "$node")
        ip="${ip:-N/A}"
        printf '  %-28s %-16s %s\n' "$node" "$ip" "SSH and install MicroCloud"
    done
}

list_training_nodes() {
    local ws_name="$1"
    local scenario_name="$2"
    local lxd_prefix="${ws_name//_/-}"

    case "$scenario_name" in
        microcloud)
            list_lxd_instances_by_prefix "${lxd_prefix}-node-"
            ;;
        k8s-snap)
            list_lxd_instances_by_prefix "${lxd_prefix}-cp-"
            list_lxd_instances_by_prefix "${lxd_prefix}-worker-"
            ;;
        k8s-juju)
            if lxc info "${lxd_prefix}-ctrl" >/dev/null 2>&1; then
                echo "${lxd_prefix}-ctrl"
            fi
            list_lxd_instances_by_prefix "${lxd_prefix}-cp-"
            list_lxd_instances_by_prefix "${lxd_prefix}-worker-"
            ;;
    esac
}

verify_training_environment() {
    local ws_name="$1"
    local scenario_name="$2"
    local node=""
    local ip=""
    local attempt="0"
    local ssh_ready=false
    local -a training_nodes=()

    mapfile -t training_nodes < <(list_training_nodes "$ws_name" "$scenario_name")
    if [[ ${#training_nodes[@]} -eq 0 ]]; then
        log_warn "No training nodes were found after infrastructure provisioning."
        exit 1
    fi

    print_section "Training Infrastructure Validation"
    for node in "${training_nodes[@]}"; do
        log_info "Waiting for cloud-init on ${node}..."
        if ! lxc exec "$node" -- cloud-init status --wait >/dev/null; then
            log_warn "cloud-init did not complete successfully on ${node}."
            exit 1
        fi

        ssh_ready=false
        for ((attempt = 1; attempt <= 24; attempt++)); do
            ip=$(get_node_primary_ip "$node")
            if [[ -n "$ip" ]] && ssh \
                -i "$SSH_KEY_PATH" \
                -o BatchMode=yes \
                -o ConnectTimeout=5 \
                -o IdentitiesOnly=yes \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR \
                "ubuntu@${ip}" true; then
                ssh_ready=true
                break
            fi
            sleep 5
        done

        if [[ "$ssh_ready" != true ]]; then
            log_warn "SSH validation failed for ${node} (${ip:-no IP})."
            exit 1
        fi
        log_success "${node} is ready for training access (${ip})."
    done
}

print_k8s_training_summary() {
    local ws_name="$1"
    local scenario_name="$2"
    local lxd_prefix="${ws_name//_/-}"
    local title=""
    local next_step=""
    local node=""
    local role=""
    local ip=""
    local -a training_nodes=()

    if [[ "$scenario_name" == "k8s-snap" ]]; then
        title="Canonical K8s Snap Training Lab Summary"
        next_step="Install Canonical K8s"
    else
        title="Canonical K8s Juju Training Lab Summary"
        next_step="Install Juju and deploy K8s"
    fi

    mapfile -t training_nodes < <(list_training_nodes "$ws_name" "$scenario_name")

    print_section "$title"
    print_kv "Deployment type" "Training / Infrastructure Only"
    print_kv "Node count" "${#training_nodes[@]}"
    print_kv "Kubernetes packages" "Not installed (student task)"
    print_kv "Cluster bootstrap" "Not performed (student task)"
    if [[ "$scenario_name" == "k8s-juju" ]]; then
        print_kv "Juju packages/bootstrap" "Not installed or performed (student task)"
    fi
    echo ""
    printf '  %-34s %-18s %-16s %s\n' "Node" "Role" "IP" "Next Step"
    printf '  %-34s %-18s %-16s %s\n' "----------------------------------" "------------------" "----------------" "------------------------------"

    for node in "${training_nodes[@]}"; do
        case "$node" in
            "${lxd_prefix}-ctrl") role="Juju controller" ;;
            *-cp-*) role="Control plane" ;;
            *-worker-*) role="Worker" ;;
            *) role="Training node" ;;
        esac
        ip=$(get_node_primary_ip "$node")
        printf '  %-34s %-18s %-16s %s\n' "$node" "$role" "${ip:-N/A}" "$next_step"
    done
}

print_k8s_summary() {
    local ws_name="$1"
    local lxd_prefix="${ws_name//_/-}"
    local first_cp=""
    local api_ip=""

    mapfile -t cp_nodes < <(list_lxd_instances_by_prefix "${lxd_prefix}-cp-" || true)
    mapfile -t worker_nodes < <(list_lxd_instances_by_prefix "${lxd_prefix}-worker-" || true)

    if [[ ${#cp_nodes[@]} -eq 0 ]]; then
        log_warn "Could not find K8s control-plane nodes for summary output."
        return
    fi

    first_cp="${cp_nodes[0]}"
    api_ip="$(get_node_primary_ip "$first_cp")"
    api_ip="${api_ip:-N/A}"

    print_section "Kubernetes Deployment Summary"
    print_kv "Control-plane nodes" "${#cp_nodes[@]}"
    print_kv "Worker nodes" "${#worker_nodes[@]}"
    print_kv "Kube API endpoint" "https://${api_ip}:6443"
    echo ""

    echo "Control-plane:"

    for node in "${cp_nodes[@]}"; do
        ip=$(get_node_primary_ip "$node")
        ip="${ip:-N/A}"
        printf '  - %s (%s)\n' "$node" "$ip"
    done

    if [[ ${#worker_nodes[@]} -gt 0 ]]; then
        echo ""
        echo "Workers:"
        for node in "${worker_nodes[@]}"; do
            ip=$(get_node_primary_ip "$node")
            ip="${ip:-N/A}"
            printf '  - %s (%s)\n' "$node" "$ip"
        done
    fi

    echo ""
    echo "Node status:"
    printf '  %-34s %-8s %-22s %-16s %s\n' "Name" "Status" "Roles" "Internal IP" "Version"
    printf '  %-34s %-8s %-22s %-16s %s\n' "----------------------------------" "--------" "----------------------" "----------------" "--------"
    while read -r name status roles age version internal_ip _; do
        [[ -z "${name:-}" ]] && continue
        status_color="$RED"
        if [[ "$status" == "Ready" ]]; then
            status_color="$GREEN"
        elif [[ "$status" == "SchedulingDisabled" ]]; then
            status_color="$YELLOW"
        fi

        printf '  %-34s %b%-8s%b %-22s %-16s %s\n' "$name" "$status_color" "$status" "$NC" "$roles" "$internal_ip" "$version"
    done < <(lxc exec "$first_cp" -- k8s kubectl get nodes -o wide --no-headers)
}

print_k8s_juju_summary() {
    local ws_name="$1"
    local lxd_prefix="${ws_name//_/-}"
    local ctrl_node="${lxd_prefix}-ctrl"
    local first_cp=""
    local api_ip=""

    mapfile -t cp_nodes < <(list_lxd_instances_by_prefix "${lxd_prefix}-cp-" || true)
    mapfile -t worker_nodes < <(list_lxd_instances_by_prefix "${lxd_prefix}-worker-" || true)

    print_section "K8s Juju Deployment Summary"
    print_kv "Juju controller VM" "$ctrl_node"
    print_kv "Control-plane nodes" "${#cp_nodes[@]}"
    print_kv "Worker nodes" "${#worker_nodes[@]}"
    echo ""

    ctrl_ip=$(get_node_primary_ip "$ctrl_node")
    print_kv "Juju controller IP" "${ctrl_ip:-N/A}"

    echo ""
    echo "Control-plane:"
    for node in "${cp_nodes[@]}"; do
        ip=$(get_node_primary_ip "$node")
        printf '  - %s (%s)\n' "$node" "${ip:-N/A}"
    done

    if [[ ${#worker_nodes[@]} -gt 0 ]]; then
        echo ""
        echo "Workers:"
        for node in "${worker_nodes[@]}"; do
            ip=$(get_node_primary_ip "$node")
            printf '  - %s (%s)\n' "$node" "${ip:-N/A}"
        done
    fi
}

ensure_tools() {
    if ! command -v tofu &> /dev/null; then
        log_info "Installing OpenTofu..."
        sudo snap install --classic opentofu
    fi
    if ! command -v ansible &> /dev/null; then
        log_info "Installing Ansible..."
        sudo apt update && sudo apt install -y ansible
    fi
    if ! command -v python3 &> /dev/null; then
        log_warn "Python 3 is required for MicroCloud subnet validation."
        exit 1
    fi
    
    # Install LXD connection plugin for Ansible
    ansible-galaxy collection install community.general >/dev/null 2>&1

    # Ensure Lab SSH Key exists for VM Access
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    chmod 0700 "$(dirname "$SSH_KEY_PATH")"
    if [ ! -f "$SSH_KEY_PATH" ]; then
        log_info "Lab SSH key not found. Generating one at $SSH_KEY_PATH..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
    fi
    if [[ ! -s "${SSH_KEY_PATH}.pub" ]]; then
        log_info "Lab SSH public key not found. Rebuilding it from the private key..."
        ssh-keygen -y -f "$SSH_KEY_PATH" > "${SSH_KEY_PATH}.pub"
        chmod 0644 "${SSH_KEY_PATH}.pub"
    fi
    export TF_VAR_ssh_public_key
    TF_VAR_ssh_public_key=$(cat "${SSH_KEY_PATH}.pub")
}

destroy_menu() {
    # Get active workspaces (ignoring default)
    mapfile -t envs < <(
        tofu workspace list \
            | sed 's/^\*\s*//' \
            | sed 's/^\s*//' \
            | awk 'NF' \
            | grep -v '^default$'
    )
    
    if [ ${#envs[@]} -eq 0 ]; then
        echo -e "${YELLOW}No active lab environments (workspaces) found to delete.${NC}"
        exit 0
    fi

    echo ""
    echo -e "${RED}--- ACTIVE ENVIRONMENTS ---${NC}"
    for i in "${!envs[@]}"; do
        echo "$((i+1))) ${envs[$i]}"
    done
    echo "0) Cancel and Exit"
    echo ""
    
    echo ""
    read -p "Select the environment number to destroy: " env_idx
    
    if [[ "$env_idx" == "0" || -z "$env_idx" ]]; then
        echo "Cancelled."
        exit 0
    fi

    if ! [[ "$env_idx" =~ ^[0-9]+$ ]] || (( env_idx < 1 || env_idx > ${#envs[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    selected_env=${envs[$((env_idx-1))]}
    local env_prefix=""
    local env_scenario=""
    local env_deployment_mode=""
    local current_microcloud_node_count="3"

    if ! read -r env_prefix env_scenario env_deployment_mode < <(parse_workspace_metadata "$selected_env"); then
        log_warn "Workspace name is not recognized as a managed lab: ${selected_env}"
        exit 1
    fi

    log_warn "Selected environment for destruction: ${selected_env}"
    echo ""
    read -p "Type 'yes' to destroy ${selected_env}: " destroy_confirm

    if [[ "$destroy_confirm" != "yes" ]]; then
        echo "Cancelled."
        exit 0
    fi

    if [[ "$env_scenario" == "k8s-snap" ]]; then
        read -r current_k8s_cp_count current_k8s_worker_count < <(get_k8s_topology_from_state "$selected_env")
    else
        current_k8s_cp_count=3
        current_k8s_worker_count=1
    fi

    if [[ "$env_scenario" == "k8s-juju" ]]; then
        read -r current_k8s_cp_count current_k8s_worker_count < <(get_k8s_juju_topology_from_state "$selected_env")
    fi

    if [[ "$env_scenario" == "microcloud" ]]; then
        current_microcloud_node_count=$(get_microcloud_node_count_from_state "$selected_env")
        if (( current_microcloud_node_count < 3 )); then
            current_microcloud_node_count=3
        fi
    fi

    log_warn "Destroying environment: ${selected_env}..."
    destroy_environment \
        "$selected_env" "$env_prefix" "$env_scenario" \
        "$current_k8s_cp_count" "$current_k8s_worker_count" \
        "$env_deployment_mode" "$current_microcloud_node_count"
    
    log_success "Environment ${selected_env} successfully destroyed and cleaned up!"
}

main() {
    if (( EUID == 0 )); then
        log_warn "Do not run orchestrate.sh as root or with sudo."
        log_warn "Run ./prep_host.sh as your regular user, refresh lxd group membership if prompted, then run ./orchestrate.sh."
        exit 1
    fi

    cd "$SCRIPT_DIR"
    clear
echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN}         CANONICAL LAB DEPLOYMENT ENGINE                  ${NC}"
echo -e "${CYAN}==========================================================${NC}"

ensure_tools
detect_lxd_defaults
if ! tofu init -input=false; then
    log_warn "OpenTofu initialization failed. Script cannot continue."
    log_warn "Please fix the error above and rerun ./orchestrate.sh."
    exit 1
fi

print_section "FULL LAB DEPLOYMENTS"
echo "  1) MicroCloud (automated deployment)"
echo "  2) Canonical K8s - Snap (automated deployment)"
echo "  3) Canonical K8s - Juju (automated deployment)"
print_section "TRAINING LABS - INFRASTRUCTURE ONLY"
echo "  4) MicroCloud Training"
echo "  5) Canonical K8s - Snap Training"
echo "  6) Canonical K8s - Juju Training"
print_section "ENVIRONMENT MANAGEMENT"
echo "  7) Destroy Environments"
echo "  0) Exit"
echo ""
read -p "Select action: " action

if [[ "$action" == "7" ]]; then
    destroy_menu
    exit 0
fi

case $action in
    0) echo "Cancelled."; exit 0 ;;
    1)
        scenario="microcloud"
        DEPLOYMENT_MODE="full"
        ;;
    2) scenario="k8s-snap"; DEPLOYMENT_MODE="full" ;;
    3) scenario="k8s-juju"; DEPLOYMENT_MODE="full" ;;
    4)
        scenario="microcloud"
        DEPLOYMENT_MODE="training"
        ;;
    5) scenario="k8s-snap"; DEPLOYMENT_MODE="training" ;;
    6) scenario="k8s-juju"; DEPLOYMENT_MODE="training" ;;
    *) echo "Invalid selection."; exit 1 ;;
esac

# --- Lab selection menu ---
mapfile -t existing_labs < <(list_existing_labs_for_scenario "$scenario" "$DEPLOYMENT_MODE")

if [[ "$DEPLOYMENT_MODE" == "training" ]]; then
    print_section "Existing Training Labs"
else
    print_section "Existing Full Labs"
fi
if [[ ${#existing_labs[@]} -eq 0 ]]; then
    echo "  No existing labs."
else
    if [[ "$scenario" == "k8s-snap" ]]; then
        printf '  %-20s %s\n' "Lab" "Topology"
        printf '  %-20s %s\n' "--------------------" "--------"
        for lab in "${existing_labs[@]}"; do
            lab_prefix="$(get_lab_prefix_from_workspace "$lab" "$scenario" "$DEPLOYMENT_MODE")"
            read -r _cp _w < <(get_k8s_topology_from_state "$lab")
            printf '  %-20s %s CP / %s worker\n' "$lab_prefix" "$_cp" "$_w"
        done
    elif [[ "$scenario" == "k8s-juju" ]]; then
        printf '  %-20s %s\n' "Lab" "Topology"
        printf '  %-20s %s\n' "--------------------" "--------"
        for lab in "${existing_labs[@]}"; do
            lab_prefix="$(get_lab_prefix_from_workspace "$lab" "$scenario" "$DEPLOYMENT_MODE")"
            read -r _cp _w < <(get_k8s_juju_topology_from_state "$lab")
            printf '  %-20s %s CP / %s worker\n' "$lab_prefix" "$_cp" "$_w"
        done
    else
        for lab in "${existing_labs[@]}"; do
            lab_prefix="$(get_lab_prefix_from_workspace "$lab" "$scenario" "$DEPLOYMENT_MODE")"
            _nodes="$(get_microcloud_node_count_from_state "$lab")"
            printf '  - %s (%s nodes)\n' "$lab_prefix" "$_nodes"
        done
    fi
fi

echo ""
if [[ ${#existing_labs[@]} -gt 0 ]]; then
    echo "  1) Deploy a new lab"
    echo "  2) Manage an existing lab"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " lab_action_choice
else
    echo "  1) Deploy a new lab"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " lab_action_choice
fi

case "$lab_action_choice" in
    0) echo "Cancelled."; exit 0 ;;
    1) lab_intent="new" ;;
    2)
        if [[ ${#existing_labs[@]} -eq 0 ]]; then
            echo "Invalid selection."; exit 1
        fi
        lab_intent="manage"
        ;;
    *) echo "Invalid selection."; exit 1 ;;
esac

# --- Resolve workspace ---
k8s_update_action="new"
k8s_juju_update_action="new"
current_k8s_cp_count=0
current_k8s_worker_count=0
k8s_control_plane_count=3
k8s_worker_count=1
k8s_juju_cp_count=1
k8s_juju_worker_count=1
K8S_JUJU_CP_CPU=2
K8S_JUJU_CP_MEMORY_GIB=4
K8S_JUJU_WORKER_CPU=2
K8S_JUJU_WORKER_MEMORY_GIB=4
user_prefix=""
workspace_name=""
workspace_suffix="$(get_workspace_suffix "$scenario" "$DEPLOYMENT_MODE")"
inventory_file=""
existing_workspace=false

if [[ "$lab_intent" == "new" ]]; then
    echo ""
    read -p "Enter a name for your new lab (e.g., your name): " user_prefix_input
    user_prefix=$(echo "$user_prefix_input" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
    if [[ -z "$user_prefix" ]]; then
        echo "Invalid lab name. Use letters and/or numbers."
        exit 1
    fi
    workspace_name="${user_prefix}_${workspace_suffix}"
    inventory_file="inventory_${workspace_name}.yaml"
    if workspace_exists "$workspace_name"; then
        echo "A lab named '${user_prefix}' already exists. Choose 'Manage an existing lab' to work with it."
        exit 1
    fi
else
    # Manage: show numbered list and let user pick
    print_section "Select a lab to manage"
    for i in "${!existing_labs[@]}"; do
        lab="${existing_labs[$i]}"
        lab_prefix="$(get_lab_prefix_from_workspace "$lab" "$scenario" "$DEPLOYMENT_MODE")"
        if [[ "$scenario" == "k8s-snap" ]]; then
            read -r _cp _w < <(get_k8s_topology_from_state "$lab")
            printf '  %d) %-20s %s CP / %s worker\n' "$((i+1))" "$lab_prefix" "$_cp" "$_w"
        elif [[ "$scenario" == "k8s-juju" ]]; then
            read -r _cp _w < <(get_k8s_juju_topology_from_state "$lab")
            printf '  %d) %-20s %s CP / %s worker\n' "$((i+1))" "$lab_prefix" "$_cp" "$_w"
        else
            _nodes="$(get_microcloud_node_count_from_state "$lab")"
            printf '  %d) %s (%s nodes)\n' "$((i+1))" "$lab_prefix" "$_nodes"
        fi
    done
    echo "  0) Cancel"
    echo ""
    read -p "Select: " lab_idx
    if [[ "$lab_idx" == "0" || -z "$lab_idx" ]]; then
        echo "Cancelled."; exit 0
    fi
    if ! [[ "$lab_idx" =~ ^[0-9]+$ ]] || (( lab_idx < 1 || lab_idx > ${#existing_labs[@]} )); then
        echo "Invalid selection."; exit 1
    fi
    selected_lab="${existing_labs[$((lab_idx-1))]}"
    user_prefix="$(get_lab_prefix_from_workspace "$selected_lab" "$scenario" "$DEPLOYMENT_MODE")"
    workspace_name="$selected_lab"
    inventory_file="inventory_${workspace_name}.yaml"
    existing_workspace=true

    if [[ "$scenario" == "k8s-snap" ]]; then
        read -r current_k8s_cp_count current_k8s_worker_count < <(get_k8s_topology_from_state "$workspace_name")
        print_section "Managing: ${user_prefix}"
        print_kv "Current topology" "${current_k8s_cp_count} CP / ${current_k8s_worker_count} worker"
        echo ""
        read -p "Choose action [add/rebuild/cancel, default: add]: " existing_lab_action
        existing_lab_action="${existing_lab_action:-add}"
        case "$existing_lab_action" in
            add)
                k8s_update_action="add"
                if [[ "$DEPLOYMENT_MODE" == "training" ]]; then
                    log_info "Update mode: add nodes to existing training infrastructure."
                else
                    log_info "Update mode: add nodes to existing cluster."
                fi
                ;;
            rebuild)
                k8s_update_action="rebuild"
                log_warn "Rebuilding existing lab: ${workspace_name}"
                destroy_environment \
                    "$workspace_name" "$user_prefix" "$scenario" \
                    "$current_k8s_cp_count" "$current_k8s_worker_count" "$DEPLOYMENT_MODE"
                existing_workspace=false
                ;;
            cancel)
                echo "Cancelled."; exit 0
                ;;
            *)
                echo "Invalid choice. Allowed values: add, rebuild, cancel."
                exit 1
                ;;
        esac
    elif [[ "$scenario" == "k8s-juju" ]]; then
        read -r current_k8s_cp_count current_k8s_worker_count < <(get_k8s_juju_topology_from_state "$workspace_name")
        print_section "Managing: ${user_prefix} (K8s Juju)"
        print_kv "Current topology" "${current_k8s_cp_count} CP / ${current_k8s_worker_count} worker"
        echo ""
        echo "  1) Update in place (expand/reconcile)"
        echo "  2) Rebuild  (destroy and redeploy from scratch)"
        echo "  3) Delete lab and exit"
        echo "  0) Cancel"
        echo ""
        read -p "Select: " juju_manage_action
        case "$juju_manage_action" in
            1|"")
                k8s_juju_update_action="add"
                if [[ "$DEPLOYMENT_MODE" == "training" ]]; then
                    log_info "Update mode: expand existing K8s Juju training infrastructure."
                else
                    log_info "Update mode: reconcile/expand existing K8s Juju lab."
                fi
                ;;
            2)
                k8s_juju_update_action="rebuild"
                log_warn "Rebuilding K8s Juju lab: ${workspace_name}"
                destroy_environment \
                    "$workspace_name" "$user_prefix" "$scenario" \
                    "$current_k8s_cp_count" "$current_k8s_worker_count" "$DEPLOYMENT_MODE"
                existing_workspace=false
                ;;
            3)
                log_warn "Deleting K8s Juju lab: ${workspace_name}"
                destroy_environment \
                    "$workspace_name" "$user_prefix" "$scenario" \
                    "$current_k8s_cp_count" "$current_k8s_worker_count" "$DEPLOYMENT_MODE"
                log_success "K8s Juju lab deleted."
                exit 0
                ;;
            0)
                echo "Cancelled."; exit 0
                ;;
            *)
                echo "Invalid selection."; exit 1
                ;;
        esac
    else
        # MicroCloud manage menu
        current_microcloud_node_count=$(get_microcloud_node_count_from_state "$workspace_name")
        if (( current_microcloud_node_count < 3 )); then
            current_microcloud_node_count=3
        fi
        print_section "Managing: ${user_prefix} (MicroCloud)"
        print_kv "Current topology" "${current_microcloud_node_count} nodes"
        echo ""
        echo "  1) Rebuild  (destroy and redeploy from scratch)"
        echo "  2) Delete lab and exit"
        echo "  0) Cancel"
        echo ""
        read -p "Select: " mc_manage_action
        case "$mc_manage_action" in
            1)
                log_warn "Rebuilding MicroCloud lab: ${workspace_name}"
                destroy_environment \
                    "$workspace_name" "$user_prefix" "$scenario" \
                    3 1 "$DEPLOYMENT_MODE" "$current_microcloud_node_count"
                existing_workspace=false
                ;;
            2)
                log_warn "Deleting MicroCloud lab: ${workspace_name}"
                destroy_environment \
                    "$workspace_name" "$user_prefix" "$scenario" \
                    3 1 "$DEPLOYMENT_MODE" "$current_microcloud_node_count"
                log_success "MicroCloud lab deleted."
                exit 0
                ;;
            0|"")
                echo "Cancelled."; exit 0
                ;;
            *)
                echo "Invalid selection."; exit 1
                ;;
        esac
    fi
fi

if [[ "$scenario" == "k8s-snap" ]]; then
    if [[ "$existing_workspace" == true && "$k8s_update_action" == "add" ]]; then
        echo ""
        read -p "Target control-plane nodes [default: ${current_k8s_cp_count}, allowed: 1 or 3, must be >= current]: " k8s_control_plane_count_input
        k8s_control_plane_count="${k8s_control_plane_count_input:-$current_k8s_cp_count}"

        if [[ "$k8s_control_plane_count" != "1" && "$k8s_control_plane_count" != "3" ]]; then
            echo "Invalid control-plane count. Allowed values: 1 or 3."
            exit 1
        fi

        if (( k8s_control_plane_count < current_k8s_cp_count )); then
            echo "Shrinking control-plane nodes in add mode is not supported. Choose rebuild to shrink."
            exit 1
        fi

        echo ""
        read -p "Target worker-only nodes [default: ${current_k8s_worker_count}, enter 0 for none, must be >= current]: " k8s_worker_count_input
        k8s_worker_count="${k8s_worker_count_input:-$current_k8s_worker_count}"

        if ! [[ "$k8s_worker_count" =~ ^[0-9]+$ ]]; then
            echo "Invalid worker count. It must be 0 or greater."
            exit 1
        fi

        if (( k8s_worker_count < current_k8s_worker_count )); then
            echo "Shrinking worker-only nodes in add mode is not supported. Choose rebuild to shrink."
            exit 1
        fi

        if [[ "$k8s_control_plane_count" == "$current_k8s_cp_count" && "$k8s_worker_count" == "$current_k8s_worker_count" ]]; then
            if [[ "$DEPLOYMENT_MODE" == "training" ]]; then
                log_info "Topology is unchanged. The training infrastructure will be validated in place."
            else
                log_info "Topology is unchanged. The existing lab will be checked and reconciled in place."
            fi
        else
            log_info "The existing lab will be expanded in place."
        fi
    else
        echo ""
        read -p "Number of control-plane nodes [default: 3, allowed: 1 or 3]: " k8s_control_plane_count_input
        k8s_control_plane_count="${k8s_control_plane_count_input:-3}"

        if [[ "$k8s_control_plane_count" != "1" && "$k8s_control_plane_count" != "3" ]]; then
            echo "Invalid control-plane count. Allowed values: 1 or 3."
            exit 1
        fi

        echo ""
        read -p "Number of worker-only nodes [default: 1, enter 0 for none]: " k8s_worker_count_input
        k8s_worker_count="${k8s_worker_count_input:-1}"

        if ! [[ "$k8s_worker_count" =~ ^[0-9]+$ ]]; then
            echo "Invalid worker count. It must be 0 or greater."
            exit 1
        fi
    fi

    if [[ "$k8s_update_action" == "add" ]]; then
        read -r K8S_CONTROL_PLANE_CPU K8S_CONTROL_PLANE_MEMORY_GIB K8S_WORKER_CPU K8S_WORKER_MEMORY_GIB < <(
            get_k8s_sizing_from_state "$workspace_name"
        )
        print_section "K8s Sizing (preserved from existing nodes)"
        print_kv "Control-plane" "${K8S_CONTROL_PLANE_CPU} vCPU / ${K8S_CONTROL_PLANE_MEMORY_GIB} GB"
        print_kv "Worker" "${K8S_WORKER_CPU} vCPU / ${K8S_WORKER_MEMORY_GIB} GB"
        print_kv "Note" "New nodes will be created with the same sizing as existing nodes"
    else
        configure_k8s_sizing "$k8s_control_plane_count" "$k8s_worker_count"
    fi
fi

if [[ "$scenario" == "microcloud" ]]; then
    echo ""
    read -p "MicroCloud node count [default: 3, allowed: 3-${MICROCLOUD_MAX_NODES}]: " microcloud_node_count_input
    MICROCLOUD_NODE_COUNT="${microcloud_node_count_input:-3}"

    if ! [[ "$MICROCLOUD_NODE_COUNT" =~ ^[0-9]+$ ]] \
        || (( MICROCLOUD_NODE_COUNT < 3 || MICROCLOUD_NODE_COUNT > MICROCLOUD_MAX_NODES )); then
        echo "Invalid MicroCloud node count. Enter a value from 3 to ${MICROCLOUD_MAX_NODES}."
        exit 1
    fi

    configure_microcloud_network_mode "$workspace_name"
    configure_microcloud_sizing "$MICROCLOUD_NODE_COUNT"
fi

if [[ "$scenario" == "k8s-juju" ]]; then
    if [[ "$existing_workspace" == true && "$k8s_juju_update_action" == "add" ]]; then
        echo ""
        read -p "Target control-plane nodes [default: ${current_k8s_cp_count}, allowed: 1 or 3, must be >= current]: " k8s_juju_cp_count_input
        k8s_juju_cp_count="${k8s_juju_cp_count_input:-$current_k8s_cp_count}"
    else
        echo ""
        read -p "Number of control-plane nodes [default: 1, allowed: 1 or 3]: " k8s_juju_cp_count_input
        k8s_juju_cp_count="${k8s_juju_cp_count_input:-1}"
    fi

    if [[ "$k8s_juju_cp_count" != "1" && "$k8s_juju_cp_count" != "3" ]]; then
        echo "Invalid control-plane count. Allowed values: 1 or 3."
        exit 1
    fi

    if [[ "$existing_workspace" == true && "$k8s_juju_update_action" == "add" ]] && (( k8s_juju_cp_count < current_k8s_cp_count )); then
        echo "Shrinking control-plane nodes in update mode is not supported. Choose rebuild to shrink."
        exit 1
    fi

    if [[ "$existing_workspace" == true && "$k8s_juju_update_action" == "add" ]]; then
        echo ""
        read -p "Target worker nodes [default: ${current_k8s_worker_count}, enter 1 or more, must be >= current]: " k8s_juju_worker_count_input
        k8s_juju_worker_count="${k8s_juju_worker_count_input:-$current_k8s_worker_count}"
    else
        echo ""
        read -p "Number of worker nodes [default: 1, enter 1 or more]: " k8s_juju_worker_count_input
        k8s_juju_worker_count="${k8s_juju_worker_count_input:-1}"
    fi

    if ! [[ "$k8s_juju_worker_count" =~ ^[0-9]+$ ]] || (( k8s_juju_worker_count < 1 )); then
        echo "Invalid worker count. It must be 1 or greater."
        exit 1
    fi

    if [[ "$existing_workspace" == true && "$k8s_juju_update_action" == "add" ]] && (( k8s_juju_worker_count < current_k8s_worker_count )); then
        echo "Shrinking worker nodes in update mode is not supported. Choose rebuild to shrink."
        exit 1
    fi

    if [[ "$existing_workspace" == true && "$k8s_juju_update_action" == "add" ]]; then
        if [[ "$k8s_juju_cp_count" == "$current_k8s_cp_count" && "$k8s_juju_worker_count" == "$current_k8s_worker_count" ]]; then
            if [[ "$DEPLOYMENT_MODE" == "training" ]]; then
                log_info "Topology is unchanged. The K8s Juju training infrastructure will be validated in place."
            else
                log_info "Topology is unchanged. The existing K8s Juju lab will be reconciled in place."
            fi
        else
            log_info "The existing K8s Juju lab will be expanded in place."
        fi

        read -r K8S_JUJU_CP_CPU K8S_JUJU_CP_MEMORY_GIB K8S_JUJU_WORKER_CPU K8S_JUJU_WORKER_MEMORY_GIB < <(
            get_k8s_sizing_from_state "$workspace_name"
        )
        print_section "K8s Juju Sizing (preserved from existing nodes)"
        print_kv "Control-plane" "${K8S_JUJU_CP_CPU} vCPU / ${K8S_JUJU_CP_MEMORY_GIB} GB"
        print_kv "Worker" "${K8S_JUJU_WORKER_CPU} vCPU / ${K8S_JUJU_WORKER_MEMORY_GIB} GB"
        print_kv "Note" "New nodes will be created with the same sizing as existing nodes"
    else
        configure_k8s_sizing "$k8s_juju_cp_count" "$k8s_juju_worker_count"
        K8S_JUJU_CP_CPU="$K8S_CONTROL_PLANE_CPU"
        K8S_JUJU_CP_MEMORY_GIB="$K8S_CONTROL_PLANE_MEMORY_GIB"
        K8S_JUJU_WORKER_CPU="$K8S_WORKER_CPU"
        K8S_JUJU_WORKER_MEMORY_GIB="$K8S_WORKER_MEMORY_GIB"
    fi
fi

log_info "Setting up OpenTofu workspace: ${workspace_name}..."
tofu workspace select "$workspace_name" 2>/dev/null || tofu workspace new "$workspace_name"

if [[ "$scenario" == "microcloud" ]]; then
    reconcile_microcloud_orphans_with_state "$workspace_name"
fi

MICROCLOUD_INFRA_ONLY_TF="false"
if [[ "$scenario" == "microcloud" && "$DEPLOYMENT_MODE" == "training" ]]; then
    MICROCLOUD_INFRA_ONLY_TF="true"
fi

MICROCLOUD_UPLINK_NETWORK_NAME=""
if [[ "$scenario" == "microcloud" ]]; then
    MICROCLOUD_UPLINK_NETWORK_NAME="$(resolve_microcloud_uplink_network_name "$workspace_name")"
    MICROCLOUD_OVN_UNDERLAY_NETWORK_NAME="$(resolve_microcloud_plane_network_name "$workspace_name" "ovn")"
    MICROCLOUD_CEPH_NETWORK_NAME="$(resolve_microcloud_plane_network_name "$workspace_name" "ceph")"

    ensure_owned_microcloud_network "$MICROCLOUD_UPLINK_NETWORK_NAME" "$workspace_name" "ovn-uplink"
    if [[ "$MICROCLOUD_NETWORK_MODE" == "fully-segregated-4nic" ]]; then
        ensure_owned_microcloud_network \
            "$MICROCLOUD_OVN_UNDERLAY_NETWORK_NAME" "$workspace_name" \
            "ovn-underlay" "$MICROCLOUD_OVN_UNDERLAY_CIDR"
        ensure_owned_microcloud_network \
            "$MICROCLOUD_CEPH_NETWORK_NAME" "$workspace_name" \
            "ceph-general" "$MICROCLOUD_CEPH_GENERAL_CIDR"
    fi
fi

log_info "Provisioning infrastructure with OpenTofu..."
tofu_apply_args=(
    -auto-approve
    -var="user_prefix=${user_prefix}"
    -var="scenario=${scenario}"
)

if [[ "$scenario" == "k8s-snap" ]]; then
    tofu_apply_args+=(
        -var="k8s_control_plane_count=${k8s_control_plane_count}"
        -var="k8s_worker_count=${k8s_worker_count}"
        -var="k8s_control_plane_cpu=${K8S_CONTROL_PLANE_CPU}"
        -var="k8s_control_plane_memory_gib=${K8S_CONTROL_PLANE_MEMORY_GIB}"
        -var="k8s_worker_cpu=${K8S_WORKER_CPU}"
        -var="k8s_worker_memory_gib=${K8S_WORKER_MEMORY_GIB}"
    )
    log_info "K8s topology: ${k8s_control_plane_count} control-plane node(s), ${k8s_worker_count} worker-only node(s)"
    log_info "K8s sizing: cp=${K8S_CONTROL_PLANE_CPU}vCPU/${K8S_CONTROL_PLANE_MEMORY_GIB}GB, worker=${K8S_WORKER_CPU}vCPU/${K8S_WORKER_MEMORY_GIB}GB"
elif [[ "$scenario" == "microcloud" ]]; then
    # Work around intermittent terraform-lxd provider state race during
    # concurrent volume creation by applying MicroCloud resources serially.
    tofu_apply_args+=(
        -var="microcloud_node_count=${MICROCLOUD_NODE_COUNT}"
        -var="microcloud_node_cpu=${MICROCLOUD_NODE_CPU}"
        -var="microcloud_node_memory_mb=${MICROCLOUD_NODE_MEMORY_MB}"
        -var="microcloud_root_disk_size_gib=${MICROCLOUD_ROOT_DISK_GIB}"
        -var="microcloud_ceph_disk_size_gib=${MICROCLOUD_CEPH_DISK_GIB}"
        -var="microcloud_local_disk_size_gib=${MICROCLOUD_LOCAL_DISK_GIB}"
        -var="microcloud_infra_only=${MICROCLOUD_INFRA_ONLY_TF}"
        -var="microcloud_uplink_network_name=${MICROCLOUD_UPLINK_NETWORK_NAME}"
        -var="microcloud_network_mode=${MICROCLOUD_NETWORK_MODE}"
        -var="microcloud_ovn_underlay_network_name=${MICROCLOUD_OVN_UNDERLAY_NETWORK_NAME}"
        -var="microcloud_ceph_network_name=${MICROCLOUD_CEPH_NETWORK_NAME}"
        -var="microcloud_ovn_underlay_cidr=${MICROCLOUD_OVN_UNDERLAY_CIDR}"
        -var="microcloud_ceph_general_cidr=${MICROCLOUD_CEPH_GENERAL_CIDR}"
        -parallelism=1
    )
    log_info "MicroCloud topology: ${MICROCLOUD_NODE_COUNT} node(s), deployment mode=${DEPLOYMENT_MODE}"
    log_info "MicroCloud network mode: $(microcloud_network_mode_label)"
    log_info "MicroCloud sizing: ${MICROCLOUD_NODE_CPU}vCPU/$((MICROCLOUD_NODE_MEMORY_MB / 1024))GB per node"
elif [[ "$scenario" == "k8s-juju" ]]; then
    tofu_apply_args+=(
        -var="k8s_juju_cp_count=${k8s_juju_cp_count}"
        -var="k8s_juju_worker_count=${k8s_juju_worker_count}"
        -var="k8s_juju_cp_cpu=${K8S_JUJU_CP_CPU}"
        -var="k8s_juju_cp_memory_gib=${K8S_JUJU_CP_MEMORY_GIB}"
        -var="k8s_juju_worker_cpu=${K8S_JUJU_WORKER_CPU}"
        -var="k8s_juju_worker_memory_gib=${K8S_JUJU_WORKER_MEMORY_GIB}"
    )
    log_info "K8s Juju topology: 1 Juju controller, ${k8s_juju_cp_count} control-plane node(s), ${k8s_juju_worker_count} worker node(s)"
    log_info "K8s Juju sizing: cp=${K8S_JUJU_CP_CPU}vCPU/${K8S_JUJU_CP_MEMORY_GIB}GB, worker=${K8S_JUJU_WORKER_CPU}vCPU/${K8S_JUJU_WORKER_MEMORY_GIB}GB"
fi

tofu apply "${tofu_apply_args[@]}"

if [[ "$scenario" == "microcloud" ]]; then
    verify_microcloud_network_planes "$workspace_name" "$MICROCLOUD_NODE_COUNT"
fi

if [[ "$scenario" == "k8s-snap" ]]; then
    if [[ "$DEPLOYMENT_MODE" == "training" ]]; then
        log_info "Skipping Canonical K8s installation and cluster bootstrap (training mode)..."
        verify_training_environment "$workspace_name" "$scenario"
        log_success "Canonical K8s Snap Training Lab Deployed Successfully!"
        print_k8s_training_summary "$workspace_name" "$scenario"
    else
        log_info "Running Ansible Orchestration for K8s..."
        ansible-playbook -i "$inventory_file" playbooks/k8s_snap.yml
        log_success "K8s Lab Deployed Successfully!"
        print_k8s_summary "$workspace_name"
    fi
    print_section "Access"
    print_kv "SSH" "ssh -i $SSH_KEY_PATH ubuntu@<VM_IP>"
elif [[ "$scenario" == "microcloud" ]]; then
    if [[ "$DEPLOYMENT_MODE" == "training" ]]; then
        log_info "Skipping MicroCloud package installation and cluster bootstrap (training mode)..."
        verify_training_environment "$workspace_name" "$scenario"
        log_success "MicroCloud Training Lab Deployed Successfully!"
        print_microcloud_infra_summary "$workspace_name"
    else
        log_info "Running Ansible Orchestration for MicroCloud..."
        ansible-playbook -i "$inventory_file" playbooks/microcloud.yml
        log_success "MicroCloud Lab Deployed Successfully!"
        print_microcloud_summary "$workspace_name"
    fi
    print_section "Access"
    print_kv "SSH" "ssh -i $SSH_KEY_PATH ubuntu@<VM_IP>"
fi

if [[ "$scenario" == "k8s-juju" ]]; then
    if [[ "$DEPLOYMENT_MODE" == "training" ]]; then
        log_info "Skipping Juju and Canonical K8s installation/bootstrap (training mode)..."
        verify_training_environment "$workspace_name" "$scenario"
        log_success "Canonical K8s Juju Training Lab Deployed Successfully!"
        print_k8s_training_summary "$workspace_name" "$scenario"
    else
        log_info "Running Ansible Orchestration for K8s (Juju)..."
        ansible-playbook -i "$inventory_file" playbooks/k8s_juju.yml
        log_success "K8s Juju Lab Deployed Successfully!"
        print_k8s_juju_summary "$workspace_name"
    fi
    print_section "Access"
    print_kv "SSH" "ssh -i $SSH_KEY_PATH ubuntu@<VM_IP>"
    if [[ "$DEPLOYMENT_MODE" == "full" ]]; then
        print_kv "Kubeconfig" "lxc exec <prefix>-ctrl -- sudo -u ubuntu -H juju run k8s/leader get-kubeconfig -m lab-controller:k8s-lab"
    fi
fi

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi