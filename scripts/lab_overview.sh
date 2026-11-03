#!/bin/bash
# Lab overview for the instructor: the Cluster Manager service, the instructor demos and every lab
# (MicroCloud, K8s Snap, K8s Juju) with nodes, state and addresses on screen, plus a CSV with the same data.
# Sourced by orchestrate.sh (uses its helpers) or run directly: ./scripts/lab_overview.sh

LAB_OVERVIEW_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-automation/lab-overview"

# Prints "<lab> <workspace> <scenario> <mode>" for every lab, in natural order of the lab name.
lab_overview_list_labs() {
    local workspace="" metadata="" lab="" scenario="" mode=""
    while IFS= read -r workspace; do
        workspace="${workspace//[* ]/}"
        [[ -z "$workspace" || "$workspace" == "default" ]] && continue
        metadata="$(parse_workspace_metadata "$workspace" 2>/dev/null)" || continue
        read -r lab scenario mode <<< "$metadata"
        echo "${lab} ${workspace} ${scenario} ${mode}"
    done < <(tofu workspace list 2>/dev/null) | sort -V
}

# Prints "<short node name>|<status>|<ip>" for the nodes of a lab. The management address is taken from
# enp5s0 when present, otherwise from the first interface with a global IPv4 address.
lab_overview_nodes() {
    local prefix="$1"
    lxc list --format json 2>/dev/null | python3 -c '
import json, re, sys
prefix = sys.argv[1]
def key(name):
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", name)]
rows = []
for instance in json.load(sys.stdin):
    name = instance["name"]
    if not name.startswith(prefix):
        continue
    addresses = {}
    for interface, data in ((instance.get("state") or {}).get("network") or {}).items():
        for address in data.get("addresses", []):
            if address.get("family") == "inet" and address.get("scope") == "global":
                addresses.setdefault(interface, address["address"])
    ip = addresses.get("enp5s0") or (addresses[sorted(addresses)[0]] if addresses else "-")
    rows.append((name[len(prefix):], instance.get("status", "-"), ip))
for name, status, ip in sorted(rows, key=lambda row: key(row[0])):
    print(f"{name}|{status}|{ip}")
' "$prefix"
}

lab_overview_cluster_manager() {
    local state_dir="${CM_STATE_DIR:-$HOME/.local/state/lab-automation/cluster-manager}"
    local csv="${state_dir}/participant-access.csv" vm_state="" cm_url="" kc_url="" accounts=""

    vm_state="$(lxc --project default list "local:${CM_VM:-lab-cluster-manager}" --format csv -c s 2>/dev/null | head -n 1)"
    if [[ -f "$csv" ]]; then
        accounts="$(( $(wc -l < "$csv") - 1 ))"
        IFS=, read -r _ _ cm_url kc_url < <(sed -n 2p "$csv")
        print_kv "Cluster Manager" "${cm_url}  (VM: ${vm_state:-missing}, ${accounts} participant accounts)"
        print_kv "Keycloak" "$kc_url"
        print_kv "Logins" "menu 7 > Show access"
    elif [[ -n "$vm_state" ]]; then
        print_kv "Cluster Manager" "installation not finished (VM: ${vm_state}); run menu 7 > Install / resume"
    else
        print_kv "Cluster Manager" "not installed (menu 7)"
    fi
}

lab_overview_landscape() {
    local state ip clients
    state="$(landscape_status "$LANDSCAPE_VM")" || return 1
    if [[ -z "$state" ]]; then
        print_kv "Landscape demo" "not installed (menu 10)"
        return 0
    fi
    if [[ "$state" == "RUNNING" ]]; then
        ip="$(landscape_ip "$LANDSCAPE_VM")" || return 1
        print_kv "Landscape demo" "https://${ip}/ (VM: ${state}, self-signed certificate)"
    else
        print_kv "Landscape demo" "${LANDSCAPE_VM} (VM: ${state})"
    fi
    if [[ -f "$LANDSCAPE_SETTINGS" ]]; then
        # shellcheck source=/dev/null
        print_kv "  login" "$(source "$LANDSCAPE_SETTINGS"; echo "${ADMIN_EMAIL} / ${ADMIN_PASSWORD}")"
    fi
    clients="$(landscape_instances | grep -c "^${LANDSCAPE_CLIENT_PREFIX}-")" || :
    print_kv "  clients" "${clients:-0} container(s)"
}

lab_overview_cos() {
    local state
    state="$(cos_lxc list "local:${COS_VM}" -c s -f csv 2>/dev/null | head -n 1)"
    if [[ -f "$COS_ACCESS" ]]; then
        (
            # shellcheck source=/dev/null
            source "$COS_ACCESS"
            print_kv "COS Lite demo" "http://${COS_IP}/cos-catalogue (VM: ${state:-missing})"
            print_kv "  Grafana" "http://${COS_IP}/cos-grafana  admin / ${GRAFANA_PASSWORD}"
            print_kv "  LXD dashboard" "http://${COS_IP}${DASHBOARD_PATH}"
        )
    elif [[ -n "$state" ]]; then
        print_kv "COS Lite demo" "installation not finished (VM: ${state}); rerun menu 11"
    else
        print_kv "COS Lite demo" "not installed (menu 11)"
    fi
}

lab_overview() {
    local labs=() entry="" lab="" workspace="" scenario="" mode="" kind=""
    local microcloud_labs=() partner="" i=0
    local nodes=() node_line="" node="" status="" ip="" ips=""
    local uplink="" gateway="" range="" routes="" dns=""
    local csv="${LAB_OVERVIEW_DIR}/all-labs.csv"
    declare -A partners=()

    mapfile -t labs < <(lab_overview_list_labs)

    # Consecutive MicroCloud training labs form a DR pair (01-02, 03-04, ...); a last odd lab is paired with the instructor.
    for entry in "${labs[@]}"; do
        read -r lab workspace scenario mode <<< "$entry"
        [[ "$scenario" == "microcloud" && "$mode" == "training" ]] && microcloud_labs+=("$lab")
    done
    for i in "${!microcloud_labs[@]}"; do
        if (( i % 2 == 0 )); then
            partners["${microcloud_labs[$i]}"]="${microcloud_labs[$((i + 1))]:-instructor}"
        else
            partners["${microcloud_labs[$i]}"]="${microcloud_labs[$((i - 1))]}"
        fi
    done

    umask 077
    mkdir -p "$LAB_OVERVIEW_DIR"
    chmod 700 "$LAB_OVERVIEW_DIR"
    echo '"type","lab","dr_partner","node_ips","uplink_gateway","uplink_first","uplink_last","uplink_dns","forward_routes"' > "$csv"

    print_section "Lab overview"
    lab_overview_cluster_manager
    lab_overview_landscape || return 1
    lab_overview_cos
    print_kv "Labs" "${#labs[@]}"

    for entry in "${labs[@]}"; do
        read -r lab workspace scenario mode <<< "$entry"
        case "$scenario" in
            microcloud) kind="MicroCloud" ;;
            k8s-snap) kind="K8s Snap" ;;
            k8s-juju) kind="K8s Juju" ;;
            *) kind="$scenario" ;;
        esac
        [[ "$mode" == "training" ]] && kind="${kind} training"
        partner="${partners[$lab]:-}"

        mapfile -t nodes < <(lab_overview_nodes "${workspace//_/-}-")
        ips=""
        for node_line in "${nodes[@]}"; do
            IFS='|' read -r _ _ ip <<< "$node_line"
            ips+="${ip} "
        done

        echo ""
        if [[ -n "$partner" ]]; then
            printf '  %s   [%s]   DR partner: %s\n' "$lab" "$kind" "$partner"
        else
            printf '  %s   [%s]\n' "$lab" "$kind"
        fi
        for node_line in "${nodes[@]}"; do
            IFS='|' read -r node status ip <<< "$node_line"
            printf '    %-14s %-16s %s\n' "$node" "$ip" "$status"
        done
        [[ ${#nodes[@]} -eq 0 ]] && echo "    no nodes found"

        gateway="" range="" routes=""
        if [[ "$scenario" == "microcloud" ]]; then
            uplink="$(get_microcloud_uplink_cidr "$workspace")"
            if [[ "$uplink" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                gateway="$(microcloud_uplink_gateway "$uplink")"
                range="$(microcloud_uplink_ovn_range "$uplink")"
                routes="$(microcloud_uplink_forward_routes "$uplink")"
                printf '    %-14s gateway %s, range %s, DNS %s  (for '"'"'microcloud init'"'"')\n' "OVN uplink" "$gateway" "$range" "$MICROCLOUD_UPLINK_DNS"
                printf '    %-14s %s  (set as UPLINK ipv4.routes after init, for network forwards)\n' "Forward range" "$routes"
            fi
        fi

        dns=""
        [[ -n "$gateway" ]] && dns="$MICROCLOUD_UPLINK_DNS"
        printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$kind" "$lab" "$partner" "${ips% }" "$gateway" "${range%-*}" "${range#*-}" "$dns" "$routes" >> "$csv"
    done
    chmod 600 "$csv"

    echo ""
    print_kv "CSV (all labs)" "$csv"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    cd "$SCRIPT_DIR" || exit 1
    # shellcheck source=../orchestrate.sh
    source "${SCRIPT_DIR}/orchestrate.sh"
    lab_overview
fi
