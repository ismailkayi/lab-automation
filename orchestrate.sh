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

SSH_KEY_PATH="$HOME/.ssh/id_rsa_lab"
LXD_NETWORK_NAME=""
LXD_STORAGE_POOL=""
MICROCLOUD_NODE_CPU="2"
MICROCLOUD_NODE_MEMORY_MB="4096"
MICROCLOUD_ROOT_DISK_GIB="40"
MICROCLOUD_CEPH_DISK_GIB="50"
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

    cpu_total=$(nproc 2>/dev/null || echo 4)
    ram_total_mb=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    storage_available_gib=$(get_storage_available_gib)
    host_ram_gb=$(( (ram_total_mb + 1023) / 1024 ))
    host_ram_per_node_gb=$(( host_ram_gb / 3 ))

    reserve_cpu=$(( cpu_total / 5 ))
    if (( reserve_cpu < 2 )); then reserve_cpu=2; fi
    usable_cpu=$(( cpu_total - reserve_cpu ))
    if (( usable_cpu < 3 )); then usable_cpu=3; fi

    reserve_ram_mb=$(( ram_total_mb / 5 ))
    if (( reserve_ram_mb < 4096 )); then reserve_ram_mb=4096; fi
    usable_ram_mb=$(( ram_total_mb - reserve_ram_mb ))
    if (( usable_ram_mb < 12288 )); then usable_ram_mb=12288; fi

    usable_disk_gib=$(( storage_available_gib - 20 ))
    if (( usable_disk_gib < 120 )); then usable_disk_gib=120; fi

    conservative_root_gib=30
    balanced_root_gib=40
    performance_root_gib=50

    raw_balanced_cpu=$(( usable_cpu / 3 ))
    balanced_cpu=$(round_down_even "$raw_balanced_cpu" 2)
    conservative_cpu=$(round_down_even $(( balanced_cpu - 2 )) 2)
    performance_cpu_limit=$(round_down_even $(( cpu_total / 3 )) "$balanced_cpu")
    performance_cpu=$(( balanced_cpu + 2 ))
    if (( performance_cpu > performance_cpu_limit )); then
        performance_cpu="$performance_cpu_limit"
    fi

    raw_balanced_memory_gb=$(( usable_ram_mb / 3072 ))
    balanced_memory_gb=$(pick_floor_tier "$raw_balanced_memory_gb" 8 12 16 24 32 48 64 96 128)
    conservative_memory_gb=$(pick_previous_tier "$balanced_memory_gb" 4 8 12 16 24 32 48 64 96 128)
    performance_memory_cap_gb=$(pick_floor_tier "$host_ram_per_node_gb" 8 12 16 24 32 48 64 96 128)
    performance_memory_gb=$(pick_next_tier "$balanced_memory_gb" "$performance_memory_cap_gb" 4 8 12 16 24 32 48 64 96 128)

    raw_balanced_ceph_gib=$(( (usable_disk_gib / 3) - balanced_root_gib ))
    if (( raw_balanced_ceph_gib < 20 )); then raw_balanced_ceph_gib=20; fi
    balanced_ceph_gib=$(pick_floor_tier "$raw_balanced_ceph_gib" 20 50 100 150 200 250 300 400 500)
    conservative_ceph_gib=$(pick_previous_tier "$balanced_ceph_gib" 20 50 100 150 200 250 300 400 500)
    performance_ceph_cap_gib=$(( (storage_available_gib / 3) - performance_root_gib ))
    if (( performance_ceph_cap_gib < 20 )); then performance_ceph_cap_gib=20; fi
    performance_cpu_cap=$(pick_floor_tier "$performance_ceph_cap_gib" 20 50 100 150 200 250 300 400 500)
    performance_ceph_gib=$(pick_next_tier "$balanced_ceph_gib" "$performance_cpu_cap" 20 50 100 150 200 250 300 400 500)

    balanced_memory_mb=$(( balanced_memory_gb * 1024 ))
    conservative_memory_mb=$(( conservative_memory_gb * 1024 ))
    performance_memory_mb=$(( performance_memory_gb * 1024 ))

    print_section "MicroCloud Sizing Advisor"
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

    if ! command -v lxc &> /dev/null; then
        log_warn "LXD CLI (lxc) not found. Run ./prep_host.sh first."
        exit 1
    fi

    if ! lxc info >/dev/null 2>&1; then
        log_warn "LXD is not reachable for the current user. Run ./prep_host.sh first."
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

workspace_exists() {
    local workspace_name="$1"
    tofu workspace list | tr -d '* ' | grep -qx "$workspace_name"
}

list_existing_labs_for_scenario() {
    local scenario_name="$1"
    tofu workspace list | tr -d '* ' | grep "_${scenario_name}$" || true
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
    local cp_node="${lxd_prefix}-k8s-cp-1"
    local worker_node="${lxd_prefix}-k8s-worker-1"
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

destroy_environment() {
    local env_name="$1"
    local env_prefix="$2"
    local env_scenario="$3"
    local env_k8s_cp_count="${4:-3}"
    local env_k8s_worker_count="${5:-1}"

    tofu workspace select "$env_name" >/dev/null 2>&1

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

    tofu destroy "${destroy_args[@]}"

    if [[ "$env_scenario" == "microcloud" ]]; then
        cleanup_microcloud_orphans "$env_name"
    fi

    tofu workspace select default >/dev/null 2>&1
    tofu workspace delete "$env_name" >/dev/null 2>&1
    rm -f "inventory_${env_name}.yaml"
}

cleanup_microcloud_orphans() {
    local env_name="$1"
    local lxd_prefix="${env_name//_/-}"
    local uplink_network="mc-${lxd_prefix:0:8}-up"
    local profile_name="${lxd_prefix}-iac-base"
    local storage_pool="${LXD_STORAGE_POOL}"

    # If provider state is inconsistent, these resources can remain orphaned.
    for i in 1 2 3; do
        lxc delete -f "${lxd_prefix}-node-${i}" >/dev/null 2>&1 || true
    done

    for i in 1 2 3; do
        lxc storage volume delete "$storage_pool" "${lxd_prefix}-ceph-${i}" >/dev/null 2>&1 || true
    done

    lxc network delete "$uplink_network" >/dev/null 2>&1 || true
    lxc profile delete "$profile_name" >/dev/null 2>&1 || true
}

reconcile_microcloud_orphans_with_state() {
    local env_name="$1"
    local lxd_prefix="${env_name//_/-}"
    local uplink_network="mc-${lxd_prefix:0:8}-up"
    local profile_name="${lxd_prefix}-iac-base"
    local storage_pool="${LXD_STORAGE_POOL}"
    local state_list=""

    state_list=$(tofu state list 2>/dev/null || true)

    if ! grep -q '^lxd_network\.ovn_uplink\[0\]$' <<< "$state_list"; then
        if lxc network show "$uplink_network" >/dev/null 2>&1; then
            log_warn "Removing orphan network not tracked in state: ${uplink_network}"
            lxc network delete "$uplink_network" >/dev/null 2>&1 || true
        fi
    fi

    if ! grep -q '^lxd_profile\.lab_base$' <<< "$state_list"; then
        if lxc profile show "$profile_name" >/dev/null 2>&1; then
            log_warn "Removing orphan profile not tracked in state: ${profile_name}"
            lxc profile delete "$profile_name" >/dev/null 2>&1 || true
        fi
    fi

    for i in 0 1 2; do
        local idx=$((i + 1))
        local vol_name="${lxd_prefix}-ceph-${idx}"
        local node_name="${lxd_prefix}-node-${idx}"

        if ! grep -q "^lxd_volume\\.microcloud_ceph_disks\\[${i}\\]$" <<< "$state_list"; then
            if lxc storage volume show "$storage_pool" "$vol_name" >/dev/null 2>&1; then
                log_warn "Removing orphan volume not tracked in state: ${storage_pool}/${vol_name}"
                lxc storage volume delete "$storage_pool" "$vol_name" >/dev/null 2>&1 || true
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

print_k8s_summary() {
    local ws_name="$1"
    local lxd_prefix="${ws_name//_/-}"
    local first_cp=""
    local api_ip=""

    mapfile -t cp_nodes < <(list_lxd_instances_by_prefix "${lxd_prefix}-k8s-cp-" || true)
    mapfile -t worker_nodes < <(list_lxd_instances_by_prefix "${lxd_prefix}-k8s-worker-" || true)

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

ensure_tools() {
    if ! command -v tofu &> /dev/null; then
        log_info "Installing OpenTofu..."
        sudo snap install --classic opentofu
    fi
    if ! command -v ansible &> /dev/null; then
        log_info "Installing Ansible..."
        sudo apt update && sudo apt install -y ansible
    fi
    
    # Install LXD connection plugin for Ansible
    ansible-galaxy collection install community.general >/dev/null 2>&1

    # Ensure Lab SSH Key exists for VM Access
    if [ ! -f "$SSH_KEY_PATH" ]; then
        log_info "Lab SSH key not found. Generating one at $SSH_KEY_PATH..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
    fi
    export TF_VAR_ssh_public_key=$(cat "${SSH_KEY_PATH}.pub")
}

destroy_menu() {
    # Get active workspaces (ignoring default)
    mapfile -t envs < <(tofu workspace list | tr -d '* ' | grep -v '^default$')
    
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
    
    if [[ "$env_idx" == "0" || -z "$env_idx" || "$env_idx" -gt "${#envs[@]}" ]]; then
        echo "Cancelled."
        exit 0
    fi

    selected_env=${envs[$((env_idx-1))]}
    
    # Extract prefix and scenario variables from the workspace name (e.g., ismail_microcloud)
    local env_prefix="${selected_env%_*}"
    local env_scenario="${selected_env#*_}"

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

    log_warn "Destroying environment: ${selected_env}..."
    destroy_environment "$selected_env" "$env_prefix" "$env_scenario" "$current_k8s_cp_count" "$current_k8s_worker_count"
    
    log_success "Environment ${selected_env} successfully destroyed and cleaned up!"
}

clear
echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN}         CANONICAL LAB DEPLOYMENT ENGINE                  ${NC}"
echo -e "${CYAN}==========================================================${NC}"

ensure_tools
detect_lxd_defaults
tofu init -v >/dev/null 2>&1

echo ""
echo "1) Deploy Canonical K8s (Snap)"
echo "2) Deploy MicroCloud (3 Node MicroCloud w/ Ceph & OVN)"
echo "3) Destroy Environments"
echo ""
read -p "Select action: " action

if [[ "$action" == "3" ]]; then
    destroy_menu
    exit 0
fi

case $action in
    1) scenario="k8s-snap" ;;
    2) scenario="microcloud" ;;
    *) echo "Invalid selection."; exit 1 ;;
esac

echo ""
log_info "Already deployed labs for ${scenario}:"
mapfile -t existing_labs < <(list_existing_labs_for_scenario "$scenario")
if [[ ${#existing_labs[@]} -eq 0 ]]; then
    log_info "- none"
else
    for lab in "${existing_labs[@]}"; do
        lab_prefix="${lab%_${scenario}}"
        log_info "- ${lab_prefix}"
    done
fi

echo ""
read -p "Enter your lab-name/prefix (e.g., your name): " user_prefix_input
user_prefix_input=$(normalize_lab_prefix_input "$user_prefix_input" "$scenario")
user_prefix=$(echo "$user_prefix_input" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')

if [[ -z "$user_prefix" ]]; then
    echo "Invalid lab-name. Use letters and/or numbers."
    exit 1
fi

workspace_name="${user_prefix}_${scenario}"
inventory_file="inventory_${workspace_name}.yaml"

existing_workspace=false
if workspace_exists "$workspace_name"; then
    existing_workspace=true
fi

k8s_update_action="new"
current_k8s_cp_count=0
current_k8s_worker_count=0
k8s_control_plane_count=3
k8s_worker_count=1

if [[ "$scenario" == "k8s-snap" && "$existing_workspace" == true ]]; then
    read -r current_k8s_cp_count current_k8s_worker_count < <(get_k8s_topology_from_state "$workspace_name")

    log_warn "Existing K8s lab detected: ${workspace_name}"
    log_info "Current topology: ${current_k8s_cp_count} control-plane node(s), ${current_k8s_worker_count} worker-only node(s)"
    echo ""
    read -p "Choose action for this existing lab [add/rebuild/cancel, default: add]: " existing_lab_action
    existing_lab_action="${existing_lab_action:-add}"

    case "$existing_lab_action" in
        add)
            k8s_update_action="add"
            log_info "Update mode: add nodes to existing cluster."
            ;;
        rebuild)
            k8s_update_action="rebuild"
            log_warn "Rebuilding existing lab: ${workspace_name}"
            destroy_environment "$workspace_name" "$user_prefix" "$scenario" "$current_k8s_cp_count" "$current_k8s_worker_count"
            existing_workspace=false
            ;;
        cancel)
            echo "Cancelled."
            exit 0
            ;;
        *)
            echo "Invalid choice. Allowed values: add, rebuild, cancel."
            exit 1
            ;;
    esac
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
            log_info "Topology is unchanged. The existing lab will be checked and reconciled in place."
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
    configure_microcloud_sizing
fi

log_info "Setting up OpenTofu workspace: ${workspace_name}..."
tofu workspace select "$workspace_name" 2>/dev/null || tofu workspace new "$workspace_name"

if [[ "$scenario" == "microcloud" ]]; then
    reconcile_microcloud_orphans_with_state "$workspace_name"
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
        -var="microcloud_node_cpu=${MICROCLOUD_NODE_CPU}"
        -var="microcloud_node_memory_mb=${MICROCLOUD_NODE_MEMORY_MB}"
        -var="microcloud_root_disk_size_gib=${MICROCLOUD_ROOT_DISK_GIB}"
        -var="microcloud_ceph_disk_size_gib=${MICROCLOUD_CEPH_DISK_GIB}"
        -parallelism=1
    )
fi

tofu apply "${tofu_apply_args[@]}"

if [[ "$scenario" == "k8s-snap" ]]; then
    log_info "Running Ansible Orchestration for K8s..."
    ansible-playbook -i "$inventory_file" playbooks/k8s_snap.yml
    log_success "K8s Lab Deployed Successfully!"
    print_k8s_summary "$workspace_name"
    print_section "Access"
    print_kv "SSH" "ssh -i $SSH_KEY_PATH ubuntu@<VM_IP>"
elif [[ "$scenario" == "microcloud" ]]; then
    log_info "Running Ansible Orchestration for MicroCloud..."
    ansible-playbook -i "$inventory_file" playbooks/microcloud.yml
    log_success "MicroCloud Lab Deployed Successfully!"
    print_microcloud_summary "$workspace_name"
    print_section "Access"
    print_kv "SSH" "ssh -i $SSH_KEY_PATH ubuntu@<VM_IP>"
fi