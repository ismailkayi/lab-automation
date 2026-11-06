#!/bin/bash
set -Eeuo pipefail

export PATH="$PATH:/snap/bin"
export DEBIAN_FRONTEND=noninteractive
# needrestart could restart lxd-agent and end the host's exec session.
export NEEDRESTART_SUSPEND=1
# shellcheck source=/dev/null
source /root/landscape.env
: "${SERVER_IP:?SERVER_IP must be passed by the host}"
# The host also passes the versions from versions.env.
: "${LANDSCAPE_RELEASE:?}" "${LANDSCAPE_DEBARCHIVE_CHANNEL:?}" "${LANDSCAPE_TASK_HANDLER_CHANNEL:?}" \
    "${LANDSCAPE_OUTBOX_CHANNEL:?}"
trap 'echo "ERROR at line ${LINENO}; fix the problem and rerun menu 10." >&2' ERR

APT=(apt-get -y -q -o DPkg::Lock::Timeout=900
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
SERVICES=(landscape-task-handler.server landscape-task-handler.worker landscape-outbox.outbox
    landscape-debarchive.debarchive)

wait_web() {
    local _ code
    for _ in {1..120}; do
        code="$(curl -ksS --max-time 10 --output /dev/null --write-out '%{http_code}' https://localhost/)" || code="unreachable"
        [[ "$code" =~ ^(200|301|302|303)$ ]] && return 0
        sleep 5
    done
    echo "Landscape HTTPS did not become ready: ${code}" >&2
    return 1
}

wait_services() {
    local service _
    for service in "${SERVICES[@]}"; do
        for _ in {1..60}; do
            systemctl is-active --quiet "snap.${service}.service" && continue 2
            sleep 5
        done
        echo "snap.${service}.service is not active" >&2
        return 1
    done
}

psql_query() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -tAq "$@"; }

# Debarchive backs the Repositories pages (mirrors, local repositories, publications).
# Quickstart already proxies /debarchive/ to port 8100; the snap needs its own database.
configure_debarchive() {
    local password
    if ! snap list landscape-debarchive >/dev/null 2>&1; then
        snap install landscape-debarchive --channel="$LANDSCAPE_DEBARCHIVE_CHANNEL"
    fi
    password="$(snap get landscape-debarchive deb.archive.database.password 2>/dev/null)" || password=""
    if [[ ! "$password" =~ ^[A-Za-z0-9]{24}$ ]]; then
        password="$(python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(24)))')"
    fi
    if [[ "$(psql_query -c "SELECT 1 FROM pg_roles WHERE rolname='landscape_debarchive'")" == "1" ]]; then
        psql_query -c "ALTER ROLE landscape_debarchive WITH LOGIN PASSWORD '${password}';"
    else
        psql_query -c "CREATE ROLE landscape_debarchive WITH LOGIN PASSWORD '${password}';"
    fi
    if [[ "$(psql_query -c "SELECT 1 FROM pg_database WHERE datname='landscape-standalone-debarchive'")" != "1" ]]; then
        runuser -u postgres -- createdb --owner=landscape_debarchive landscape-standalone-debarchive
    fi
    psql_query -d landscape-standalone-debarchive -c \
        'GRANT USAGE, CREATE ON SCHEMA public TO landscape_debarchive;'
    snap set landscape-debarchive \
        deb.archive.database.name=landscape-standalone-debarchive \
        deb.archive.database.user=landscape_debarchive \
        "deb.archive.database.password=${password}"
}

wait_debarchive() {
    local _ code
    for _ in {1..60}; do
        code="$(curl -sS --max-time 10 --output /dev/null --write-out '%{http_code}' \
            http://localhost:8100/v1/mirrors)" || code="unreachable"
        [[ "$code" =~ ^[234] ]] && return 0
        sleep 5
    done
    echo "Debarchive did not become ready on port 8100: ${code}" >&2
    return 1
}

# The snap services fail when they start before their databases after a reboot.
configure_service_dependencies() {
    local service directory
    local -a units=()
    for service in "${SERVICES[@]}"; do
        units+=("snap.${service}.service")
        directory="/etc/systemd/system/snap.${service}.service.d"
        mkdir -p "$directory"
        cat > "$directory/99-landscape-demo.conf" <<EOF
[Unit]
Requires=postgresql.service
After=postgresql.service
EOF
        if [[ "$service" == "landscape-outbox.outbox" ]]; then
            cat >> "$directory/99-landscape-demo.conf" <<EOF
Requires=rabbitmq-server.service
After=rabbitmq-server.service
EOF
        fi
    done
    systemctl daemon-reload
    systemctl reset-failed "${units[@]}"
    systemctl start "${units[@]}"
}

# Browsers reach the demo by IP, and portal links such as "Switch to classic dashboard"
# are built from root_url. The certificate also covers the IP. Prints "changed" when edited.
configure_service_conf() {
    python3 - "https://${SERVER_IP}/" <<'PY'
import configparser
import sys
from pathlib import Path
path = Path("/etc/landscape/service.conf")
config = configparser.ConfigParser(interpolation=None, strict=False)
config.read(path)
changed = False
for section, key, value in (("features", "ubuntu_pro_licensing", "true"), ("system", "root_url", sys.argv[1])):
    if not config.has_section(section):
        config.add_section(section)
    if config.get(section, key, fallback=None) != value:
        config.set(section, key, value)
        changed = True
if changed:
    with path.open("w") as stream:
        config.write(stream)
    print("changed")
PY
}

# Older demo versions added a hostnamectl hook that blocks the agent at boot.
if [[ -f /etc/systemd/system/lxd-agent.service.d/99-landscape-hostname.conf ]]; then
    rm /etc/systemd/system/lxd-agent.service.d/99-landscape-hostname.conf
    systemctl daemon-reload
fi

if [[ -f /var/lib/lab-landscape/ready ]]; then
    # Also adds Debarchive to servers installed before it was part of the demo.
    configure_debarchive
    configure_service_dependencies
    service_conf="$(configure_service_conf)"
    if [[ "$service_conf" == "changed" ]]; then
        lsctl restart
    fi
    wait_web
    wait_services
    wait_debarchive
    echo "Landscape server is already configured."
    exit 0
fi

echo "==> Preparing the server for Landscape ${LANDSCAPE_RELEASE}"
cloud-init status --wait
mkdir -p /var/lib/lab-landscape /etc/cloud/cloud.cfg.d
# Quickstart builds its certificate from the FQDN.
cat > /etc/cloud/cloud.cfg.d/99-landscape-demo.cfg <<EOF
preserve_hostname: true
manage_etc_hosts: false
EOF
hostnamectl set-hostname "$FQDN"
if ! grep -qF "127.0.1.1 ${FQDN}" /etc/hosts; then
    printf '127.0.1.1 %s\n' "$FQDN" >> /etc/hosts
fi
if [[ ! -f /swapfile ]]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
fi
if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
    swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

snap wait system seed.loaded
"${APT[@]}" update
"${APT[@]}" install software-properties-common curl ca-certificates
add-apt-repository -y "ppa:landscape/self-hosted-${LANDSCAPE_RELEASE}"
"${APT[@]}" update
"${APT[@]}" install landscape-server-quickstart
version="$(dpkg-query -W -f='${Version}' landscape-server)"
[[ "$version" == "${LANDSCAPE_RELEASE}"* ]] || { echo "Unexpected Landscape version: ${version}" >&2; exit 1; }

echo "==> Configuring Task Handler, Outbox and Debarchive services"
if ! snap list landscape-task-handler >/dev/null 2>&1; then
    snap install landscape-task-handler --channel="$LANDSCAPE_TASK_HANDLER_CHANNEL"
fi
if [[ "$(psql_query -c "SELECT 1 FROM pg_database WHERE datname='landscape-standalone-task-handler'")" != "1" ]]; then
    runuser -u postgres -- createdb landscape-standalone-task-handler
fi
psql_query -d landscape-standalone-task-handler -c \
    'GRANT CONNECT ON DATABASE "landscape-standalone-task-handler" TO landscape; GRANT CREATE ON SCHEMA public TO landscape;'
db_password="$(python3 - <<'PY'
import base64
import configparser
config = configparser.ConfigParser(interpolation=None, strict=False)
config.read("/etc/landscape/service.conf")
password = config.get("stores", "password")
print(base64.b64decode(password[4:]).decode() if password.startswith("b64:") else password)
PY
)"
snap set landscape-task-handler \
    landscape.database.task-handler.host=localhost \
    landscape.database.task-handler.port=5432 \
    landscape.database.task-handler.name=landscape-standalone-task-handler \
    landscape.database.task-handler.user=landscape \
    "landscape.database.task-handler.password=${db_password}" \
    landscape.database.task-handler.ssl=disable \
    landscape.task-handler.server.grpc-port=50053 \
    landscape.task-handler.server.host=localhost
unset db_password
if ! snap list landscape-outbox >/dev/null 2>&1; then
    snap install landscape-outbox --channel="$LANDSCAPE_OUTBOX_CHANNEL"
fi
snap connect landscape-outbox:grpc-client-certs landscape-task-handler:grpc-client-certs
configure_debarchive
configure_service_dependencies

echo "==> Creating instructor account"
wait_web
if [[ ! -f /var/lib/lab-landscape/account-ready ]]; then
    /opt/canonical/landscape/bootstrap-account \
        --admin_email "$ADMIN_EMAIL" --admin_name "Landscape Instructor" \
        --admin_password="$ADMIN_PASSWORD" --registration_key="$REGISTRATION_KEY" \
        --system_email "noreply@landscape.internal" --root_url "https://${SERVER_IP}/"
    touch /var/lib/lab-landscape/account-ready
fi
psql_query -d landscape-standalone-main -c \
    "UPDATE account SET auto_register_new_computers = true WHERE name = 'standalone';"
configure_service_conf >/dev/null
lsctl restart
wait_web
wait_services
wait_debarchive
touch /var/lib/lab-landscape/ready
echo "==> Landscape ${version} server configured"
