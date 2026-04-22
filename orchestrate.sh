#!/bin/bash

# ==============================================================================
# CANONICAL LAB ORCHESTRATOR RUNNER (Terraform + Ansible)
# ==============================================================================

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

ensure_tools() {
    log_info "Ensuring Ansible and Terraform are available..."
    if ! command -v terraform &> /dev/null; then
        sudo snap install terraform --classic
    fi
    if ! command -v ansible &> /dev/null; then
        sudo apt update && sudo apt install -y ansible
    fi
    # Install LXD connection plugin for Ansible
    ansible-galaxy collection install community.general >/dev/null 2>&1
}

clear
echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN}    CANONICAL IaC DEPLOYMENT ENGINE (TF + ANSIBLE)        ${NC}"
echo -e "${CYAN}==========================================================${NC}"

read -p "Enter your username/prefix: " user_prefix
user_prefix=$(echo "$user_prefix" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')

echo ""
echo "1) k8s-snap (3 Node Canonical Kubernetes)"
echo "2) microcloud (3 Node MicroCloud)"
echo "3) Destroy Environment"
read -p "Select action: " action

ensure_tools
terraform init -v >/dev/null 2>&1

case $action in
    1)
        log_info "Provisioning infrastructure with Terraform..."
        terraform apply -auto-approve -var="user_prefix=${user_prefix}" -var="scenario=k8s-snap"
        
        log_info "Running Ansible Orchestration for K8s..."
        ansible-playbook -i inventory.yaml playbooks/k8s_snap.yml
        
        log_success "K8s Lab Deployed Successfully!"
        ;;
    2)
        log_info "Provisioning infrastructure with Terraform..."
        terraform apply -auto-approve -var="user_prefix=${user_prefix}" -var="scenario=microcloud"
        log_info "MicroCloud infrastructure ready. (Ansible playbook for microcloud init can be added here)."
        ;;
    3)
        log_info "Destroying infrastructure with Terraform..."
        terraform destroy -auto-approve -var="user_prefix=${user_prefix}" -var="scenario=k8s-snap"
        terraform destroy -auto-approve -var="user_prefix=${user_prefix}" -var="scenario=microcloud"
        log_success "Environment wiped clean."
        ;;
    *)
        echo "Invalid selection."
        ;;
esac