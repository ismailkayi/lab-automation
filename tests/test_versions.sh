#!/bin/bash
# Variables set here are read by the sourced functions.
# shellcheck disable=SC2034
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../orchestrate.sh
source "${REPO_ROOT}/orchestrate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "Expected '$2' in '$1'"; }
lxc() { fail "Unexpected real LXD call: $*"; }

# The real file was loaded when orchestrate.sh was sourced.
real_keys=("${VERSION_KEYS[@]}")
(( ${#real_keys[@]} > 0 )) || fail "versions.env defines no versions"
for key in "${real_keys[@]}"; do
    [[ -n "$(printenv "$key")" ]] || fail "${key} must be exported with a value"
done
(( ${#VERSION_EXTRA_VARS[@]} == 2 * ${#real_keys[@]} )) || fail "Every key must reach Ansible as a variable"
[[ "$(printenv TF_VAR_ubuntu_image)" == "$UBUNTU_IMAGE" ]] || fail "OpenTofu must receive UBUNTU_IMAGE"
if sed -n '/^variable "ubuntu_image"/,/^}/p' "${REPO_ROOT}/main.tf" | grep -q default; then
    fail "main.tf must not carry its own image default"
fi
[[ "${K8S_CHARM_BASE#ubuntu@}" == "${UBUNTU_IMAGE#ubuntu:}" ]] ||
    fail "K8S_CHARM_BASE must match the Ubuntu release of UBUNTU_IMAGE"

# Comments, blank lines and a missing final newline are accepted.
printf '%s\n' '# comment' '' '   # indented comment' '   ' 'T_ONE_CHANNEL=1.2/stable' 'T_ONE_IMAGE=ubuntu:24.04' > "$TMP/ok.env"
printf 'T_TWO_LIST=a,b,c' >> "$TMP/ok.env"
(
    load_versions "$TMP/ok.env"
    [[ "${VERSION_KEYS[*]}" == "T_ONE_CHANNEL T_ONE_IMAGE T_TWO_LIST" ]] || fail "Keys must keep the file order"
    [[ "$T_ONE_CHANNEL" == "1.2/stable" && "$T_TWO_LIST" == "a,b,c" ]] || fail "Values must be set"
    [[ "$(printenv T_ONE_IMAGE)" == "ubuntu:24.04" ]] || fail "Values must be exported"
    [[ "${VERSION_EXTRA_VARS[*]}" == "-e t_one_channel=1.2/stable -e t_one_image=ubuntu:24.04 -e t_two_list=a,b,c" ]] ||
        fail "Ansible must get lowercase variables: ${VERSION_EXTRA_VARS[*]}"
    args=()
    version_env_args args T_ONE_
    [[ "${args[*]}" == "--env T_ONE_CHANNEL=1.2/stable --env T_ONE_IMAGE=ubuntu:24.04" ]] ||
        fail "A guest must get only the keys with its prefix: ${args[*]}"
    version_env_args args T_NONE_
    (( ${#args[@]} == 0 )) || fail "A prefix without keys must give no arguments"
)

# A variable exported in the shell wins over the file; an empty one is ignored.
(
    export T_ONE_CHANNEL=9.9/edge
    load_versions "$TMP/ok.env"
    [[ "$T_ONE_CHANNEL" == "9.9/edge" ]] || fail "An exported variable must win over the file"
    assert_contains "${VERSION_EXTRA_VARS[*]}" "-e t_one_channel=9.9/edge "
    args=()
    version_env_args args T_ONE_
    [[ "${args[*]}" == "--env T_ONE_CHANNEL=9.9/edge --env T_ONE_IMAGE=ubuntu:24.04" ]] ||
        fail "The override must reach the guest: ${args[*]}"
    export T_ONE_CHANNEL=""
    load_versions "$TMP/ok.env"
    [[ "$T_ONE_CHANNEL" == "1.2/stable" ]] || fail "An empty exported variable must be ignored"
)
(
    export T_ONE_CHANNEL='9.9/edge; id'
    if output="$(load_versions "$TMP/ok.env" 2>&1)"; then
        fail "An unsupported override must be refused"
    fi
    assert_contains "$output" "T_ONE_CHANNEL"
)

# Anything that is not a plain KEY=value line is refused with its line number.
bad_lines=(
    'T_X = 1'
    'T_X= 1'
    'T_X="1"'
    "T_X='1'"
    't_x=1'
    'T_X='
    'T_X=1 2'
    'T_X=a;b'
    'T_X=$(id)'
    'T_X=a=b'
    'export T_X=1'
    'T_X'
    $'T_X=1\r'
)
for bad in "${bad_lines[@]}"; do
    printf '# header\n%s\n' "$bad" > "$TMP/bad.env"
    if output="$(load_versions "$TMP/bad.env" 2>&1)"; then
        fail "'${bad}' must be refused"
    fi
    assert_contains "$output" "bad.env:2:"
done
printf 'T_X=1\nT_X=2\n' > "$TMP/dup.env"
if output="$(load_versions "$TMP/dup.env" 2>&1)"; then
    fail "A duplicate key must be refused"
fi
assert_contains "$output" "dup.env:2:"
assert_contains "$output" "defined twice"
if output="$(load_versions "$TMP/missing.env" 2>&1)"; then
    fail "A missing file must be refused"
fi
assert_contains "$output" "Cannot read"

# The orchestrator stops before doing anything when versions.env is broken or missing.
mkdir "$TMP/copy"
cp "${REPO_ROOT}/orchestrate.sh" "$TMP/copy/"
printf 'MAAS_CHANNEL = 3.8/stable\n' > "$TMP/copy/versions.env"
if output="$(TERM=xterm bash "$TMP/copy/orchestrate.sh" < /dev/null 2>&1)"; then
    fail "A broken versions.env must stop the orchestrator"
fi
assert_contains "$output" "versions.env:1:"
rm "$TMP/copy/versions.env"
if output="$(TERM=xterm bash "$TMP/copy/orchestrate.sh" < /dev/null 2>&1)"; then
    fail "A missing versions.env must stop the orchestrator"
fi
assert_contains "$output" "Cannot read"

# Every playbook call gets the versions as extra variables, and the playbooks only use defined ones.
playbook_calls="$(grep -E '^[[:space:]]*ansible-playbook ' "${REPO_ROOT}/orchestrate.sh")"
[[ -n "$playbook_calls" ]] || fail "orchestrate.sh must run the playbooks"
while IFS= read -r line; do
    [[ "$line" == *'"${VERSION_EXTRA_VARS[@]}"'* ]] || fail "ansible-playbook must receive the versions: ${line}"
done <<< "$playbook_calls"
mapfile -t playbook_vars < <(grep -ohE '\{\{ *[a-z0-9_]+_channel *\}\}' "${REPO_ROOT}"/playbooks/*.yml | tr -d '{} ' | sort -u)
(( ${#playbook_vars[@]} > 0 )) || fail "The playbooks must take their channels from versions.env"
for var in "${playbook_vars[@]}"; do
    [[ " ${real_keys[*]} " == *" ${var^^} "* ]] || fail "The playbooks use ${var}, which versions.env does not define"
done

# A guest requires every version it uses, and only versions that versions.env defines.
for guest in "${REPO_ROOT}"/scripts/*_guest.sh; do
    name="$(basename "$guest")"
    mapfile -t guarded < <(grep -oE '\$\{[A-Z][A-Z0-9_]*:\?' "$guest" | sed -E 's/^\$\{//; s/:\?$//' | sort -u)
    for key in "${guarded[@]}"; do
        case "$key" in
            SERVER_IP | MAAS_IP) continue ;;
        esac
        [[ " ${real_keys[*]} " == *" ${key} "* ]] || fail "${name} requires ${key}, which versions.env does not define"
    done
    for key in "${real_keys[@]}"; do
        if grep -qE "\\\$\\{?${key}([^A-Za-z0-9_]|\$)" "$guest" && ! grep -qF "\${${key}:?" "$guest"; then
            fail "${name} uses ${key} without requiring it up front"
        fi
    done
done

# Every key is used somewhere, and no script keeps its own copy of a value.
for key in "${real_keys[@]}"; do
    if ! grep -qw -- "$key" "${REPO_ROOT}/orchestrate.sh" "${REPO_ROOT}"/scripts/*.sh &&
        ! grep -qw -- "${key,,}" "${REPO_ROOT}"/playbooks/*.yml; then
        fail "${key} is defined in versions.env but nothing uses it"
    fi
    if grep -nE "(^|[[:space:];])${key}=|\\\$\\{${key}:-" "${REPO_ROOT}/orchestrate.sh" "${REPO_ROOT}"/scripts/*.sh; then
        fail "${key} must only be set in versions.env"
    fi
done
code=("${REPO_ROOT}/orchestrate.sh" "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/playbooks/*.yml "${REPO_ROOT}/main.tf")
if grep -nE '(^|[^A-Za-z0-9_.-])[A-Za-z0-9.-]+/(stable|candidate|beta|edge)\b|ubuntu:[0-9]' "${code[@]}" |
    grep -vE ':[0-9]+:[[:space:]]*#'; then
    fail "Channels and images belong in versions.env, not in the scripts"
fi

# Cluster Manager has no test file of its own, so its version handling is checked here.
(
    CM_STATE_DIR="$TMP/cm"
    CM_SETTINGS="$CM_STATE_DIR/settings.env"
    mkdir -p "$CM_STATE_DIR"
    printf 'SUBNET_PREFIX=172.31.7\n' > "$CM_SETTINGS"
    CM_VM_IMAGE=ubuntu:test-image
    awk() { echo 64; }
    sleep() { :; }
    : > "$TMP/calls"
    cm_lxc() {
        echo "$*" >> "$TMP/calls"
        case "$1 $2" in
            "network show" | "info local:lab-cluster-manager") return 1 ;;
        esac
    }
    cm_ensure_infrastructure > /dev/null
    assert_contains "$(cat "$TMP/calls")" "launch ubuntu:test-image local:lab-cluster-manager --vm --network lab-cmbr0"
)
(
    CM_STATE_DIR="$TMP/cm"
    CM_TRAEFIK_CHANNEL=9.9/test
    cm_prepare_settings() { :; }
    cm_ensure_infrastructure() { :; }
    cm_write_access_files() { :; }
    cm_show_access() { :; }
    : > "$TMP/calls"
    cm_lxc() { [[ "$1" != exec ]] || echo "$*" >> "$TMP/calls"; }
    cm_install > /dev/null
    calls="$(cat "$TMP/calls")"
    assert_contains "$calls" "exec local:lab-cluster-manager --env CM_"
    assert_contains "$calls" "--env CM_TRAEFIK_CHANNEL=9.9/test"
    assert_contains "$calls" "-- bash /root/cluster-manager-setup.sh"
    for other in LANDSCAPE_ COS_ MAAS_ LXD_CHANNEL K8S_ JUJU_ UBUNTU_IMAGE; do
        [[ "$calls" != *"--env ${other}"* ]] || fail "The Cluster Manager VM must not receive ${other}* versions"
    done
)

echo "PASS: versions.env loading, overrides, refused input, startup failure, per-product hand-over, Ansible variables and no hard-coded versions"
