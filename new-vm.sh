#!/bin/bash
# new-vm.sh — Create a new VM from a QCow2 UEFI/GPT base image

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="$BASE_DIR/images"
DISKS_DIR="$BASE_DIR/disks"
OVMF_CODE="/usr/share/OVMF/x64/OVMF_CODE.4m.fd"
OVMF_VARS_TEMPLATE="/usr/share/OVMF/x64/OVMF_VARS.4m.fd"

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║        New VM from QCow2 Image           ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ── 0. Check dependencies ─────────────────────────────────────────────────────
if ! command -v virt-customize &>/dev/null; then
    die "virt-customize is required but not installed.

  Install it with:
    apt/deb  : sudo apt install libguestfs-tools
    dnf/rpm  : sudo dnf install guestfs-tools
    pacman   : sudo pacman -S libguestfs"
fi

# ── 1. Pick base image ────────────────────────────────────────────────────────
mapfile -t IMAGES < <(find "$IMAGES_DIR" -maxdepth 1 \( -name "*.img" -o -name "*.qcow2" \) 2>/dev/null | sort)
[[ ${#IMAGES[@]} -eq 0 ]] && die "No .img/.qcow2 files found in $IMAGES_DIR"

echo "Available base images:"
for i in "${!IMAGES[@]}"; do
    size=$(qemu-img info --output=json "${IMAGES[$i]}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('virtual-size',0)//1073741824,'GB')" 2>/dev/null || echo "?")
    printf "  [%d] %s  (%s)\n" "$((i+1))" "$(basename "${IMAGES[$i]}")" "$size"
done
echo ""
read -rp "Select base image [1-${#IMAGES[@]}]: " IMG_IDX
[[ "$IMG_IDX" =~ ^[0-9]+$ ]] && (( IMG_IDX >= 1 && IMG_IDX <= ${#IMAGES[@]} )) || die "Invalid selection"
BASE_IMAGE="${IMAGES[$((IMG_IDX-1))]}"
success "Base image: $(basename "$BASE_IMAGE")"

# ── 2. VM name ────────────────────────────────────────────────────────────────
read -rp "VM name: " VM_NAME
[[ -z "$VM_NAME" ]] && die "VM name cannot be empty"
virsh dominfo "$VM_NAME" &>/dev/null && die "A VM named '$VM_NAME' already exists"

# Pre-calculate base image size (needed by both modes)
BASE_VSIZE=$(qemu-img info --output=json "$BASE_IMAGE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('virtual-size',0)//1073741824)")

# ── 3. Mode selection ─────────────────────────────────────────────────────────
echo ""
echo "  [1] Simple   — use defaults, random password"
echo "  [2] Advanced — configure each option"
echo ""
read -rp "Mode [default: 1]: " MODE_IDX
MODE_IDX=${MODE_IDX:-1}

if [[ "$MODE_IDX" == "1" ]]; then
    # ── Simple mode defaults ──────────────────────────────────────────────────
    VM_RAM=2048
    VM_CPUS=2
    VM_DISK_GB=$(( BASE_VSIZE > 20 ? BASE_VSIZE : 20 ))
    VM_USER="ubuntu"
    while true; do
        read -rsp "Password for '${VM_USER}': " VM_PASS; echo
        [[ -z "$VM_PASS" ]] && { warn "Password cannot be empty"; continue; }
        read -rsp "Confirm password: " VM_PASS2; echo
        [[ "$VM_PASS" == "$VM_PASS2" ]] && break
        warn "Passwords do not match, try again"
    done
    VM_SSHKEY=""
    GRAPHICS_ARG="spice,listen=127.0.0.1"

    # Pick first available network
    mapfile -t NETWORKS < <(virsh net-list --name 2>/dev/null | grep -v '^$' | sort)
    [[ ${#NETWORKS[@]} -eq 0 ]] && die "No active libvirt networks found"
    NETWORK_ARG="network=${NETWORKS[0]}"

    echo ""
    success "Simple mode — defaults applied:"
    echo -e "  RAM      : ${CYAN}${VM_RAM} MB${NC}"
    echo -e "  vCPUs    : ${CYAN}${VM_CPUS}${NC}"
    echo -e "  Disk     : ${CYAN}${VM_DISK_GB} GB${NC}"
    echo -e "  Network  : ${CYAN}${NETWORKS[0]}${NC}"
    echo -e "  Display  : ${CYAN}Spice${NC}"
    echo -e "  User     : ${CYAN}${VM_USER}${NC}"
    echo -e "  Password : ${CYAN}${VM_PASS}${NC}"
    echo ""

elif [[ "$MODE_IDX" == "2" ]]; then
    # ── Advanced mode ─────────────────────────────────────────────────────────

    # Resources
    TOTAL_RAM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
    read -rp "RAM in MB [default: 2048, host has ${TOTAL_RAM_MB}MB]: " VM_RAM
    VM_RAM=${VM_RAM:-2048}
    [[ "$VM_RAM" =~ ^[0-9]+$ ]] || die "Invalid RAM value"

    HOST_CPUS=$(nproc)
    read -rp "vCPUs [default: 2, host has ${HOST_CPUS}]: " VM_CPUS
    VM_CPUS=${VM_CPUS:-2}
    [[ "$VM_CPUS" =~ ^[0-9]+$ ]] || die "Invalid CPU value"

    # Disk size
    read -rp "Disk size in GB [default: $((BASE_VSIZE > 20 ? BASE_VSIZE : 20)), min: ${BASE_VSIZE}GB]: " VM_DISK_GB
    VM_DISK_GB=${VM_DISK_GB:-$((BASE_VSIZE > 20 ? BASE_VSIZE : 20))}
    [[ "$VM_DISK_GB" =~ ^[0-9]+$ ]] && (( VM_DISK_GB >= BASE_VSIZE )) || die "Disk must be >= ${BASE_VSIZE}GB"

    # Network
    mapfile -t NETWORKS < <(virsh net-list --name 2>/dev/null | grep -v '^$' | sort)
    echo ""
    echo "Available networks:"
    for i in "${!NETWORKS[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${NETWORKS[$i]}"
    done
    printf "  [%d] %s\n" "$((${#NETWORKS[@]}+1))" "bridge (specify manually)"
    read -rp "Select network [default: 1]: " NET_IDX
    NET_IDX=${NET_IDX:-1}

    if (( NET_IDX == ${#NETWORKS[@]}+1 )); then
        read -rp "Bridge interface name (e.g. br0): " NET_BRIDGE
        NETWORK_ARG="bridge=$NET_BRIDGE"
    else
        [[ "$NET_IDX" =~ ^[0-9]+$ ]] && (( NET_IDX >= 1 && NET_IDX <= ${#NETWORKS[@]} )) || die "Invalid network selection"
        SELECTED_NET="${NETWORKS[$((NET_IDX-1))]}"
        NETWORK_ARG="network=${SELECTED_NET}"
    fi

    # Display
    echo ""
    echo "Display options:"
    echo "  [1] Spice (recommended for desktop)"
    echo "  [2] VNC"
    echo "  [3] None (headless)"
    read -rp "Select display [default: 1]: " DISP_IDX
    DISP_IDX=${DISP_IDX:-1}
    case "$DISP_IDX" in
        1) GRAPHICS_ARG="spice,listen=127.0.0.1" ;;
        2) GRAPHICS_ARG="vnc,listen=127.0.0.1" ;;
        3) GRAPHICS_ARG="none" ;;
        *) die "Invalid display selection" ;;
    esac

    # User credentials
    echo ""
    echo "First user account:"
    read -rp "Username [default: ubuntu]: " VM_USER
    VM_USER=${VM_USER:-ubuntu}

    while true; do
        read -rsp "Password: " VM_PASS; echo
        [[ -z "$VM_PASS" ]] && { warn "Password cannot be empty"; continue; }
        read -rsp "Confirm password: " VM_PASS2; echo
        [[ "$VM_PASS" == "$VM_PASS2" ]] && break
        warn "Passwords do not match, try again"
    done

    read -rp "SSH public key (paste or leave blank to skip): " VM_SSHKEY

else
    die "Invalid mode selection"
fi

# ── 8. Build the disk ────────────────────────────────────────────────────────
DISK_PATH="$DISKS_DIR/${VM_NAME}.qcow2"
VARS_PATH="$DISKS_DIR/${VM_NAME}-OVMF_VARS.fd"

info "Copying OVMF VARS (UEFI NVRAM) → $VARS_PATH"
cp "$OVMF_VARS_TEMPLATE" "$VARS_PATH"

info "Creating disk → $DISK_PATH  (${VM_DISK_GB}GB)"
# Detect the root partition (largest ext4/xfs filesystem)
ROOT_PART=$(virt-filesystems --long --all -a "$BASE_IMAGE" 2>/dev/null \
    | awk '$2=="filesystem" && ($3=="ext4" || $3=="xfs") {print $1, $4, $6}' \
    | awk '
        # Priority 1: label contains "root" (case-insensitive)
        tolower($2) ~ /root/ { print $1; found=1; exit }
        # Collect candidates: exclude known non-root labels
        tolower($2) !~ /boot|efi|uefi|swap/ { if ($3+0 > max) { max=$3+0; best=$1 } }
        END { if (!found) print best }
    ')
[[ -z "$ROOT_PART" ]] && die "Could not detect root partition in base image"
info "Root partition detected: $ROOT_PART"

if (( VM_DISK_GB > BASE_VSIZE )); then
    # Create blank target disk at requested size, then virt-resize expands
    # the root partition + filesystem to fill the extra space
    qemu-img create -f qcow2 "$DISK_PATH" "${VM_DISK_GB}G"
    info "Resizing partitions and filesystem with virt-resize…"
    virt-resize --expand "$ROOT_PART" "$BASE_IMAGE" "$DISK_PATH"
else
    # Same size — plain convert is enough
    qemu-img convert -f qcow2 -O qcow2 "$BASE_IMAGE" "$DISK_PATH"
fi

# ── 9. Inject credentials into disk ──────────────────────────────────────────
info "Injecting credentials into disk…"
VIRT_CUST_ARGS=(
    -a "$DISK_PATH"
    --run-command "id -u ${VM_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${VM_USER}"
    --run-command "usermod -aG sudo ${VM_USER} 2>/dev/null || usermod -aG wheel ${VM_USER} 2>/dev/null || true"
    --run-command "echo '${VM_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${VM_USER}"
    --password "${VM_USER}:password:${VM_PASS}"
    --password "root:password:${VM_PASS}"
    --run-command "passwd -u root >/dev/null 2>&1 || true"
    --run-command "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true"
    --run-command "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true"
)
[[ -n "$VM_SSHKEY" ]] && VIRT_CUST_ARGS+=(--ssh-inject "${VM_USER}:string:${VM_SSHKEY}")

VIRT_CUST_ARGS+=(
    # Generate SSH host keys (cloud images ship without them; openssh needs them)
    --run-command "ssh-keygen -A"
)
virt-customize "${VIRT_CUST_ARGS[@]}"
success "Credentials injected"

# ── 10. Define the VM ────────────────────────────────────────────────────────
info "Defining VM with virt-install…"
virt-install \
    --name "$VM_NAME" \
    --memory "$VM_RAM" \
    --vcpus "$VM_CPUS" \
    --disk "path=$DISK_PATH,format=qcow2,bus=virtio,cache=writeback" \
    --boot "uefi" \
    --boot "loader=${OVMF_CODE},loader.readonly=yes,loader.type=pflash,nvram=${VARS_PATH}" \
    --os-variant detect=on,require=off \
    --network "$NETWORK_ARG,model=virtio" \
    --graphics "$GRAPHICS_ARG" \
    --video vga \
    --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
    --import \
    --noautoconsole \
    --noreboot 2>&1

# ── 11. Summary ───────────────────────────────────────────────────────────────
echo ""
success "VM '${VM_NAME}' created successfully!"
echo ""
echo -e "  Disk     : ${CYAN}${DISK_PATH}${NC}"
echo -e "  OVMF VARS: ${CYAN}${VARS_PATH}${NC}"
echo -e "  RAM      : ${CYAN}${VM_RAM} MB${NC}"
echo -e "  vCPUs    : ${CYAN}${VM_CPUS}${NC}"
echo -e "  User     : ${CYAN}${VM_USER}${NC}"
echo -e "  Password : ${CYAN}${VM_PASS}${NC}"
echo ""
echo "Useful commands:"
echo "  virsh start $VM_NAME"
echo "  virsh console $VM_NAME"
echo "  virsh shutdown $VM_NAME"
echo "  virsh undefine $VM_NAME --nvram --remove-all-storage"
echo ""

read -rp "Start the VM now? [y/N]: " START_NOW
if [[ "${START_NOW,,}" == "y" ]]; then
    virsh start "$VM_NAME"
    success "VM started. Connect with: virt-viewer $VM_NAME  or  virsh console $VM_NAME"
fi
