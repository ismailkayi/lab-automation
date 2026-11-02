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
if [[ -n "$PRO_TOKEN" ]]; then
    attached="$(pro status --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["attached"])')"
    if [[ "$attached" != "True" ]]; then
        pro attach "$PRO_TOKEN" --no-auto-enable
    fi
fi
unset PRO_TOKEN
if ! grep -qF "${SERVER_IP} ${FQDN}" /etc/hosts; then
    printf '%s %s\n' "$SERVER_IP" "$FQDN" >> /etc/hosts
fi
install -m 0644 /root/landscape-server.pem /etc/landscape/server.pem
if ! landscape-config --is-registered; then
    landscape-config --silent --account-name standalone \
        --computer-title "$(hostname)" \
        --url "https://${FQDN}/message-system" --ping-url "http://${FQDN}/ping" \
        --ssl-public-key /etc/landscape/server.pem --registration-key "$REGISTRATION_KEY" \
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
