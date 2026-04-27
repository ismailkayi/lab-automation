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

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

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

    log_info "Using LXD network: ${LXD_NETWORK_NAME}"
    log_info "Using LXD storage pool: ${LXD_STORAGE_POOL}"
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

    ip=$(lxc exec "$node" -- sh -c "ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if(\$i==\"src\") {print \$(i+1); exit}}'" 2>/dev/null || true)
    ip="$(echo "$ip" | tr -d '[:space:]')"

    if [[ -z "$ip" ]]; then
        ip=$(lxc list "$node" --format csv -c 4 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
    fi

    echo "$ip"
}

print_microcloud_summary() {
    local ws_name="$1"
    local lxd_prefix="${ws_name//_/-}"
    local first_node=""
    local health="UNKNOWN"

    mapfile -t nodes < <(lxc list --format csv -c n | grep "^${lxd_prefix}-node-" || true)

    if [[ ${#nodes[@]} -eq 0 ]]; then
        log_warn "Could not find MicroCloud nodes for summary output."
        return
    fi

    first_node="${nodes[0]}"
    health=$(lxc exec "$first_node" -- microcloud status 2>/dev/null | awk '/Status:/ {print $2; exit}')
    health="${health:-UNKNOWN}"

    log_info "MicroCloud lab is ready."
    log_info "Health: ${health}"
    log_info "Cluster nodes:"

    for node in "${nodes[@]}"; do
        ip=$(get_node_primary_ip "$node")
        ip="${ip:-N/A}"
        log_info "- ${node} (${ip})"
    done

    log_info "UI access links:"
    for node in "${nodes[@]}"; do
        ip=$(get_node_primary_ip "$node")
        if [[ -n "$ip" ]]; then
            log_info "- https://${ip}:8443"
        fi
    done
}

print_k8s_summary() {
    local ws_name="$1"
    local lxd_prefix="${ws_name//_/-}"
    local first_cp=""

    mapfile -t cp_nodes < <(lxc list --format csv -c n | grep "^${lxd_prefix}-k8s-cp-" || true)
    mapfile -t worker_nodes < <(lxc list --format csv -c n | grep "^${lxd_prefix}-k8s-worker-" || true)

    if [[ ${#cp_nodes[@]} -eq 0 ]]; then
        log_warn "Could not find K8s control-plane nodes for summary output."
        return
    fi

    first_cp="${cp_nodes[0]}"

    log_info "Canonical Kubernetes lab is ready."
    log_info "Cluster nodes:"

    for node in "${cp_nodes[@]}"; do
        ip=$(get_node_primary_ip "$node")
        ip="${ip:-N/A}"
        log_info "- ${node} (${ip}) [control-plane]"
    done

    for node in "${worker_nodes[@]}"; do
        ip=$(get_node_primary_ip "$node")
        ip="${ip:-N/A}"
        log_info "- ${node} (${ip}) [worker]"
    done

    log_info "Kube API endpoint: https://$(get_node_primary_ip "$first_cp"):6443"
    log_info "Cluster node status:"
    lxc exec "$first_cp" -- k8s kubectl get nodes -o wide | sed 's/^/[INFO] /'
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
echo -e "${CYAN}    CANONICAL IaC DEPLOYMENT ENGINE (TOFU + ANSIBLE)       ${NC}"
echo -e "${CYAN}==========================================================${NC}"

ensure_tools
detect_lxd_defaults
tofu init -v >/dev/null 2>&1

echo ""
echo "1) Deploy Canonical K8s (Snap)"
echo "2) Deploy MicroCloud (3 Node MicroCloud w/ Ceph & OVN)"
echo "3) Destroy Environments"
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
        read -p "Number of control-plane nodes [default: 3, allowed: 1 or 3]: " k8s_control_plane_count_input
        k8s_control_plane_count="${k8s_control_plane_count_input:-3}"

        if [[ "$k8s_control_plane_count" != "1" && "$k8s_control_plane_count" != "3" ]]; then
            echo "Invalid control-plane count. Allowed values: 1 or 3."
            exit 1
        fi

        read -p "Number of worker-only nodes [default: 1, enter 0 for none]: " k8s_worker_count_input
        k8s_worker_count="${k8s_worker_count_input:-1}"

        if ! [[ "$k8s_worker_count" =~ ^[0-9]+$ ]]; then
            echo "Invalid worker count. It must be 0 or greater."
            exit 1
        fi
    fi
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
    )
    log_info "K8s topology: ${k8s_control_plane_count} control-plane node(s), ${k8s_worker_count} worker-only node(s)"
elif [[ "$scenario" == "microcloud" ]]; then
    # Work around intermittent terraform-lxd provider state race during
    # concurrent volume creation by applying MicroCloud resources serially.
    tofu_apply_args+=(
        -parallelism=1
    )
fi

tofu apply "${tofu_apply_args[@]}"

if [[ "$scenario" == "k8s-snap" ]]; then
    log_info "Running Ansible Orchestration for K8s..."
    ansible-playbook -i "$inventory_file" playbooks/k8s_snap.yml
    log_success "K8s Lab Deployed Successfully!"
    print_k8s_summary "$workspace_name"
    log_info "To access the machines, run: ssh -i $SSH_KEY_PATH ubuntu@<VM_IP>"
elif [[ "$scenario" == "microcloud" ]]; then
    log_info "Running Ansible Orchestration for MicroCloud..."
    ansible-playbook -i "$inventory_file" playbooks/microcloud.yml
    log_success "MicroCloud Lab Deployed Successfully!"
    print_microcloud_summary "$workspace_name"
    log_info "To access the machines, run: ssh -i $SSH_KEY_PATH ubuntu@<VM_IP>"
fi