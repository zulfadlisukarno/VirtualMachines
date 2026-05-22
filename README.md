# VirtualMachines

KVM/libvirt virtual machine management scripts.

## Directory Structure

```
VirtualMachines/
├── setup-kvm.sh                    # One-time KVM environment setup
├── new-vm.sh                       # Create a new VM from a cloud image
├── download-ubuntu-cloud-image.sh  # Download Ubuntu cloud images
├── images/                         # Base cloud images (.img / .qcow2)
├── disks/                          # VM disk files
├── isos/                           # ISO files
├── snapshots/                      # VM snapshots
└── cloud-init/                     # cloud-init configs
```

## Scripts

### `setup-kvm.sh`
One-time setup script to install and configure the KVM/libvirt environment.

**Must be run as root (`sudo`).**

- Checks CPU hardware virtualisation support (Intel VMX / AMD SVM)
- Installs KVM, QEMU, libvirt, virt-manager, OVMF and related packages
- Supports **Arch Linux** (pacman), **Ubuntu/Debian** (apt), and **Fedora/RHEL** (dnf)
- Enables and starts `libvirtd` service
- Adds the current user to `libvirt` and `kvm` groups
- Enables nested virtualisation
- Enables IP forwarding
- Sets up a default NAT network (`192.168.122.0/24`)
- Registers `disks`, `isos`, and `snapshots` as libvirt storage pools

```bash
sudo ./setup-kvm.sh
```

---

### `new-vm.sh`
Interactive script to create a new VM from an existing cloud image in the `images/` folder.

**Requires:** `qemu-img`, `virt-customize` (libguestfs), `virt-install`, `virsh`

- Lets you pick a base image from `images/`
- Prompts for VM name, RAM, vCPUs, disk size, network, and display type
- Offers **Simple mode** (quick defaults) or **Advanced mode** (full control)
- Resizes the disk and root filesystem if a larger disk is requested
- Injects user credentials, SSH keys, and netplan config into the disk image
- Disables cloud-init to prevent it from overriding the injected config
- Defines and optionally starts the VM via `virt-install`

```bash
./new-vm.sh
```

---

### `download-ubuntu-cloud-image.sh`
Interactive script to download Ubuntu cloud images (QCow2 UEFI/GPT) into the `images/` folder.

- Fetches available Ubuntu LTS versions from [cloud-images.ubuntu.com](https://cloud-images.ubuntu.com/)
- Lists versions with EOL status
- Downloads the selected image directly into `images/`
- Supports both `wget` and `curl`

```bash
./download-ubuntu-cloud-image.sh
```

---

## Typical Workflow

```bash
# 1. Set up KVM (once)
sudo ./setup-kvm.sh

# 2. Download a base cloud image
./download-ubuntu-cloud-image.sh

# 3. Create a VM from the downloaded image
./new-vm.sh
```
