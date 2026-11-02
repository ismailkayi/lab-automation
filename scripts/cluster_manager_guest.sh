#!/bin/bash
# Runs inside the Cluster Manager service VM. Safe to rerun: every step checks
# what already exists and only creates what is missing.
set -Eeuo pipefail

export PATH="$PATH:/snap/bin"

# shellcheck source=/dev/null
source /root/cluster-manager.env

REALM="microcloud-training"
CLIENT_ID="cluster-manager"
MODEL="lab-cm:cluster-manager"
CM_APP="microcloud-cluster-manager-k8s"
MANAGER_IP="${SUBNET_PREFIX}.220"
KEYCLOAK_IP="${SUBNET_PREFIX}.210"
KEYCLOAK_URL="http://${KEYCLOAK_IP}:8080"
LB_ANNOTATIONS="metallb.io/loadBalancerIPs=${MANAGER_IP},lbipam.cilium.io/ips=${MANAGER_IP}"
STEP=0

step() { STEP=$((STEP + 1)); echo; echo "==> [${STEP}/8] $*"; }
trap 'echo "ERROR: step ${STEP} failed at line ${LINENO}. Fix the cause and rerun the installation; completed steps are skipped." >&2' ERR

# Retries commands that depend on the network (snap store, charmhub, images).
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

kubectl() { k8s kubectl "$@"; }

step "Installing snaps"
cloud-init status --wait >/dev/null || true
snap wait system seed.loaded
install_snap k8s 1.35-classic/stable --classic
install_snap juju 3.6/stable

step "Bootstrapping Canonical Kubernetes"
if [[ ! -f /var/lib/cluster-manager-k8s-bootstrapped ]]; then
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
      - ${SUBNET_PREFIX}.200-${SUBNET_PREFIX}.220
EOF
    touch /var/lib/cluster-manager-k8s-bootstrapped
fi
k8s status --wait-ready --timeout 20m
wait_until "the default storage class" 600 bash -c "k8s kubectl get storageclass | grep -q '(default)'"

step "Deploying Keycloak"
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl -n keycloak create secret generic keycloak-admin \
    --from-literal=username=lab-admin --from-literal=password="$KEYCLOAK_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: keycloak-data, namespace: keycloak}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 5Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: keycloak, namespace: keycloak}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: keycloak}}
  template:
    metadata: {labels: {app: keycloak}}
    spec:
      securityContext: {fsGroup: 1000}
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.8.1
          args: [start-dev]
          env:
            - {name: KC_HOSTNAME, value: "${KEYCLOAK_URL}"}
            - {name: KC_HTTP_ENABLED, value: "true"}
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              valueFrom: {secretKeyRef: {name: keycloak-admin, key: username}}
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: keycloak-admin, key: password}}
          ports: [{containerPort: 8080}]
          readinessProbe:
            httpGet: {path: /realms/master, port: 8080}
            periodSeconds: 10
          volumeMounts: [{name: data, mountPath: /opt/keycloak/data}]
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: keycloak-data}
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
  annotations:
    metallb.io/loadBalancerIPs: "${KEYCLOAK_IP}"
    lbipam.cilium.io/ips: "${KEYCLOAK_IP}"
spec:
  type: LoadBalancer
  selector: {app: keycloak}
  ports: [{port: 8080, targetPort: 8080}]
EOF
kubectl -n keycloak rollout status deployment/keycloak --timeout=20m
wait_until "Keycloak at ${KEYCLOAK_URL}" 600 curl -fsS "${KEYCLOAK_URL}/realms/master"

step "Configuring Keycloak realm, client and users"
kc() { kubectl -n keycloak exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
kc_id() { kc get "$1" -r "$REALM" "${@:2}" --fields id --format csv --noquotes | head -n 1; }

kc config credentials --server http://localhost:8080 --realm master \
    --user lab-admin --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null
if ! kc get "realms/${REALM}" >/dev/null 2>&1; then
    kc create realms -s realm="$REALM" -s enabled=true -s sslRequired=none
fi

client_uuid="$(kc_id clients -q clientId="$CLIENT_ID")"
if [[ -z "$client_uuid" ]]; then
    client_uuid="$(kc create clients -r "$REALM" -i \
        -s clientId="$CLIENT_ID" -s enabled=true -s publicClient=false \
        -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
        -s secret="$OIDC_CLIENT_SECRET" \
        -s "redirectUris=[\"https://${MANAGER_IP}/oidc/callback\"]" \
        -s "webOrigins=[\"https://${MANAGER_IP}\"]")"
    kc create "clients/${client_uuid}/protocol-mappers/models" -r "$REALM" \
        -s name=mcm-groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
        -s 'config."full.path"=false' -s 'config."claim.name"=mcm-idp-groups' \
        -s 'config."id.token.claim"=true' -s 'config."access.token.claim"=true' \
        -s 'config."userinfo.token.claim"=true'
fi

group_id="$(kc get groups -r "$REALM" --fields id,name --format csv --noquotes | awk -F, '$2 == "admins" {print $1; exit}')"
if [[ -z "$group_id" ]]; then
    group_id="$(kc create groups -r "$REALM" -i -s name=admins)"
fi

ensure_user() {
    local username="$1" password="$2" user_id
    user_id="$(kc_id users -q username="$username" -q exact=true)"
    if [[ -z "$user_id" ]]; then
        user_id="$(kc create users -r "$REALM" -i -s username="$username" -s enabled=true \
            -s emailVerified=true -s email="${username}@lab.invalid" \
            -s firstName="$username" -s lastName=Training)"
        kc set-password -r "$REALM" --username "$username" --new-password "$password"
        echo "    created ${username}"
    fi
    kc update "users/${user_id}/groups/${group_id}" -r "$REALM" \
        -s realm="$REALM" -s userId="$user_id" -s groupId="$group_id" -n
}
ensure_user instructor "$INSTRUCTOR_PASSWORD"
for number in $(seq 1 "$PARTICIPANT_COUNT"); do
    ensure_user "$(printf '%s%02d' "$PARTICIPANT_PREFIX" "$number")" "admingroup${number}"
done

step "Bootstrapping Juju"
mkdir -p /root/.local/share
if ! juju show-cloud lab-k8s --client >/dev/null 2>&1; then
    k8s config | juju add-k8s lab-k8s --client
fi
if ! juju show-controller lab-cm >/dev/null 2>&1; then
    juju bootstrap lab-k8s lab-cm
fi
if ! juju show-model "$MODEL" >/dev/null 2>&1; then
    juju add-model cluster-manager -c lab-cm
fi

step "Deploying Cluster Manager charms"
deploy() {
    local app="$1"
    shift
    if juju show-application -m "$MODEL" "$app" >/dev/null 2>&1; then
        echo "    ${app} already deployed"
    else
        retry juju deploy -m "$MODEL" "$app" --trust "$@"
    fi
}
deploy postgresql-k8s --channel 14/stable
deploy self-signed-certificates
deploy traefik-k8s --config "loadbalancer_annotations=${LB_ANNOTATIONS}"
deploy "$CM_APP"

juju config -m "$MODEL" traefik-k8s external_hostname="$MANAGER_IP" loadbalancer_annotations="$LB_ANNOTATIONS"
juju config -m "$MODEL" "$CM_APP" \
    management-api-domain="$MANAGER_IP" cluster-connector-domain="$MANAGER_IP" \
    oidc-issuer="${KEYCLOAK_URL}/realms/${REALM}" oidc-client-id="$CLIENT_ID" \
    oidc-client-secret="$OIDC_CLIENT_SECRET"

integrate() {
    local output
    if ! output="$(juju integrate -m "$MODEL" "$1" "$2" 2>&1)"; then
        grep -qi 'already exists' <<< "$output" || { echo "$output" >&2; return 1; }
    fi
}
integrate postgresql-k8s:database "$CM_APP"
integrate self-signed-certificates:certificates "$CM_APP"
integrate self-signed-certificates:send-ca-cert "$CM_APP"
integrate traefik-k8s:traefik-route "$CM_APP"

step "Waiting for the applications to become active (can take 10-20 minutes)"
for app in postgresql-k8s self-signed-certificates traefik-k8s "$CM_APP"; do
    juju wait-for application -m "$MODEL" "$app" --timeout 30m
done

step "Checking access"
login_redirect() {
    curl -sk -o /dev/null -w '%{redirect_url}' "https://${MANAGER_IP}/oidc/login" | grep -q "^${KEYCLOAK_URL}/realms/${REALM}/"
}
wait_until "Cluster Manager to redirect logins to Keycloak" 300 login_redirect
wait_until "the Cluster Connector on ${MANAGER_IP}:9100" 120 timeout 5 bash -c "</dev/tcp/${MANAGER_IP}/9100"

echo
echo "Cluster Manager is ready: https://${MANAGER_IP}"
