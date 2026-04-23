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

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

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
    tofu workspace select default >/dev/null 2>&1
    tofu workspace delete "$env_name" >/dev/null 2>&1
    rm -f "inventory_${env_name}.yaml"
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

read -p "Enter your lab-name/prefix (e.g., ismail): " user_prefix_input
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