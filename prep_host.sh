#!/bin/bash

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER=""
TARGET_GROUP=""
TARGET_HOME=""
SSH_KEY_PATH=""
APT_UPDATED=false
LXD_GROUP_REFRESH_REQUIRED=false

DONE_ITEMS=()
SKIPPED_ITEMS=()
WARN_ITEMS=()

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

add_done() { DONE_ITEMS+=("$1"); }
add_skipped() { SKIPPED_ITEMS+=("$1"); }
add_warn() { WARN_ITEMS+=("$1"); }

detect_target_user() {
    if (( EUID == 0 )); then
        if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
            log_warn "Run this script as the non-root user who will operate the labs."
            log_warn "The script will request sudo access when required."
            exit 1
        fi
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER="$(id -un)"
    fi

    TARGET_GROUP="$(id -gn "$TARGET_USER")"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
    if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
        log_warn "Could not resolve a valid home directory for ${TARGET_USER}."
        exit 1
    fi

    SSH_KEY_PATH="${TARGET_HOME}/.ssh/id_rsa_lab"
}

run_as_target() {
    if [[ "$(id -un)" == "$TARGET_USER" ]]; then
        "$@"
    else
        sudo -H -u "$TARGET_USER" env "PATH=$PATH" "$@"
    fi
}

run_as_target_with_fresh_groups() {
    sudo -H -u "$TARGET_USER" env "PATH=$PATH" "$@"
}

ensure_apt_updated() {
    if [[ "$APT_UPDATED" == false ]]; then
        sudo apt update
        APT_UPDATED=true
    fi
}

print_summary() {
    print_section "Host Preparation Summary"

    if [[ ${#DONE_ITEMS[@]} -gt 0 ]]; then
        echo "DONE:"
        for item in "${DONE_ITEMS[@]}"; do
            echo "  - ${item}"
        done
        echo ""
    fi

    if [[ ${#SKIPPED_ITEMS[@]} -gt 0 ]]; then
        echo "SKIPPED:"
        for item in "${SKIPPED_ITEMS[@]}"; do
            echo "  - ${item}"
        done
        echo ""
    fi

    if [[ ${#WARN_ITEMS[@]} -gt 0 ]]; then
        echo "NOTES:"
        for item in "${WARN_ITEMS[@]}"; do
            echo "  - ${item}"
        done
        echo ""
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
    local target_groups=""

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

    storage_count=$(sudo lxc storage list --format csv | awk -F',' 'NF>0 {count++} END {print count+0}')

    if [[ "$storage_count" -eq 0 ]]; then
        log_info "Initializing LXD with default settings..."
        sudo lxd init --auto
        add_done "LXD initialized (bridge network and storage pool prepared)"
    else
        add_skipped "LXD storage already initialized"
    fi

    while IFS= read -r net_name; do
        [[ -z "$net_name" ]] && continue

        net_type=$(sudo lxc network show "$net_name" 2>/dev/null | awk -F': ' '$1=="type" {print $2; exit}')
        [[ "$net_type" != "bridge" ]] && continue

        net_ipv4=$(sudo lxc network get "$net_name" ipv4.address 2>/dev/null || true)
        if [[ -n "$net_ipv4" && "$net_ipv4" != "none" ]]; then
            routable_bridge_count=$((routable_bridge_count + 1))
        fi
    done < <(sudo lxc network list --format csv | awk -F',' 'NF>0 {print $1}')

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

    target_groups="$(id -nG "$TARGET_USER")"
    if [[ " $target_groups " != *" lxd "* ]]; then
        log_info "Adding ${TARGET_USER} to the lxd group..."
        sudo usermod -aG lxd "$TARGET_USER"
        LXD_GROUP_REFRESH_REQUIRED=true
        add_done "User added to lxd group"
    else
        add_skipped "User already in lxd group"
    fi

    if [[ "$(id -un)" == "$TARGET_USER" && " $(id -nG) " != *" lxd "* ]]; then
        LXD_GROUP_REFRESH_REQUIRED=true
    fi

    log_info "Validating LXD access as ${TARGET_USER}..."
    if ! run_as_target_with_fresh_groups lxc info >/dev/null; then
        log_warn "LXD is still not reachable as ${TARGET_USER} after group configuration."
        exit 1
    fi
    run_as_target_with_fresh_groups lxc storage list --format csv >/dev/null
    run_as_target_with_fresh_groups lxc network list --format csv >/dev/null
    add_done "LXD access validated for ${TARGET_USER}"

    if [[ "$LXD_GROUP_REFRESH_REQUIRED" == true ]]; then
        add_warn "Open a new login session or run 'newgrp lxd' before ./orchestrate.sh"
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
        ensure_apt_updated
        sudo apt install -y ansible
        add_done "Ansible installed"
    else
        add_skipped "Ansible already installed"
    fi

    if ! run_as_target ansible-galaxy collection list 2>/dev/null | grep -q '^community\.general\s'; then
        log_info "Installing Ansible collection: community.general"
        run_as_target ansible-galaxy collection install community.general
        add_done "Ansible collection community.general installed"
    else
        add_skipped "Ansible collection community.general already installed"
    fi
}

ensure_ssh_key() {
    local public_key=""

    if ! command -v ssh-keygen >/dev/null 2>&1; then
        log_info "Installing OpenSSH client tools..."
        ensure_apt_updated
        sudo apt install -y openssh-client
        add_done "OpenSSH client installed"
    else
        add_skipped "OpenSSH client already installed"
    fi

    sudo install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_GROUP" "${TARGET_HOME}/.ssh"

    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        log_info "Generating lab SSH key at $SSH_KEY_PATH..."
        run_as_target ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
        add_done "Lab SSH key created (${SSH_KEY_PATH})"
    else
        add_skipped "Lab SSH key already exists (${SSH_KEY_PATH})"
    fi

    if [[ ! -s "${SSH_KEY_PATH}.pub" ]]; then
        log_info "Rebuilding missing public key from ${SSH_KEY_PATH}..."
        public_key="$(run_as_target ssh-keygen -y -f "$SSH_KEY_PATH")"
        printf '%s\n' "$public_key" | sudo tee "${SSH_KEY_PATH}.pub" >/dev/null
        add_done "Lab SSH public key rebuilt"
    fi

    sudo chown "$TARGET_USER:$TARGET_GROUP" "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub"
    sudo chmod 0600 "$SSH_KEY_PATH"
    sudo chmod 0644 "${SSH_KEY_PATH}.pub"
}

repair_generated_artifact_ownership() {
    local artifact=""
    local -a artifacts=(
        "${SCRIPT_DIR}/.terraform"
        "${SCRIPT_DIR}/.terraform.lock.hcl"
        "${SCRIPT_DIR}/terraform.tfstate"
        "${SCRIPT_DIR}/terraform.tfstate.backup"
        "${SCRIPT_DIR}/terraform.tfstate.d"
        "${SCRIPT_DIR}/.terraform.tfstate.lock.info"
    )

    shopt -s nullglob
    artifacts+=("${SCRIPT_DIR}"/inventory_*.yaml)
    shopt -u nullglob

    for artifact in "${artifacts[@]}"; do
        [[ -e "$artifact" ]] || continue
        if find "$artifact" ! -user "$TARGET_USER" -print -quit | grep -q .; then
            log_info "Repairing ownership of generated artifact: ${artifact}"
            sudo chown -R "$TARGET_USER:$TARGET_GROUP" "$artifact"
            add_done "Ownership repaired for ${artifact}"
        fi
    done
}

initialize_tofu() {
    log_info "Running OpenTofu init..."
    (
        cd "$SCRIPT_DIR"
        run_as_target tofu init -input=false
    )
    add_done "OpenTofu working directory initialized"
}

main() {
    detect_target_user
    ensure_sudo_session
    ensure_lxd
    ensure_opentofu
    ensure_ansible
    ensure_ssh_key
    repair_generated_artifact_ownership
    initialize_tofu
    print_summary

    if [[ "$LXD_GROUP_REFRESH_REQUIRED" == true ]]; then
        log_warn "Host preparation is complete, but this shell has stale group membership."
        log_warn "Run 'newgrp lxd' or open a new login session, then run ./orchestrate.sh."
    else
        log_success "Host preparation completed. You can now run ./orchestrate.sh"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi