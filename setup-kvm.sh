#!/bin/bash
# setup-kvm.sh — Set up KVM/libvirt virtualisation environment
#
# Supports: Arch Linux (pacman) · Ubuntu/Debian (apt) · Fedora/RHEL (dnf)

set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║         KVM Environment Setup            ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# Must run as root or with sudo
[[ "$EUID" -ne 0 ]] && die "Please run as root: sudo $0"

# Capture the real user behind sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# ── 1. CPU virtualisation check ───────────────────────────────────────────────
info "Checking CPU virtualisation support…"
if grep -qE 'vmx|svm' /proc/cpuinfo; then
    VIRT_TYPE=$(grep -Eo 'vmx|svm' /proc/cpuinfo | sort -u | head -1)
    [[ "$VIRT_TYPE" == "vmx" ]] && CPU_VENDOR="Intel (VMX)" || CPU_VENDOR="AMD (SVM)"
    success "Hardware virtualisation supported: $CPU_VENDOR"
else
    die "CPU does not support hardware virtualisation (no vmx/svm in /proc/cpuinfo).
Check your BIOS/UEFI and enable VT-x or AMD-V."
fi

# ── 2. Detect package manager ─────────────────────────────────────────────────
info "Detecting package manager…"
if command -v pacman &>/dev/null; then
    PKG_MGR="pacman"
elif command -v apt &>/dev/null; then
    PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
else
    die "No supported package manager found (pacman / apt / dnf)."
fi
success "Package manager: $PKG_MGR"

# ── 3. Install packages ───────────────────────────────────────────────────────
info "Installing KVM/libvirt packages…"
case "$PKG_MGR" in
    pacman)
        pacman -Sy --noconfirm --needed \
            qemu-full \
            libvirt \
            virt-install \
            virt-manager \
            virt-viewer \
            edk2-ovmf \
            dnsmasq \
            nftables \
            iptables \
            libguestfs \
            guestfs-tools \
            spice-gtk \
            virtiofsd
        ;;
    apt)
        apt update -y
        apt install -y \
            qemu-system-x86 \
            qemu-utils \
            qemu-kvm \
            libvirt-daemon-system \
            libvirt-clients \
            virt-install \
            virt-manager \
            virt-viewer \
            ovmf \
            dnsmasq \
            bridge-utils \
            libguestfs-tools \
            spice-client-gtk \
            nftables
        ;;
    dnf)
        dnf install -y \
            qemu-kvm \
            qemu-img \
            libvirt \
            libvirt-daemon-config-network \
            libvirt-daemon-kvm \
            virt-install \
            virt-manager \
            virt-viewer \
            edk2-ovmf \
            dnsmasq \
            guestfs-tools \
            spice-gtk-tools \
            nftables
        ;;
esac
success "Packages installed"

# ── 4. Enable & start libvirt services ────────────────────────────────────────
info "Enabling libvirt services…"
systemctl enable --now libvirtd
systemctl enable --now virtlogd.socket
success "libvirtd running"

# ── 5. Add user to required groups ────────────────────────────────────────────
info "Adding '$REAL_USER' to libvirt and kvm groups…"
for grp in libvirt kvm; do
    if getent group "$grp" &>/dev/null; then
        usermod -aG "$grp" "$REAL_USER"
        success "Added to group: $grp"
    else
        warn "Group '$grp' not found — skipping"
    fi
done
# libvirt-qemu group (Arch/Debian)
if getent group libvirt-qemu &>/dev/null; then
    usermod -aG libvirt-qemu "$REAL_USER"
    success "Added to group: libvirt-qemu"
fi

# ── 6. Enable nested virtualisation ──────────────────────────────────────────
info "Enabling nested virtualisation…"
if [[ "$VIRT_TYPE" == "svm" ]]; then
    MOD="kvm_amd"
    PARAM="nested=1"
else
    MOD="kvm_intel"
    PARAM="nested=1"
fi

MODPROBE_CONF="/etc/modprobe.d/kvm-nested.conf"
echo "options $MOD nested=1" > "$MODPROBE_CONF"
success "Nested virt config written → $MODPROBE_CONF"

# Apply immediately if module is already loaded
CURRENT=$(cat /sys/module/${MOD}/parameters/nested 2>/dev/null || echo "0")
if [[ "$CURRENT" == "1" || "$CURRENT" == "Y" ]]; then
    success "Nested virt already active"
else
    warn "Nested virt will be active after next reboot (module reload required)"
fi

# ── 7. Enable IP forwarding ───────────────────────────────────────────────────
info "Enabling IP forwarding…"
SYSCTL_CONF="/etc/sysctl.d/99-kvm-ipforward.conf"
echo "net.ipv4.ip_forward = 1" > "$SYSCTL_CONF"
sysctl -w net.ipv4.ip_forward=1 &>/dev/null
success "IP forwarding enabled"

# ── 8. Set up default NAT network ────────────────────────────────────────────
info "Configuring default NAT network…"
if virsh net-info default &>/dev/null; then
    success "Default network already exists"
else
    virsh net-define /dev/stdin <<'NETXML'
<network>
  <name>default</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
NETXML
    success "Default NAT network defined"
fi

# Ensure it is active and set to autostart
virsh net-autostart default &>/dev/null
virsh net-start default &>/dev/null || true
success "Default network active and set to autostart"

# ── 9. Set up storage pools ───────────────────────────────────────────────────
info "Configuring storage pools…"
VM_BASE="$REAL_HOME/VirtualMachines"

declare -A POOLS=(
    [disks]="$VM_BASE/disks"
    [isos]="$VM_BASE/isos"
    [snapshots]="$VM_BASE/snapshots"
)

for POOL_NAME in "${!POOLS[@]}"; do
    POOL_PATH="${POOLS[$POOL_NAME]}"
    mkdir -p "$POOL_PATH"
    chown "$REAL_USER:$REAL_USER" "$POOL_PATH"

    if virsh pool-info "$POOL_NAME" &>/dev/null; then
        success "Pool '$POOL_NAME' already exists"
    else
        virsh pool-define-as "$POOL_NAME" dir --target "$POOL_PATH"
        success "Pool '$POOL_NAME' defined → $POOL_PATH"
    fi
    virsh pool-autostart "$POOL_NAME" &>/dev/null
    virsh pool-start "$POOL_NAME" &>/dev/null || true
done

# ── 10. Configure virsh default URI ──────────────────────────────────────────
info "Configuring virsh default URI to qemu:///system…"
LIBVIRT_CONF_DIR="$REAL_HOME/.config/libvirt"
LIBVIRT_CONF="$LIBVIRT_CONF_DIR/libvirt.conf"
mkdir -p "$LIBVIRT_CONF_DIR"
chown "$REAL_USER:$REAL_USER" "$LIBVIRT_CONF_DIR"

if grep -qs 'uri_default' "$LIBVIRT_CONF" 2>/dev/null; then
    sed -i 's|.*uri_default.*|uri_default = "qemu:///system"|' "$LIBVIRT_CONF"
    success "Updated uri_default in $LIBVIRT_CONF"
else
    echo 'uri_default = "qemu:///system"' >> "$LIBVIRT_CONF"
    success "Written uri_default to $LIBVIRT_CONF"
fi
chown "$REAL_USER:$REAL_USER" "$LIBVIRT_CONF"

# ── 11. Summary ───────────────────────────────────────────────────────────────
echo ""
success "KVM environment setup complete!"
echo ""
echo -e "  CPU Virt : ${CYAN}${CPU_VENDOR}${NC}"
echo -e "  Nested   : ${CYAN}enabled${NC}"
echo -e "  User     : ${CYAN}${REAL_USER}${NC}  (groups: libvirt, kvm)"
echo -e "  Network  : ${CYAN}default (192.168.122.0/24 NAT)${NC}"
echo -e "  Pools    : ${CYAN}disks, isos, snapshots${NC}  under $VM_BASE"
echo ""
warn "Log out and back in (or reboot) for group membership to take effect."
