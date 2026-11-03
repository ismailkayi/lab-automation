#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/snap/bin"
trap 'echo "Landscape client setup failed at line ${LINENO}; rerun menu 10." >&2' ERR
trap 'rm -f /root/landscape-client.env /root/landscape-server.pem' EXIT
# shellcheck source=/dev/null
source /root/landscape-client.env

cloud-init status --wait
if ! dpkg-query -W -f='${db:Status-Status}' landscape-client 2>/dev/null | grep -qx installed; then
    apt-get -q -o DPkg::Lock::Timeout=600 update
    apt-get -y -q -o DPkg::Lock::Timeout=600 install landscape-client ca-certificates
fi
pro_attached() {
    pro api u.pro.status.is_attached.v1 |
        python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["data"]["attributes"]["is_attached"] else 1)'
}
pro_enabled_services() {
    pro api u.pro.status.enabled_services.v1 |
        python3 -c 'import json, sys; print(" ".join(s["name"] for s in json.load(sys.stdin)["data"]["attributes"]["enabled_services"]))'
}
# A wrong token must not break the demo: warn and register the client without Pro.
if [[ -n "$PRO_TOKEN" ]] && ! pro_attached; then
    pro attach "$PRO_TOKEN" --no-auto-enable ||
        echo "WARNING: Ubuntu Pro attach failed on $(hostname); continuing without Pro." >&2
fi
unset PRO_TOKEN
if pro_attached; then
    for service in esm-infra esm-apps; do
        if [[ " $(pro_enabled_services) " != *" ${service} "* ]]; then
            pro enable "$service" --assume-yes ||
                echo "WARNING: Could not enable ${service} on $(hostname)." >&2
        fi
    done
fi
if ! grep -qF "${SERVER_IP} ${FQDN}" /etc/hosts; then
    printf '%s %s\n' "$SERVER_IP" "$FQDN" >> /etc/hosts
fi
install -m 0644 /root/landscape-server.pem /etc/landscape/server.pem
if ! landscape-config --is-registered; then
    landscape-config --silent --account-name standalone \
        --computer-title "$(hostname)" \
        --url "https://${FQDN}/message-system" --ping-url "http://${FQDN}/ping" \
        --ssl-public-key /etc/landscape/server.pem --registration-key="$REGISTRATION_KEY" \
        --tags instructor-demo --script-users root --include-manager-plugins ScriptExecution
fi
for _ in {1..60}; do
    if landscape-config --is-registered; then
        echo "Demo client is registered. Inventory may take a few minutes to appear."
        exit 0
    fi
    sleep 5
done
echo "Client registration timed out. Inspect /var/log/landscape/broker.log." >&2
exit 1
