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
        ip=$(lxc list "$node" --format csv -c 4 | sed -E 's/ .*//' | cut -d'/' -f1)
        ip="${ip:-N/A}"
        log_info "- ${node} (${ip})"
    done

    log_info "UI access links:"
    for node in "${nodes[@]}"; do
        ip=$(lxc list "$node" --format csv -c 4 | sed -E 's/ .*//' | cut -d'/' -f1)
        if [[ -n "$ip" ]]; then
            log_info "- https://${ip}:8443"
        fi
    done
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

    log_warn "Warning! Destroying environment: ${selected_env}..."
    
    tofu workspace select "$selected_env" >/dev/null 2>&1
    tofu destroy -auto-approve -var="user_prefix=${env_prefix}" -var="scenario=${env_scenario}"
    
    tofu workspace select default >/dev/null 2>&1
    tofu workspace delete "$selected_env" >/dev/null 2>&1
    
    rm -f "inventory_${selected_env}.yaml"
    
    log_success "Environment ${selected_env} successfully destroyed and cleaned up!"
}

clear
echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN}    CANONICAL IaC DEPLOYMENT ENGINE (TOFU + ANSIBLE)       ${NC}"
echo -e "${CYAN}==========================================================${NC}"

ensure_tools
tofu init -v >/dev/null 2>&1

echo ""
echo "1) Deploy k8s-snap (3 Node Canonical Kubernetes)"
echo "2) Deploy microcloud (3 Node MicroCloud w/ Ceph & OVN)"
echo "3) Manage / Destroy Environments"
read -p "Select action: " action

if [[ "$action" == "3" ]]; then
    destroy_menu
    exit 0
fi

read -p "Enter your username/prefix (e.g., ismail): " user_prefix
user_prefix=$(echo "$user_prefix" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')

case $action in
    1) scenario="k8s-snap" ;;
    2) scenario="microcloud" ;;
    *) echo "Invalid selection."; exit 1 ;;
esac

workspace_name="${user_prefix}_${scenario}"
inventory_file="inventory_${workspace_name}.yaml"

log_info "Setting up OpenTofu workspace: ${workspace_name}..."
tofu workspace select "$workspace_name" 2>/dev/null || tofu workspace new "$workspace_name"

log_info "Provisioning infrastructure with OpenTofu..."
tofu apply -auto-approve -var="user_prefix=${user_prefix}" -var="scenario=${scenario}"

if [[ "$scenario" == "k8s-snap" ]]; then
    log_info "Running Ansible Orchestration for K8s..."
    ansible-playbook -i "$inventory_file" playbooks/k8s_snap.yml
    log_success "K8s Lab Deployed Successfully!"
    log_info "To access the machines, run: ssh -i $SSH_KEY_PATH ubuntu@<VM_IP>"
elif [[ "$scenario" == "microcloud" ]]; then
    log_info "Running Ansible Orchestration for MicroCloud..."
    ansible-playbook -i "$inventory_file" playbooks/microcloud.yml
    log_success "MicroCloud Lab Deployed Successfully!"
    print_microcloud_summary "$workspace_name"
    log_info "To access the machines, run: ssh -i $SSH_KEY_PATH ubuntu@<VM_IP>"
fi