#!/bin/bash
# Lab overview for the instructor: the Cluster Manager service, the instructor demos and every lab
# (MicroCloud, K8s Snap, K8s Juju) with nodes, state and addresses on screen, plus a CSV with the same data.
# Sourced by orchestrate.sh (uses its helpers) or run directly: ./scripts/lab_overview.sh

LAB_OVERVIEW_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-automation/lab-overview"

lab_overview_heading() {
    printf '\n  %s\n' "$1"
    printf '  %s\n' "--------------------------------------------------------"
}

lab_overview_field() {
    printf '    %-18s %s\n' "$1" "$2"
}

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
    local csv="${state_dir}/participant-access.csv" settings="${state_dir}/settings.env"
    local vm_state="" cm_url="" kc_url="" accounts=""

    vm_state="$(lxc --project default list "local:${CM_VM:-lab-cluster-manager}" --format csv -c s 2>/dev/null | head -n 1)"
    lab_overview_heading "Cluster Manager"
    if [[ -f "$csv" && -f "$settings" ]]; then
        accounts="$(( $(wc -l < "$csv") - 1 ))"
        IFS=, read -r _ _ cm_url kc_url < <(sed -n 2p "$csv")
        (
            # shellcheck source=/dev/null
            source "$settings"
            lab_overview_field "VM state" "${vm_state:-missing}"
            lab_overview_field "Web UI" "$cm_url"
            lab_overview_field "Username" "instructor"
            lab_overview_field "Password" "$INSTRUCTOR_PASSWORD"
            lab_overview_field "Keycloak" "${kc_url}/admin/"
            lab_overview_field "Keycloak user" "lab-admin"
            lab_overview_field "Keycloak password" "$KEYCLOAK_ADMIN_PASSWORD"
            lab_overview_field "Accounts" "${accounts} participant accounts"
            lab_overview_field "Participant logins" "menu 9 > Show access"
        )
    elif [[ -n "$vm_state" ]]; then
        lab_overview_field "VM state" "$vm_state"
        lab_overview_field "Setup" "installation not finished"
        lab_overview_field "Next step" "menu 9 > Install / resume"
    else
        lab_overview_field "Setup" "not installed (menu 9)"
    fi
}

lab_overview_landscape() {
    local state ip clients
    state="$(landscape_status "$LANDSCAPE_VM")" || return 1
    lab_overview_heading "Landscape demo"
    if [[ -z "$state" ]]; then
        lab_overview_field "Setup" "not installed (menu 10)"
        return 0
    fi
    lab_overview_field "VM" "$LANDSCAPE_VM"
    lab_overview_field "VM state" "$state"
    if [[ "$state" == "RUNNING" ]]; then
        ip="$(landscape_ip "$LANDSCAPE_VM")" || return 1
        lab_overview_field "Web UI" "https://${ip}/"
        lab_overview_field "Certificate" "self-signed"
    fi
    if [[ -f "$LANDSCAPE_SETTINGS" ]]; then
        (
            # shellcheck source=/dev/null
            source "$LANDSCAPE_SETTINGS"
            lab_overview_field "Username" "$ADMIN_EMAIL"
            lab_overview_field "Password" "$ADMIN_PASSWORD"
        )
    fi
    clients="$(landscape_instances | grep -c "^${LANDSCAPE_CLIENT_PREFIX}-")" || :
    lab_overview_field "Demo clients" "${clients:-0} container(s)"
}

lab_overview_cos() {
    local state
    state="$(cos_lxc list "local:${COS_VM}" -c s -f csv 2>/dev/null | head -n 1)"
    lab_overview_heading "COS Lite demo"
    if [[ -f "$COS_ACCESS" ]]; then
        (
            # shellcheck source=/dev/null
            source "$COS_ACCESS"
            lab_overview_field "VM state" "${state:-missing}"
            lab_overview_field "Catalogue" "http://${COS_IP}/cos-catalogue"
            lab_overview_field "Grafana" "http://${COS_IP}/cos-grafana"
            lab_overview_field "Username" "admin"
            lab_overview_field "Password" "$GRAFANA_PASSWORD"
            lab_overview_field "LXD dashboard" "http://${COS_IP}${DASHBOARD_PATH}"
        )
    elif [[ -n "$state" ]]; then
        lab_overview_field "VM state" "$state"
        lab_overview_field "Setup" "installation not finished"
        lab_overview_field "Next step" "rerun menu 11"
    else
        lab_overview_field "Setup" "not installed (menu 11)"
    fi
}

lab_overview_maas() {
    local state
    state="$(maas_lxc list "local:^${MAAS_VM}\$" -c s -f csv 2>/dev/null | head -n 1)"
    lab_overview_heading "MAAS demo"
    if [[ -f "$MAAS_ACCESS" && -f "$MAAS_SETTINGS" ]]; then
        (
            # shellcheck source=/dev/null
            source "$MAAS_SETTINGS"
            # shellcheck source=/dev/null
            source "$MAAS_ACCESS"
            lab_overview_field "VM state" "${state:-missing}"
            lab_overview_field "Web UI" "http://${MAAS_IP}:${MAAS_WEB_PORT}/MAAS"
            lab_overview_field "Username" "admin"
            lab_overview_field "Password" "$ADMIN_PASSWORD"
            lab_overview_field "Version" "MAAS ${MAAS_VERSION}"
        )
    elif [[ -n "$state" ]]; then
        lab_overview_field "VM state" "$state"
        lab_overview_field "Setup" "installation not finished"
        lab_overview_field "Next step" "rerun menu 12"
    else
        lab_overview_field "Setup" "not installed (menu 12)"
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
    print_kv "Participant labs" "${#labs[@]}"
    print_section "Instructor services"
    lab_overview_cluster_manager
    lab_overview_landscape || return 1
    lab_overview_cos
    lab_overview_maas

    print_section "Participant labs (${#labs[@]})"
    if [[ ${#labs[@]} -eq 0 ]]; then
        echo "  No participant labs found."
    fi

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

        lab_overview_heading "${lab} | ${kind}"
        if [[ -n "$partner" ]]; then
            lab_overview_field "DR partner" "$partner"
        fi
        if [[ ${#nodes[@]} -gt 0 ]]; then
            printf '\n    %-14s %-12s %s\n' "NODE" "STATE" "MANAGEMENT IP"
            printf '    %-14s %-12s %s\n' "--------------" "------------" "---------------"
            for node_line in "${nodes[@]}"; do
                IFS='|' read -r node status ip <<< "$node_line"
                printf '    %-14s %-12s %s\n' "$node" "$status" "$ip"
            done
        else
            echo "    no nodes found"
        fi

        gateway="" range="" routes=""
        if [[ "$scenario" == "microcloud" ]]; then
            uplink="$(get_microcloud_uplink_cidr "$workspace")"
            if [[ "$uplink" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                gateway="$(microcloud_uplink_gateway "$uplink")"
                range="$(microcloud_uplink_ovn_range "$uplink")"
                routes="$(microcloud_uplink_forward_routes "$uplink")"
                printf '\n    OVN uplink (microcloud init)\n'
                lab_overview_field "Gateway" "$gateway"
                lab_overview_field "Address range" "$range"
                lab_overview_field "DNS" "$MICROCLOUD_UPLINK_DNS"
                printf '\n    Network forwards (after init)\n'
                lab_overview_field "UPLINK ipv4.routes" "$routes"
            fi
        fi

        dns=""
        [[ -n "$gateway" ]] && dns="$MICROCLOUD_UPLINK_DNS"
        printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$kind" "$lab" "$partner" "${ips% }" "$gateway" "${range%-*}" "${range#*-}" "$dns" "$routes" >> "$csv"
    done
    chmod 600 "$csv"

    print_section "Export"
    print_kv "CSV (all labs)" "$csv"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    cd "$SCRIPT_DIR" || exit 1
    # shellcheck source=../orchestrate.sh
    source "${SCRIPT_DIR}/orchestrate.sh"
    lab_overview
fi
