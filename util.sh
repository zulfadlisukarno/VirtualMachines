#!/bin/bash
# util.sh — VM management utilities menu

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── list_vm_ips ───────────────────────────────────────────────────────────────
list_vm_ips() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    Running VM IP Addresses                    ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""

    mapfile -t RUNNING_VMS < <(virsh list --name 2>/dev/null | grep -v '^$' || true)

    if [[ ${#RUNNING_VMS[@]} -eq 0 ]]; then
        warn "No running VMs found."
        echo ""
        return
    fi

    local rows=()
    for vm in "${RUNNING_VMS[@]}"; do
        local found=0

        if command -v virsh &>/dev/null; then
            local addrs
            addrs=$(virsh domifaddr "$vm" --source agent 2>/dev/null || true)
            if [[ -n "$addrs" ]] && echo "$addrs" | grep -q '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+'; then
                while IFS= read -r line; do
                    local ip mac
                    ip=$(echo "$line" | awk '{print $4}' | cut -d/ -f1)
                    mac=$(echo "$line" | awk '{print $2}')
                    [[ -n "$ip" ]] && rows+=("$vm|$ip|$mac|guest-agent")
                done < <(echo "$addrs" | tail -n +3)
                found=1
            fi

            if [[ $found -eq 0 ]]; then
                mapfile -t VM_MACS < <(virsh domiflist "$vm" 2>/dev/null \
                    | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' || true)
                for vm_mac in "${VM_MACS[@]}"; do
                    local lease_line
                    lease_line=$(virsh net-dhcp-leases default 2>/dev/null \
                        | grep -i "$vm_mac" | head -1 || true)
                    if [[ -n "$lease_line" ]]; then
                        local ip
                        ip=$(echo "$lease_line" | awk '{print $5}' | cut -d/ -f1)
                        if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                            rows+=("$vm|$ip|$vm_mac|dhcp-leases")
                            found=1
                        fi
                    fi
                done
            fi
        fi

        if [[ $found -eq 0 ]]; then
            local vm_mac
            vm_mac=$(virsh domiflist "$vm" 2>/dev/null | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1 || true)
            if [[ -n "$vm_mac" ]]; then
                local arp_ip
                arp_ip=$(ip neigh 2>/dev/null | grep -i "$vm_mac" | awk '{print $1}' | head -1 || true)
                if [[ -n "$arp_ip" ]]; then
                    rows+=("$vm|$arp_ip|$vm_mac|arp")
                    found=1
                fi
            fi
        fi

        if [[ $found -eq 0 ]]; then
            rows+=("$vm|-|-|-")
        fi
    done

    printf "  %-20s %-15s %-18s %s\n" "VM Name" "IP Address" "MAC Address" "Source"
    printf "  %-20s %-15s %-18s %s\n" "───────" "──────────" "───────────" "──────"
    for row in "${rows[@]}"; do
        IFS='|' read -r name ip mac src <<< "$row"
        if [[ "$ip" == "-" ]]; then
            printf "  %-20s %-15s %-18s %s\n" "$name" "${YELLOW}N/A${NC}" "${YELLOW}-${NC}" "${YELLOW}-${NC}"
        else
            printf "  %-20s %-15s %-18s %s\n" "$name" "$ip" "$mac" "$src"
        fi
    done
    echo ""
}

# ── start_vm ──────────────────────────────────────────────────────────────────
start_vm() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    Start a Shutdown VM                       ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""

    mapfile -t INACTIVE_VMS < <(virsh list --inactive --name 2>/dev/null | grep -v '^$' || true)

    if [[ ${#INACTIVE_VMS[@]} -eq 0 ]]; then
        warn "No shutdown VMs found."
        echo ""
        return
    fi

    echo -e "  ${YELLOW}Shutdown VMs:${NC}"
    for i in "${!INACTIVE_VMS[@]}"; do
        printf "  [%d] %s\n" "$((i + 1))" "${INACTIVE_VMS[$i]}"
    done
    echo "  [0] Cancel"
    echo ""
    read -rp "Select VM to start [0-${#INACTIVE_VMS[@]}]: " choice

    if [[ "$choice" -eq 0 ]] 2>/dev/null; then
        info "Cancelled."
        echo ""
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "${#INACTIVE_VMS[@]}" ]]; then
        warn "Invalid selection."
        echo ""
        return
    fi

    local selected="${INACTIVE_VMS[$((choice - 1))]}"
    info "Starting ${selected}..."
    if virsh start "$selected" &>/dev/null; then
        success "${selected} started successfully."
    else
        die "Failed to start ${selected}."
    fi
    echo ""
}

# ── shutdown_vm ───────────────────────────────────────────────────────────────
shutdown_vm() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    Shutdown a Running VM                     ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""

    mapfile -t RUNNING_VMS < <(virsh list --name 2>/dev/null | grep -v '^$' || true)

    if [[ ${#RUNNING_VMS[@]} -eq 0 ]]; then
        warn "No running VMs found."
        echo ""
        return
    fi

    echo -e "  ${GREEN}Running VMs:${NC}"
    for i in "${!RUNNING_VMS[@]}"; do
        printf "  [%d] %s\n" "$((i + 1))" "${RUNNING_VMS[$i]}"
    done
    echo "  [a] Shutdown All"
    echo "  [0] Cancel"
    echo ""
    read -rp "Select VM to shutdown [0-${#RUNNING_VMS[@]} or a]: " choice

    if [[ "$choice" == "0" ]] 2>/dev/null; then
        info "Cancelled."
        echo ""
        return
    fi

    if [[ "$choice" == "a" ]]; then
        info "Shutting down all VMs..."
        for vm in "${RUNNING_VMS[@]}"; do
            info "Shutting down ${vm}..."
            virsh shutdown "$vm" &>/dev/null || warn "Failed to shutdown ${vm}."
        done
        success "Shutdown signal sent to all VMs."
        echo ""
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "${#RUNNING_VMS[@]}" ]]; then
        warn "Invalid selection."
        echo ""
        return
    fi

    local selected="${RUNNING_VMS[$((choice - 1))]}"
    info "Shutting down ${selected}..."
    if virsh shutdown "$selected" &>/dev/null; then
        success "Shutdown signal sent to ${selected}."
    else
        die "Failed to shutdown ${selected}."
    fi
    echo ""
}

# ── main menu ─────────────────────────────────────────────────────────────────
while true; do
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║            VM Utilities Menu             ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  [1] List VM"
    echo "  [2] Start VM"
    echo "  [3] Shutdown VM"
    echo "  [0] Exit"
    echo ""
    read -rp "Select option [0-3]: " OPTION

    case "$OPTION" in
        1) list_vm_ips ;;
        2) start_vm ;;
        3) shutdown_vm ;;
        0) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) warn "Invalid option. Please choose 0-3." ;;
    esac
    echo ""
done
