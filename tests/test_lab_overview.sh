#!/bin/bash
# Variables set here are read by the sourced overview functions.
# shellcheck disable=SC2034
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../orchestrate.sh
source "${REPO_ROOT}/orchestrate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "Expected '$2' in '$1'"; }

LAB_OVERVIEW_DIR="$TMP/overview"
CM_STATE_DIR="$TMP/cm"
LANDSCAPE_SETTINGS="$TMP/landscape.env"
COS_ACCESS="$TMP/cos.env"
MAAS_SETTINGS="$TMP/maas-settings.env"
MAAS_ACCESS="$TMP/maas.env"
mkdir -p "$CM_STATE_DIR"

lxc() {
    case "$*" in
        "list --format json") cat "$TMP/nodes.json" ;;
        "--project default list local:lab-cluster-manager --format csv -c s")
            echo RUNNING ;;
        *) fail "Unexpected LXD call: $*" ;;
    esac
}
tofu() {
    [[ "$*" == "workspace list" ]] || fail "Unexpected OpenTofu call: $*"
    printf '  default\n  group10_training-microcloud\n  snap_k8s-snap\n'
    printf '* group2_training-microcloud\n  juju_training-k8s-juju\n'
    printf '  group1_training-microcloud\n  unsupported_workspace\n'
}
cos_lxc() { echo RUNNING; }
maas_lxc() { echo RUNNING; }
landscape_status() { echo RUNNING; }
landscape_ip() { echo 10.1.1.2; }
landscape_instances() { printf 'lab-landscape\nlab-landscape-client-2404\n'; }
get_microcloud_uplink_cidr() {
    case "$1" in
        group1_*) echo 172.30.1.0/24 ;;
        group2_*) echo 172.30.2.0/24 ;;
        group10_*) echo "" ;;
        *) fail "Uplink lookup for a non-MicroCloud lab: $1" ;;
    esac
}

cat > "$CM_STATE_DIR/participant-access.csv" <<'EOF'
username,password,cm_url,keycloak_url
group1,test1,https://172.31.0.220,http://172.31.0.210:8080
group2,test2,https://172.31.0.220,http://172.31.0.210:8080
EOF
cat > "$CM_STATE_DIR/settings.env" <<'EOF'
SUBNET_PREFIX=172.31.0
PARTICIPANT_PREFIX=group
PARTICIPANT_COUNT=2
INSTRUCTOR_PASSWORD=InstructorTest123
KEYCLOAK_ADMIN_PASSWORD=KeycloakTest123
OIDC_CLIENT_SECRET=OidcSecretMustStayHidden
EOF
cat > "$LANDSCAPE_SETTINGS" <<'EOF'
ADMIN_EMAIL=instructor@example.test
ADMIN_PASSWORD=LandscapeTest123
EOF
cat > "$COS_ACCESS" <<'EOF'
COS_IP=172.31.7.200
GRAFANA_PASSWORD=GrafanaTest123
DASHBOARD_PATH=/cos-grafana/d/lxd/lxd
EOF
cat > "$MAAS_SETTINGS" <<'EOF'
ADMIN_PASSWORD=MaasTest123
EOF
cat > "$MAAS_ACCESS" <<'EOF'
MAAS_IP=172.31.9.5
MAAS_VERSION=3.8.0
EOF
cat > "$TMP/nodes.json" <<'EOF'
[
  {"name": "group1-training-microcloud-node-10", "status": "STOPPED", "state": null},
  {"name": "group1-training-microcloud-node-2", "status": "RUNNING",
   "state": {"network": {
     "enp6s0": {"addresses": [{"family": "inet", "scope": "global", "address": "172.30.1.2"}]},
     "enp5s0": {"addresses": [{"family": "inet", "scope": "global", "address": "10.0.0.2"}]}
   }}},
  {"name": "group2-training-microcloud-node-1", "status": "RUNNING",
   "state": {"network": {
     "eth0": {"addresses": [
       {"family": "inet6", "scope": "global", "address": "2001:db8::3"},
       {"family": "inet", "scope": "global", "address": "10.0.0.3"}
     ]}
   }}},
  {"name": "snap-k8s-snap-cp-1", "status": "RUNNING",
   "state": {"network": {"enp5s0": {"addresses": [
     {"family": "inet", "scope": "global", "address": "10.0.0.4"}
   ]}}}},
  {"name": "lab-unrelated", "status": "RUNNING", "state": null}
]
EOF

lab_overview > "$TMP/output"
output="$(cat "$TMP/output")"
for text in "Instructor services" "Participant labs (5)" "Export" \
    "group1 | MicroCloud training" "group10 | MicroCloud training" \
    "snap | K8s Snap" "juju | K8s Juju training" "no nodes found" \
    "OVN uplink (microcloud init)" "Network forwards (after init)" \
    "DR partner         instructor" "UPLINK ipv4.routes 172.30.1.224/27" \
    "https://172.31.0.220" "Username           instructor" \
    "Password           InstructorTest123" \
    "Keycloak           http://172.31.0.210:8080/admin/" \
    "Keycloak user      lab-admin" "Keycloak password  KeycloakTest123" \
    "Accounts           2 participant accounts" "Participant logins menu 7 > Show access" \
    "https://10.1.1.2/" "Password           LandscapeTest123" \
    "http://172.31.7.200/cos-grafana" "Password           GrafanaTest123" \
    "http://172.31.9.5:5240/MAAS" "Password           MaasTest123"; do
    assert_contains "$output" "$text"
done
[[ "$output" != *"OidcSecretMustStayHidden"* ]] || fail "The overview must not print the OIDC client secret"

python3 - "$TMP/output" "$LAB_OVERVIEW_DIR/all-labs.csv" <<'PY'
import csv
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
assert "\x1b" not in text, "Redirected overview must be plain text"
assert text.index("Instructor services") < text.index("Participant labs (5)") < text.index("\nExport\n")
assert text.index("group1 |") < text.index("group2 |") < text.index("group10 |"), "Natural lab order"
assert text.index("node-2") < text.index("node-10"), "Natural node order"
assert re.search(r"NODE\s+STATE\s+MANAGEMENT IP", text)
assert re.search(r"node-2\s+RUNNING\s+10\.0\.0\.2", text), "Prefer management NIC"
assert re.search(r"node-10\s+STOPPED\s+-", text), "Keep nodes with no address"
assert "lab-unrelated" not in text
for line in text.splitlines():
    if "CSV (all labs)" not in line:  # The user's state-directory path may be long.
        assert len(line) <= 80, f"Unexpectedly wide overview line: {line!r}"

csv_path = pathlib.Path(sys.argv[2])
with csv_path.open() as stream:
    rows = list(csv.reader(stream))
assert rows == [
    ["type", "lab", "dr_partner", "node_ips", "uplink_gateway", "uplink_first",
     "uplink_last", "uplink_dns", "forward_routes"],
    ["MicroCloud training", "group1", "group2", "10.0.0.2 -", "172.30.1.1/24",
     "172.30.1.100", "172.30.1.200", "8.8.8.8", "172.30.1.224/27"],
    ["MicroCloud training", "group2", "group1", "10.0.0.3", "172.30.2.1/24",
     "172.30.2.100", "172.30.2.200", "8.8.8.8", "172.30.2.224/27"],
    ["MicroCloud training", "group10", "instructor", "", "", "", "", "", ""],
    ["K8s Juju training", "juju", "", "", "", "", "", "", ""],
    ["K8s Snap", "snap", "", "10.0.0.4", "", "", "", "", ""],
], "CSV schema, values, ordering and DR pairing must remain unchanged"
assert csv_path.stat().st_mode & 0o777 == 0o600
assert csv_path.parent.stat().st_mode & 0o777 == 0o700
PY

# A fully deployed MicroCloud is shown too, but never enters training DR pairs.
(
    lab_overview_list_labs() { echo "full full_microcloud microcloud full"; }
    lab_overview_nodes() { echo "node-1|RUNNING|10.0.0.5"; }
    get_microcloud_uplink_cidr() { echo 172.30.3.0/24; }
    output="$(lab_overview)"
    assert_contains "$output" "full | MicroCloud"
    [[ "$output" != *"DR partner"* ]] || fail "Full deployments must not get a training partner"
    grep -qx '"MicroCloud","full","","10.0.0.5","172.30.3.1/24","172.30.3.100","172.30.3.200","8.8.8.8","172.30.3.224/27"' \
        "$LAB_OVERVIEW_DIR/all-labs.csv" || fail "Full MicroCloud CSV changed"
)

# Access values are literal, not printf escape sequences, and never truncated.
(
    value='a-literal-password-with-\n-and-\t'
    output="$(lab_overview_field Password "$value")"
    [[ "$output" == "    Password           $value" ]] || fail "Access values must be printed literally"
)

# Empty host: no stale rows or invented addresses, but keep setup menu hints.
(
    tofu() { echo default; }
    lxc() { :; }
    landscape_status() { :; }
    cos_lxc() { :; }
    maas_lxc() { :; }
    CM_STATE_DIR="$TMP/missing-cm"
    COS_ACCESS="$TMP/missing-cos.env"
    MAAS_ACCESS="$TMP/missing-maas.env"
    output="$(lab_overview)"
    for text in "Participant labs (0)" "No participant labs found." \
        "not installed (menu 7)" "not installed (menu 10)" "not installed (menu 11)" \
        "not installed (menu 12)"; do
        assert_contains "$output" "$text"
    done
    [[ "$(wc -l < "$LAB_OVERVIEW_DIR/all-labs.csv")" == 1 ]] || fail "Empty CSV must have only the header"
)

# A stopped or unfinished service must not be presented as healthy.
(
    lxc() { echo STOPPED; }
    CM_STATE_DIR="$TMP/missing-cm"
    output="$(lab_overview_cluster_manager)"
    assert_contains "$output" "VM state           STOPPED"
    assert_contains "$output" "installation not finished"
    assert_contains "$output" "menu 7 > Install / resume"
)
# Without the generated settings the logins are unknown, so the installation is offered again.
(
    mkdir -p "$TMP/cm-no-settings"
    cp "$CM_STATE_DIR/participant-access.csv" "$TMP/cm-no-settings/"
    CM_STATE_DIR="$TMP/cm-no-settings"
    output="$(lab_overview_cluster_manager)"
    assert_contains "$output" "installation not finished"
    [[ "$output" != *"Password"* ]] || fail "No login may be shown without the settings file"
)
(
    landscape_status() { echo STOPPED; }
    landscape_ip() { fail "Do not query a stopped server's IP"; }
    output="$(lab_overview_landscape)"
    assert_contains "$output" "VM state           STOPPED"
    [[ "$output" != *"Web UI"* ]] || fail "Stopped Landscape must not advertise a current IP"
)
(
    landscape_status() { echo "Landscape status query failed" >&2; return 1; }
    if lab_overview_landscape > "$TMP/failure" 2>&1; then
        fail "A Landscape lookup error must propagate"
    fi
    assert_contains "$(cat "$TMP/failure")" "Landscape status query failed"
)
(
    maas_lxc() { echo STOPPED; }
    MAAS_ACCESS="$TMP/missing-maas.env"
    output="$(lab_overview_maas)"
    assert_contains "$output" "VM state           STOPPED"
    assert_contains "$output" "installation not finished"
    assert_contains "$output" "rerun menu 12"
    [[ "$output" != *"Password"* ]] || fail "An unfinished MAAS must not show credentials"
)

echo "PASS: overview sections, readable node tables, service states, DR pairs and unchanged private CSV"
