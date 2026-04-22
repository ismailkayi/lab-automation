#!/bin/bash

# ==============================================================================
# CANONICAL ADVANCED LAB ORCHESTRATOR v2.0 (Deep Integration)
# Targets: MicroCloud, Snap-based K8s, Juju Orchestration, MicroCeph
# Platform: LXD Virtual Machines (Heavy Duty Configuration)
# Description: Automated deployment engine for Canonical's ecosystem.
# ==============================================================================

# Exit on error, undefined vars, and pipe failures
set -euo pipefail

# --- Configuration Constants ---
UBUNTU_SERIES="noble" # Ubuntu 24.04 LTS
LXD_BRIDGE="lxdbr0"
CEPH_DISK_SIZE="50GiB"

# Resource Flavors
FLAVOR_MEDIUM_CPU=2
FLAVOR_MEDIUM_MEM="4GiB"
FLAVOR_LARGE_CPU=4
FLAVOR_LARGE_MEM="8GiB"

# --- Output Styling ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# --- User Isolation (Multi-tenant) ---

get_user_prefix() {
    clear
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${CYAN}       CANONICAL LAB ORCHESTRATOR - INITIALIZATION        ${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    read -p "Enter your username/initials for resource isolation: " raw_user
    
    # Sanitize input: lowercase and alphanumeric only to comply with hostname rules
    USER_PREFIX=$(echo "$raw_user" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
    
    if [[ -z "$USER_PREFIX" ]]; then
        log_warn "Empty input. Defaulting prefix to 'lab'"
        USER_PREFIX="lab"
    fi
    
    LAB_PROFILE_NAME="${USER_PREFIX}-canonical-advanced-lab"
    log_info "Active Session Prefix: '${USER_PREFIX}'"
    log_info "All resources will be created as '${USER_PREFIX}-<resource_name>'"
    sleep 2
}

# --- System Check & Pre-requisites ---

ensure_prerequisites() {
    log_info "Verifying host system prerequisites..."
    
    # Check Hardware Virtualization
    if ! grep -Eoc '(vmx|svm)' /proc/cpuinfo > /dev/null; then
        log_error "Hardware Virtualization (VT-x/AMD-V) is NOT enabled. VM deployment will fail."
        exit 1
    fi

    # Ensure Snapd is installed
    if ! command -v snap &> /dev/null; then
        log_warn "Snapd missing. Attempting installation..."
        sudo apt update && sudo apt install -y snapd
    fi

    # Ensure LXD is installed and initialized
    if ! command -v lxc &> /dev/null; then
        log_warn "LXD missing. Installing latest stable..."
        sudo snap install lxd --channel=latest/stable
        sudo lxd init --auto
    fi

    # Basic LXD health check using sudo
    if ! sudo lxc info &>/dev/null; then
        log_error "LXD daemon is not responding even with sudo. Please check LXD status (sudo snap services lxd)."
        exit 1
    fi
}

# --- LXD Resource Management ---

setup_advanced_profile() {
    local cpu=$1
    local mem=$2
    
    log_info "Creating/Updating LXD Profile: ${LAB_PROFILE_NAME} (${cpu} vCPU, ${mem} RAM)"
    
    sudo lxc profile create "${LAB_PROFILE_NAME}" 2>/dev/null || true
    
    # We use cloud-init to ensure SSH and basic tools are ready
    sudo lxc profile edit "${LAB_PROFILE_NAME}" <<EOF
config:
  limits.cpu: "${cpu}"
  limits.memory: "${mem}"
  security.nesting: "true"
  user.user-data: |
    #cloud-config
    package_update: true
    package_upgrade: true
    packages:
      - bridge-utils
      - cloud-utils
      - net-tools
      - nfs-common
    ssh_pwauth: true
    users:
      - name: ubuntu
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
description: Advanced Lab Profile for Canonical Stack
devices:
  eth0:
    name: eth0
    network: ${LXD_BRIDGE}
    type: nic
  root:
    path: /
    pool: default
    size: 40GiB
    type: disk
EOF
}

attach_ceph_disk() {
    local vm_name=$1
    log_info "Attaching secondary block device to ${vm_name} for Ceph/Storage..."
    sudo lxc storage volume create default "${vm_name}-ceph" --type block size=${CEPH_DISK_SIZE} 2>/dev/null || true
    sudo lxc config device add "${vm_name}" ceph-disk disk pool=default source="${vm_name}-ceph" 2>/dev/null || true
}

wait_for_boot() {
    local vm_name=$1
    log_info "Waiting for ${vm_name} to be reachable via SSH/Cloud-init..."
    until sudo lxc exec "${vm_name}" -- cloud-init status --wait > /dev/null 2>&1; do
        printf "."
        sleep 3
    done
    echo ""
    log_success "${vm_name} is up and initialized."
}

# --- Scenarios ---

deploy_microcloud() {
    log_info "Scenario: 3-Node MicroCloud Cluster"
    setup_advanced_profile ${FLAVOR_MEDIUM_CPU} ${FLAVOR_MEDIUM_MEM}
    
    for i in {1..3}; do
        local name="${USER_PREFIX}-microcloud-node-$i"
        sudo lxc launch "ubuntu:${UBUNTU_SERIES}" "${name}" --vm --profile "${LAB_PROFILE_NAME}"
        attach_ceph_disk "${name}"
        wait_for_boot "${name}"
        log_info "Installing MicroCloud stack on ${name}..."
        sudo lxc exec "${name}" -- snap install microcloud lxd microceph microovn
    done
    log_success "MicroCloud nodes provisioned. Run 'microcloud init' on ${USER_PREFIX}-microcloud-node-1."
}

deploy_k8s_snap() {
    log_info "Scenario: Snap-based Canonical K8s (3 nodes)"
    setup_advanced_profile ${FLAVOR_MEDIUM_CPU} ${FLAVOR_MEDIUM_MEM}
    
    for i in {1..3}; do
        local name="${USER_PREFIX}-k8s-node-$i"
        sudo lxc launch "ubuntu:${UBUNTU_SERIES}" "${name}" --vm --profile "${LAB_PROFILE_NAME}"
        wait_for_boot "${name}"
        log_info "Installing 'k8s' snap on ${name}..."
        sudo lxc exec "${name}" -- snap install k8s --channel=latest/stable --classic
        
        if [ "$i" -eq 1 ]; then
            log_info "Bootstrapping K8s Control Plane on ${name}..."
            sudo lxc exec "${name}" -- k8s bootstrap
        fi
    done
}

deploy_juju_k8s() {
    log_info "Scenario: Juju-based K8s (1 Controller, 3 Workers)"
    
    # Juju Controller needs more juice
    setup_advanced_profile ${FLAVOR_LARGE_CPU} ${FLAVOR_LARGE_MEM}
    local controller_name="${USER_PREFIX}-juju-controller"
    sudo lxc launch "ubuntu:${UBUNTU_SERIES}" "${controller_name}" --vm --profile "${LAB_PROFILE_NAME}"
    wait_for_boot "${controller_name}"
    sudo lxc exec "${controller_name}" -- snap install juju --classic
    
    # Workers
    setup_advanced_profile ${FLAVOR_MEDIUM_CPU} ${FLAVOR_MEDIUM_MEM}
    for i in {1..3}; do
        local worker_name="${USER_PREFIX}-juju-worker-$i"
        sudo lxc launch "ubuntu:${UBUNTU_SERIES}" "${worker_name}" --vm --profile "${LAB_PROFILE_NAME}"
        wait_for_boot "${worker_name}"
    done
}

deploy_juju_k8s_ceph() {
    log_info "Scenario: Juju-based K8s + Charmed MicroCeph"
    deploy_juju_k8s # Start with standard Juju prep
    
    for i in {1..3}; do
        local name="${USER_PREFIX}-juju-worker-$i"
        attach_ceph_disk "${name}"
        sudo lxc exec "${name}" -- snap install microceph
    done
    log_success "Hybrid stack ready. Ceph disks attached to all workers."
}

cleanup() {
    echo ""
    log_info "Scanning LXD for active lab environments..."
    
    # Extract prefixes from instances that match our naming convention
    local active_prefixes=$(sudo lxc list --format csv -c n | grep -E "-(microcloud|k8s|juju)-" | sed -E 's/-(microcloud|k8s|juju).*//' | sort -u)
    
    if [ -z "$active_prefixes" ]; then
        log_warn "No active lab environments matching known patterns were detected."
    else
        echo -e "${CYAN}Found the following active lab prefixes:${NC}"
        for p in $active_prefixes; do
            echo -e "  -> ${YELLOW}${p}${NC}"
        done
    fi
    echo ""

    read -p "Enter the username prefix whose lab you want to destroy [Current: ${USER_PREFIX}]: " target_user
    target_user=${target_user:-$USER_PREFIX}
    target_user=$(echo "$target_user" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')

    log_warn "DANGER: This will destroy all VMs, storage, and profiles starting with '${target_user}-'. Continue? (y/N)"
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        log_info "Cleaning up resources for user prefix '${target_user}'..."
        
        # Delete VMs
        sudo lxc list --format csv -c n | grep -E "^${target_user}-(microcloud|k8s|juju)-" | xargs -I {} sudo lxc delete -f {} || true
        
        # Clean up storage volumes
        sudo lxc storage volume list default --format csv | grep -E "^${target_user}-(microcloud|k8s|juju)-" | cut -d, -f2 | xargs -I {} sudo lxc storage volume delete default {} || true
        
        # Clean up profile
        sudo lxc profile delete "${target_user}-canonical-advanced-lab" 2>/dev/null || true
        
        log_success "Lab environment for '${target_user}' wiped."
    else
        log_info "Cleanup aborted."
    fi
}

# --- Main Interaction ---

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "=========================================================="
    echo "       CANONICAL LAB ORCHESTRATOR - ENTERPRISE v2        "
    echo "       Active Prefix: ${USER_PREFIX}"
    echo "=========================================================="
    echo -e "${NC}"
}

main_menu() {
    ensure_prerequisites
    get_user_prefix
    while true; do
        show_banner
        echo "1) [MicroCloud] - 3 Node Cluster (VMs + Secondary Disks)"
        echo "2) [K8s Snap]   - 3 Node Canonical Kubernetes (Official Snap)"
        echo "3) [Juju K8s]   - 1 Controller + 3 Worker Nodes"
        echo "4) [Juju+Ceph]  - Juju K8s with Charmed MicroCeph Integration"
        echo "5) [Cleanup]    - Destroy all lab VMs and Storage"
        echo "6) Exit"
        echo ""
        read -p "Select Deployment Scenario: " choice

        case $choice in
            1) deploy_microcloud ;;
            2) deploy_k8s_snap ;;
            3) deploy_juju_k8s ;;
            4) deploy_juju_k8s_ceph ;;
            5) cleanup ;;
            6) exit 0 ;;
            *) log_error "Invalid selection." ;;
        esac
        echo -e "\nPress Enter to return to menu..."
        read -r
    done
}

main_menu
