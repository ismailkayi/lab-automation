#!/bin/bash
# Runs inside the COS Lite demo VM. Safe to rerun: every step checks what
# already exists and only creates what is missing.
set -Eeuo pipefail

export PATH="$PATH:/snap/bin"

# shellcheck source=/dev/null
source /root/cos.env

# The host passes the versions from versions.env.
: "${COS_K8S_CHANNEL:?}" "${COS_JUJU_CHANNEL:?}" "${COS_OPENTOFU_CHANNEL:?}" \
    "${COS_LITE_REF:?}" "${COS_SCRAPE_TARGET_CHANNEL:?}"

COS_IP="${SUBNET_PREFIX}.200"
LB_ANNOTATIONS="metallb.io/loadBalancerIPs=${COS_IP},lbipam.cilium.io/ips=${COS_IP}"
# The host's LXD metrics endpoint, bound by the host to the bridge gateway.
LXD_METRICS_TARGET="${SUBNET_PREFIX}.1:8444"
CONTROLLER="lab-cos"
MODEL="${CONTROLLER}:cos"
TF_DIR="/root/cos-lite"
LXD_DASHBOARD_URL="https://grafana.com/api/dashboards/19131/revisions/5/download"
STEP=0

step() { STEP=$((STEP + 1)); echo; echo "==> [${STEP}/8] $*"; }
trap '(( BASH_SUBSHELL == 0 )) && echo "ERROR: step ${STEP} failed at line ${LINENO}. Fix the cause and rerun menu 11; completed steps are skipped." >&2' ERR

# Retries commands that depend on the network (snap store, charmhub, GitHub).
retry() {
    local attempt
    for attempt in 1 2 3 4 5; do
        "$@" && return 0
        echo "    attempt ${attempt}/5 failed: $*" >&2
        if [[ "$attempt" -lt 5 ]]; then sleep $((attempt * 20)); fi
    done
    return 1
}

wait_until() {
    local description="$1" seconds="$2"
    shift 2
    local deadline=$((SECONDS + seconds))
    until "$@" >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for ${description}" >&2
            return 1
        fi
        sleep 10
    done
}

install_snap() {
    local name="$1" channel="$2"
    shift 2
    if snap list "$name" >/dev/null 2>&1; then
        echo "    ${name} already installed"
    else
        retry snap install "$name" --channel="$channel" "$@"
    fi
}

step "Installing snaps"
cloud-init status --wait >/dev/null || true
snap wait system seed.loaded
install_snap k8s "$COS_K8S_CHANNEL" --classic
install_snap juju "$COS_JUJU_CHANNEL"
install_snap opentofu "$COS_OPENTOFU_CHANNEL" --classic
command -v git >/dev/null || retry apt-get install -y git

step "Bootstrapping Canonical Kubernetes"
if [[ ! -f /var/lib/cos-k8s-bootstrapped ]]; then
    k8s bootstrap --timeout 10m --file - <<EOF
pod-cidr: 100.64.0.0/16
service-cidr: 100.65.0.0/16
cluster-config:
  network:
    enabled: true
  dns:
    enabled: true
  local-storage:
    enabled: true
    default: true
  load-balancer:
    enabled: true
    l2-mode: true
    cidrs:
      - ${SUBNET_PREFIX}.200-${SUBNET_PREFIX}.209
EOF
    touch /var/lib/cos-k8s-bootstrapped
fi
k8s status --wait-ready --timeout 20m
wait_until "the default storage class" 600 bash -c "k8s kubectl get storageclass | grep -q '(default)'"
# MetalLB can fail first while its webhook starts; k8sd retries it and Traefik needs it.
wait_until "the load balancer" 900 bash -c "k8s status | grep -q '^load-balancer: *enabled'"

step "Bootstrapping Juju"
mkdir -p /root/.local/share
if ! juju show-cloud cos-k8s --client >/dev/null 2>&1; then
    k8s config | juju add-k8s cos-k8s --client
fi
if ! juju show-controller "$CONTROLLER" >/dev/null 2>&1; then
    juju bootstrap cos-k8s "$CONTROLLER"
fi
juju switch "$CONTROLLER" >/dev/null

step "Deploying COS Lite with OpenTofu (${COS_LITE_REF})"
mkdir -p "$TF_DIR"
cat > "${TF_DIR}/main.tf" <<EOF
terraform {
  required_providers {
    juju = {
      source = "juju/juju"
    }
  }
}

module "cos_lite" {
  source = "git::https://github.com/canonical/observability-stack//terraform/cos-lite?ref=${COS_LITE_REF}"
  model  = { name = "cos" }
  traefik = {
    config = {
      external_hostname        = "${COS_IP}"
      loadbalancer_annotations = "${LB_ANNOTATIONS}"
    }
  }
  grafana    = { storage_directives = { database = "1G" } }
  loki       = { storage_directives = { "active-index-directory" = "1G", "loki-chunks" = "5G" } }
  prometheus = { storage_directives = { database = "5G" } }
}
EOF
cd "$TF_DIR"
# No -upgrade: a rerun keeps the locked providers and the downloaded module.
retry tofu init -input=false
retry tofu apply -input=false -auto-approve

step "Adding the host's LXD as a Prometheus scrape target"
if ! juju show-application -m "$MODEL" lxd-host >/dev/null 2>&1; then
    retry juju deploy -m "$MODEL" prometheus-scrape-target-k8s lxd-host --channel "$COS_SCRAPE_TARGET_CHANNEL"
fi
juju config -m "$MODEL" lxd-host job_name=lxd targets="$LXD_METRICS_TARGET" scheme=https \
    metrics_path=/1.0/metrics tls_config_insecure_skip_verify=true
if ! output="$(juju integrate -m "$MODEL" lxd-host prometheus:metrics-endpoint 2>&1)"; then
    grep -qi 'already exists' <<< "$output" || { echo "$output" >&2; false; }
fi

step "Waiting for the applications to become active (can take 15-30 minutes)"
# A long-running "juju wait-for" can miss the final state, so poll juju status instead.
pending_apps() {
    juju status -m "$MODEL" --format json | python3 -c '
import json, sys
apps = json.load(sys.stdin).get("applications", {})
states = sorted((name, app["application-status"]["current"]) for name, app in apps.items())
print(" ".join("%s=%s" % item for item in states if item[1] != "active") if states else "no-applications")'
}
deadline=$((SECONDS + 2400))
last=""
while true; do
    pending="$(pending_apps)" || pending="juju-status-unavailable"
    [[ -z "$pending" ]] && break
    if [[ "$pending" != "$last" ]]; then
        echo "    not active yet: ${pending}"
        last="$pending"
    fi
    if (( SECONDS >= deadline )); then
        echo "Timed out; check 'juju status -m ${MODEL}' inside this VM." >&2
        false
    fi
    sleep 15
done
echo "    all applications are active"

step "Checking that Prometheus scrapes the host's LXD"
lxd_job() {
    curl -fsS --max-time 10 -G "http://${COS_IP}/cos-prometheus-0/api/v1/label/job/values" \
        --data-urlencode 'match[]=lxd_procs_total' \
        | python3 -c 'import json, sys; jobs = json.load(sys.stdin)["data"]; print(jobs[0]) if jobs else sys.exit(1)'
}
wait_until "LXD metrics from ${LXD_METRICS_TARGET} in Prometheus" 600 lxd_job
LXD_JOB="$(lxd_job)"
echo "    Prometheus job: ${LXD_JOB}"

step "Importing the LXD dashboard into Grafana"
GRAFANA_URL="http://${COS_IP}/cos-grafana"
# The action fails with "Grafana is not reachable yet" for a short time after Grafana becomes active.
grafana_password() {
    juju run -m "$MODEL" grafana/leader get-admin-password --format json 2>/dev/null \
        | python3 -c 'import json, sys; print(next(iter(json.load(sys.stdin).values()))["results"]["admin-password"])'
}
wait_until "Grafana at ${GRAFANA_URL}" 300 curl -fsS --max-time 10 "${GRAFANA_URL}/api/health"
wait_until "the Grafana admin password" 600 grafana_password
GRAFANA_PASSWORD="$(grafana_password)"
retry curl -fsSL --max-time 60 -o /root/lxd-dashboard.json "$LXD_DASHBOARD_URL"
DASHBOARD_PATH="$(GRAFANA_URL="$GRAFANA_URL" GRAFANA_PASSWORD="$GRAFANA_PASSWORD" python3 - /root/lxd-dashboard.json <<'PY'
import base64, json, os, sys, urllib.request

base = os.environ["GRAFANA_URL"]
token = base64.b64encode(f"admin:{os.environ['GRAFANA_PASSWORD']}".encode()).decode()

def call(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(base + path, data=data, headers={
        "Authorization": "Basic " + token, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)

uids = {}
for source in call("/api/datasources"):
    uids.setdefault(source["type"], source["uid"])
inputs = [
    {"name": "DS_PROMETHEUS", "type": "datasource", "pluginId": "prometheus", "value": uids["prometheus"]},
    {"name": "DS_LOKI", "type": "datasource", "pluginId": "loki", "value": uids["loki"]},
]
with open(sys.argv[1]) as handle:
    dashboard = json.load(handle)
result = call("/api/dashboards/import", {"dashboard": dashboard, "overwrite": True, "inputs": inputs})
print(result["importedUrl"])
PY
)"
wait_until "Loki at http://${COS_IP}/cos-loki-0/ready" 300 curl -fsS --max-time 10 "http://${COS_IP}/cos-loki-0/ready"

(
    umask 077
    printf 'COS_IP=%q\nGRAFANA_PASSWORD=%q\nLXD_JOB=%q\nDASHBOARD_PATH=%q\n' \
        "$COS_IP" "$GRAFANA_PASSWORD" "$LXD_JOB" "$DASHBOARD_PATH" > /root/cos-access.env
)
echo
echo "COS Lite is ready: http://${COS_IP}/cos-catalogue"
