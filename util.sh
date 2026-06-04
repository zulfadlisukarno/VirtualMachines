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

    for vm in "${RUNNING_VMS[@]}"; do
        echo -e "  ${GREEN}${vm}${NC}"

        # Try virsh domifaddr (most reliable, requires qemu-guest-agent)
        local ip_found=0
        if command -v virsh &>/dev/null; then
            local addrs
            addrs=$(virsh domifaddr "$vm" --source agent 2>/dev/null || true)
            if [[ -n "$addrs" ]] && echo "$addrs" | grep -q '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+'; then
                echo "$addrs" | tail -n +3 | while read -r line; do
                    local ip mac
                    ip=$(echo "$line" | awk '{print $4}' | cut -d/ -f1)
                    mac=$(echo "$line" | awk '{print $2}')
                    [[ -n "$ip" ]] && printf "    IP : %s  (MAC: %s, via guest-agent)\n" "$ip" "$mac"
                done
                ip_found=1
            fi

            # Fallback to dhcp-leases if guest-agent didn't return anything
            if [[ $ip_found -eq 0 ]]; then
                # Get the VM's MAC address(es) from domiflist
                mapfile -t VM_MACS < <(virsh domiflist "$vm" 2>/dev/null \
                    | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' || true)
                for vm_mac in "${VM_MACS[@]}"; do
                    # Match by MAC address (field 3 in dhcp-leases: date=2 fields + MAC=3rd)
                    local lease_line
                    lease_line=$(virsh net-dhcp-leases default 2>/dev/null \
                        | grep -i "$vm_mac" | head -1 || true)
                    if [[ -n "$lease_line" ]]; then
                        # Fields: Exp-Date Exp-Time  MAC(3)  Proto(4)  IP/mask(5)  Hostname(6)  ...
                        local ip
                        ip=$(echo "$lease_line" | awk '{print $5}' | cut -d/ -f1)
                        if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                            printf "    IP : %s  (MAC: %s, via dhcp-leases)\n" "$ip" "$vm_mac"
                            ip_found=1
                        fi
                    fi
                done
            fi
        fi

        # Final fallback: arp table
        if [[ $ip_found -eq 0 ]]; then
            local vm_mac
            vm_mac=$(virsh domiflist "$vm" 2>/dev/null | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1 || true)
            if [[ -n "$vm_mac" ]]; then
                local arp_ip
                arp_ip=$(ip neigh 2>/dev/null | grep -i "$vm_mac" | awk '{print $1}' | head -1 || true)
                if [[ -n "$arp_ip" ]]; then
                    printf "    IP : %s  (MAC: %s, via arp)\n" "$arp_ip" "$vm_mac"
                    ip_found=1
                fi
            fi
        fi

        if [[ $ip_found -eq 0 ]]; then
            warn "  Could not determine IP address. Is qemu-guest-agent installed?"
        fi
        echo ""
    done
}

# ── main menu ─────────────────────────────────────────────────────────────────
while true; do
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║            VM Utilities Menu             ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  [1] List VM IP"
    echo "  [0] Exit"
    echo ""
    read -rp "Select option [0-1]: " OPTION

    case "$OPTION" in
        1) list_vm_ips ;;
        0) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) warn "Invalid option. Please choose 0 or 1." ;;
    esac
    echo ""
done
