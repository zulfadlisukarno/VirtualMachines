# AGENTS.md

Bash scripts for KVM/libvirt VM management. No build system, no tests, no CI.

## Setup & prerequisites

- `setup-kvm.sh` **must be run as root** (`sudo ./setup-kvm.sh`). All other scripts run as a normal user.
- After `setup-kvm.sh`, log out/in (or reboot) for `libvirt`/`kvm` group membership to take effect.
- Required tools: `qemu-img`, `virt-customize` (libguestfs/guestfs-tools), `virt-install`, `virsh`.

## Script dependency order

1. `setup-kvm.sh` — one-time KVM environment setup (done once per host)
2. `download-ubuntu-cloud-image.sh` — downloads base cloud images into `images/`
3. `new-vm.sh` — creates a VM from a base image in `images/`, writes the disk to `disks/`

## Directory layout

| Directory | Purpose | Git-tracked? |
|-----------|---------|--------------|
| `images/` | Base cloud images (`.img`, `.qcow2`) | No (`.gitignore`) |
| `disks/` | Per-VM disk files | No (`.gitignore`) |
| `snapshots/` | VM snapshots | No (`.gitignore`) |
| `isos/` | ISO files | No (`.gitignore`) |
| `cloud-init/` | cloud-init configs | Only `.gitkeep` |

Every data directory uses `.gitkeep` to hold the empty directory in Git; actual content is gitignored.

## Script conventions

- All scripts use `set -euo pipefail`.
- Colored output via `RED`, `GREEN`, `YELLOW`, `CYAN`, `NC` ANSI escape sequences and helper functions (`info`, `success`, `warn`, `die`).
- `new-vm.sh` injects SSH config via `/etc/ssh/sshd_config.d/50-opencode.conf` inside the guest (overrides cloudimg defaults that disable password auth).

## `new-vm.sh` modes

- **Simple** (mode 1): defaults (2 GB RAM, 2 vCPUs, Spice display, first available libvirt network), random password prompt.
- **Advanced** (mode 2): prompts for every option including network (with bridge support), display (Spice/VNC/headless), user, password, SSH key.
