#!/bin/bash

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SSH_KEY_PATH="$HOME/.ssh/id_rsa_lab"

DONE_ITEMS=()
SKIPPED_ITEMS=()
WARN_ITEMS=()

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

add_done() { DONE_ITEMS+=("$1"); }
add_skipped() { SKIPPED_ITEMS+=("$1"); }
add_warn() { WARN_ITEMS+=("$1"); }

print_summary() {
    echo ""
    log_info "Host preparation summary"

    if [[ ${#DONE_ITEMS[@]} -gt 0 ]]; then
        echo "[DONE]"
        for item in "${DONE_ITEMS[@]}"; do
            echo "  - ${item}"
        done
    fi

    if [[ ${#SKIPPED_ITEMS[@]} -gt 0 ]]; then
        echo "[SKIPPED]"
        for item in "${SKIPPED_ITEMS[@]}"; do
            echo "  - ${item}"
        done
    fi

    if [[ ${#WARN_ITEMS[@]} -gt 0 ]]; then
        echo "[NOTES]"
        for item in "${WARN_ITEMS[@]}"; do
            echo "  - ${item}"
        done
    fi
}

ensure_sudo_session() {
    if ! sudo -n true 2>/dev/null; then
        log_info "Sudo authentication is required for host preparation."
        sudo -v
        add_done "Sudo session authenticated"
    else
        add_skipped "Sudo session already active"
    fi
}

ensure_lxd() {
    local bridge_count="0"
    local storage_count="0"

    if ! type -P lxd >/dev/null 2>&1 || ! type -P lxc >/dev/null 2>&1; then
        log_info "Installing LXD..."
        sudo snap install lxd
        add_done "LXD installed"
    else
        add_skipped "LXD already installed"
    fi

    log_info "Waiting for LXD daemon to become ready..."
    sudo lxd waitready --timeout=30
    add_done "LXD daemon is ready"

    bridge_count=$(sudo lxc network list --format csv -c t | grep -c '^bridge$' || true)
    storage_count=$(sudo lxc storage list --format csv -c n | grep -c '.' || true)

    if [[ "$bridge_count" -eq 0 || "$storage_count" -eq 0 ]]; then
        log_info "Initializing LXD with default settings..."
        sudo lxd init --auto
        add_done "LXD initialized (bridge network and storage pool prepared)"
    else
        add_skipped "LXD already initialized"
    fi

    if ! groups "$USER" | grep -qw lxd; then
        log_info "Adding ${USER} to the lxd group..."
        sudo usermod -aG lxd "$USER"
        log_warn "Log out and back in for non-sudo LXD access."
        add_done "User added to lxd group"
        add_warn "Log out and back in for non-sudo LXD access"
    else
        add_skipped "User already in lxd group"
    fi
}

ensure_opentofu() {
    if ! command -v tofu >/dev/null 2>&1; then
        log_info "Installing OpenTofu..."
        sudo snap install --classic opentofu
        add_done "OpenTofu installed"
    else
        add_skipped "OpenTofu already installed"
    fi
}

ensure_ansible() {
    if ! command -v ansible >/dev/null 2>&1; then
        log_info "Installing Ansible..."
        sudo apt update
        sudo apt install -y ansible
        add_done "Ansible installed"
    else
        add_skipped "Ansible already installed"
    fi

    if ! ansible-galaxy collection list 2>/dev/null | grep -q '^community\.general\s'; then
        log_info "Installing Ansible collection: community.general"
        ansible-galaxy collection install community.general >/dev/null 2>&1 || true
        add_done "Ansible collection community.general installed"
    else
        add_skipped "Ansible collection community.general already installed"
    fi
}

ensure_ssh_key() {
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        log_info "Installing OpenSSH client tools..."
        sudo apt update
        sudo apt install -y openssh-client
        add_done "OpenSSH client installed"
    else
        add_skipped "OpenSSH client already installed"
    fi

    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        log_info "Generating lab SSH key at $SSH_KEY_PATH..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
        add_done "Lab SSH key created (~/.ssh/id_rsa_lab)"
    else
        add_skipped "Lab SSH key already exists (~/.ssh/id_rsa_lab)"
    fi
}

initialize_tofu() {
    log_info "Running OpenTofu init..."
    tofu init -input=false >/dev/null 2>&1
    add_done "OpenTofu working directory initialized"
}

main() {
    ensure_sudo_session
    ensure_lxd
    ensure_opentofu
    ensure_ansible
    ensure_ssh_key
    initialize_tofu
    print_summary
    log_success "Host preparation completed. You can now run ./orchestrate.sh"
}

main "$@"