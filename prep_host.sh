#!/bin/bash

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SSH_KEY_PATH="$HOME/.ssh/id_rsa_lab"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

ensure_sudo_session() {
    if ! sudo -n true 2>/dev/null; then
        log_info "Sudo authentication is required for host preparation."
        sudo -v
    fi
}

ensure_package() {
    local package_name="$1"

    if ! dpkg -s "$package_name" >/dev/null 2>&1; then
        log_info "Installing package: ${package_name}"
        sudo apt install -y "$package_name"
    fi
}

ensure_lxd() {
    if ! type -P lxd >/dev/null 2>&1 || ! type -P lxc >/dev/null 2>&1; then
        log_info "Installing LXD..."
        sudo snap install lxd
    fi

    log_info "Waiting for LXD daemon to become ready..."
    sudo lxd waitready --timeout=30

    if ! sudo lxc profile show default >/dev/null 2>&1; then
        log_info "Initializing LXD with default settings..."
        sudo lxd init --auto
    fi

    if ! groups "$USER" | grep -qw lxd; then
        log_info "Adding ${USER} to the lxd group..."
        sudo usermod -aG lxd "$USER"
        log_warn "Log out and back in for non-sudo LXD access."
    fi
}

ensure_opentofu() {
    if ! command -v tofu >/dev/null 2>&1; then
        log_info "Installing OpenTofu..."
        sudo snap install --classic opentofu
    fi
}

ensure_ansible() {
    if ! command -v ansible >/dev/null 2>&1; then
        log_info "Installing Ansible..."
        sudo apt update
        sudo apt install -y ansible
    fi

    if ! ansible-galaxy collection list community.general >/dev/null 2>&1; then
        log_info "Installing Ansible collection: community.general"
        ansible-galaxy collection install community.general >/dev/null 2>&1 || true
    fi
}

ensure_ssh_key() {
    ensure_package openssh-client

    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        log_info "Generating lab SSH key at $SSH_KEY_PATH..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
    fi
}

initialize_tofu() {
    log_info "Running OpenTofu init..."
    tofu init -input=false
}

main() {
    ensure_sudo_session
    ensure_lxd
    ensure_opentofu
    ensure_ansible
    ensure_ssh_key
    initialize_tofu
    log_success "Host preparation completed. You can now run ./orchestrate.sh"
}

main "$@"