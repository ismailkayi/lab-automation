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
    local routable_bridge_count="0"
    local storage_count="0"
    local net_name=""
    local net_type=""
    local net_ipv4=""

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

    while IFS= read -r net_name; do
        [[ -z "$net_name" ]] && continue

        net_type=$(sudo lxc network show "$net_name" 2>/dev/null | awk -F': ' '$1=="type" {print $2; exit}')
        [[ "$net_type" != "bridge" ]] && continue

        net_ipv4=$(sudo lxc network get "$net_name" ipv4.address 2>/dev/null || true)
        if [[ -n "$net_ipv4" && "$net_ipv4" != "none" ]]; then
            routable_bridge_count=$((routable_bridge_count + 1))
        fi
    done < <(sudo lxc network list --format csv | awk -F',' 'NF>0 {print $1}')

    storage_count=$(sudo lxc storage list --format csv | awk -F',' 'NF>0 {count++} END {print count+0}')

    if [[ "$storage_count" -eq 0 ]]; then
        log_info "Initializing LXD with default settings..."
        sudo lxd init --auto
        add_done "LXD initialized (bridge network and storage pool prepared)"
    else
        add_skipped "LXD storage already initialized"
    fi

    if [[ "$routable_bridge_count" -eq 0 ]]; then
        if ! sudo lxc network show labbr0 >/dev/null 2>&1; then
            log_info "Creating fallback LXD bridge network: labbr0"
            sudo lxc network create labbr0 ipv4.address=auto ipv6.address=none
            add_done "Fallback LXD bridge labbr0 created"
        else
            add_skipped "Fallback LXD bridge labbr0 already exists"
        fi
    else
        add_skipped "Usable LXD bridge network already exists"
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