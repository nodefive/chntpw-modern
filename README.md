# chntpw ISO Modernizer

Modernizes the [chntpw](http://pogostick.net/~pnh/ntpasswd/) Offline NT Password & Registry Editor ISO (originally built for 2014 hardware, Linux 3.10.5 i386) to support **NVMe drives**, **UEFI boot**, and **modern kernels (Linux 6.x / 7.x)** — while leaving every original tool completely untouched inside the initrd.

> **DISCLAIMER** — chntpw is a powerful system administration tool. Only use it on systems you own or have explicit written authorisation to service. The authors of chntpw-modern assume no liability for any damage arising from use or misuse of this software.

---

## Quick Start

```bash
# 1. Place the original chntpw ISO in legacy/
cp /path/to/chntpw.iso legacy/

# 2. Run as root
sudo bash chntpw-modernizer.sh
```

Press **A** to open the Automated Build submenu, then:

- Press **A** again to build everything from scratch, including the kernel (15–60 min the first time).
- Press **1** then **3** (or type `13` at the prompt) to skip the kernel compile and reuse an existing `work/vmlinuz-modern`.

For a fully non-interactive CI/scripted build:

```bash
sudo bash chntpw-modernizer.sh --batch
```

---

## Project Structure

```
chntpw-modernizer.sh    ← Single script: settings at top, all logic inside. Run this.
make_regf.py            ← Helper: generates fake Windows registry hives for QEMU testing.
README.md               ← This file.
kernel.config           ← Exported kernel config (Step 13 output, for version control).

legacy/                 ← Original chntpw ISO — never modified.
│   └── chntpw.iso

source/                 ← Assembled ISO tree, ready to pack into a final ISO.
│   ├── isolinux/       ← BIOS boot: isolinux.bin, vmlinuz, initrd.cgz, scsi.cgz, configs
│   ├── EFI/            ← UEFI boot: BOOTX64.EFI (standalone GRUB2), efiboot.img (FAT16)
│   └── boot/grub/      ← GRUB2 config used by the EFI binary
│   └── thisiscd        ← Marker: tells init scripts this is a CD boot, not floppy

work/                   ← All intermediate build files. Safe to wipe (X → A or X → W).
│   ├── iso_extract/    ← Step 1 output:  original ISO extracted here
│   ├── initrd_extract/ ← Step 2 output:  original initrd.cgz unpacked
│   ├── initrd_patched/ ← Step 3 output:  patched initrd (NVMe + timing fixes)
│   ├── initrd.cgz      ← Step 4 output:  repacked patched initrd
│   ├── scsi.cgz        ← Step 5 output:  empty stub (replaces old kernel modules)
│   ├── kernel/         ← Steps 6-8:      kernel.config, source tarball, compiled bzImage
│   │   ├── kernel.config
│   │   ├── linux-X.Y.tar.xz
│   │   ├── linux-X.Y/
│   │   └── build.log
│   ├── vmlinuz-modern  ← Step 8 output:  compiled kernel bzImage
│   ├── efi/            ← Step 10 work:   grub-embedded.cfg staging area
│   ├── ovmf_vars_runtime.fd  ← QEMU: writable OVMF vars copy (auto-created)
│   ├── test_sata.qcow2 ← QEMU test drive: SATA with fake Windows install
│   └── test_nvme.qcow2 ← QEMU test drive: NVMe with fake Windows install

release/                ← Final ISO lands here.
    └── chntpw-modern.iso
```

---

## Menu Steps

| Step | What it does |
|------|-------------|
| **1** | Create directory structure; move chntpw.iso to `legacy/` if found at root |
| **2** | Extract `legacy/chntpw.iso` → `work/iso_extract/` |
| **3** | Unpack `initrd.cgz` → `work/initrd_extract/` |
| **4** | Apply NVMe + modern hardware patches → `work/initrd_patched/` |
| **5** | Repack patched initrd → `work/initrd.cgz` |
| **6** | Build empty stub `work/scsi.cgz` (replaces old 3.10 kernel modules) |
| **7** | Generate `work/kernel/kernel.config` for Linux 6.x / 7.x |
| **8** | Download kernel source from kernel.org (prompts for version, validates ≥ 6.x) |
| **9** | Compile kernel → `work/vmlinuz-modern` *(15–60 min)* |
| **10** | Assemble `source/` tree: copy kernel, initrd, boot configs |
| **11** | Build EFI image: `BOOTX64.EFI` + 16 MiB FAT16 `efiboot.img` |
| **12** | Build final hybrid ISO → `release/chntpw-modern.iso` |
| **13** | Export `work/kernel/kernel.config` to project root + show build summary |
| **T** | QEMU Test Lab submenu |
| **A** | Automated Build submenu (see below) |
| **C** | Check all required tools are installed |
| **X** | Clean submenu (see below) |
| **Z** | Exit |

### Automated Build submenu (A)

| Option | What it runs |
|--------|-------------|
| **1** | Suboption 1: Extraction & Patching — Steps 1–6 |
| **2** | Suboption 2: Kernel Build — Steps 7–9 *(15–60 min)* |
| **3** | Suboption 3: ISO Assembly — Steps 10–12 |
| **A** | All suboptions in sequence — Steps 1–12 |

Suboptions can be combined by typing multiple digits at the prompt. For example, typing `13` runs suboptions 1 and 3 in sequence — the fast path when a compiled `work/vmlinuz-modern` already exists.

### Clean submenu (X)

| Option | What is deleted |
|--------|----------------|
| **A** | `work/`  `release/`  `source/` — full clean, keeps `legacy/` and scripts |
| **W** | `work/` only — keeps `source/` and `release/` (useful after re-patching initrd) |

Both options remove any empty directories left behind.

### Batch / CI mode

```bash
sudo bash chntpw-modernizer.sh --batch
```

Runs a complete non-interactive build: clean everything, then Steps 1–12. Useful for automated pipelines or scripted rebuilds.

---

## Configuration

Edit the top of `chntpw-modernizer.sh`. All user-facing settings are in one block:

| Variable | Default | Description |
|----------|---------|-------------|
| `KERNEL_VERSION` | `7.1` | Default kernel version; Step 8 prompts to override. Must be 6.x or 7.x. |
| `ISO_OUTPUT_NAME` | `chntpw-modern.iso` | Output filename in `release/` |
| `ISO_VOLID` | `CHNTPW_MODERN` | ISO volume label (max 32 chars, uppercase) |
| `ISO_PREPARER` | `chntpw-modern <…>` | Embedded in ISO metadata |
| `ISO_PUBLISHER` | `chntpw-modern` | Embedded in ISO metadata |
| `EFI_IMG_SIZE` | `16` | MiB for the FAT16 EFI boot image |
| `QEMU_IMG_SIZE` | `4G` | Size of each QEMU dummy test drive |
| `QEMU_MEMORY` | `512M` | RAM for QEMU test VMs |
| `QEMU_SMP` | `2` | vCPUs for QEMU test VMs |
| `QEMU_VGA` | `std` | QEMU VGA adapter (`std`, `virtio`, `vmware`, `qxl`) |
| `OVMF_CODE` | `/usr/share/edk2/x64/OVMF_CODE.4m.fd` | UEFI firmware (read-only) |
| `OVMF_VARS` | `/usr/share/edk2/x64/OVMF_VARS.4m.fd` | UEFI vars template (copied per run) |
| `ISOLINUX_BIN` | `/usr/lib/syslinux/bios/isolinux.bin` | Arch layout; Debian: `/usr/lib/ISOLINUX/` |
| `ISOHDPFX_BIN` | `/usr/lib/syslinux/bios/isohdpfx.bin` | MBR hybrid prefix |
| `SYSLINUX_MODULES` | `/usr/lib/syslinux/bios` | Directory with `menu.c32`, `ldlinux.c32`, etc. |
| `PYTHON3` | `python3` | Override if named differently |
| `XORRISO` | `xorriso` | ISO builder |
| `GRUB_MKSTANDALONE` | `grub-mkstandalone` | Fedora/RHEL: `grub2-mkstandalone` |
| `MKDOSFS` | `mkdosfs` | Also: `mkfs.fat` |
| `MKNTFS` | `mkntfs` | From `ntfs-3g-progs` / `ntfsprogs` |
| `NTFS3G` | `ntfs-3g` | FUSE NTFS driver |
| `QEMU` | `qemu-system-x86_64` | Also: `qemu-kvm` |
| `QEMU_IMG` | `qemu-img` | QEMU disk image tool |
| `PKG_INSTALL` | `apt-get install -y` | Arch: `pacman -S`, Fedora: `dnf install -y` |

---

## What is Preserved (Untouched)

| Item | Location in initrd | Status |
|------|--------------------|--------|
| `chntpw` binary | `/bin/chntpw` | **Unchanged** |
| `reged` binary | `/bin/reged` | **Unchanged** |
| `sampasswd` / `samusrgrp` | `/bin/` | **Unchanged** |
| `ntfs-3g` + `ntfs-3g.probe` | `/bin/` | **Unchanged** |
| All shell wizard scripts | `/scripts/` | **Unchanged** (except targeted patches below) |
| `busybox` (all applets) | `/bin/busybox` | **Unchanged** |
| All uClibc 0.9.27 libraries | `/lib/` | **Unchanged** |

---

## What is Modernized

| Component | Original | Modernized |
|-----------|----------|-----------|
| Kernel | Linux 3.10.5 (Aug 2013, i386) | Linux 6.x / 7.x (x86_64, IA32 emulation) |
| Kernel modules | Loadable `.ko` files (`scsi.cgz`) | Monolithic — all drivers built-in |
| Boot (BIOS) | Old `isolinux.bin` from 2014 ISO | Current `isolinux` from system package |
| Boot (UEFI) | Not supported | Standalone GRUB2 EFI binary + 16 MiB FAT16 ESP |
| Display mode | `vga=1` (40×25 half-width) | `vga=normal` (80×25 standard text) |
| NVMe storage | Not detected at all | Built-in `CONFIG_BLK_DEV_NVME=y` |
| SATA/AHCI | Module (`ahci.ko` for 3.10) | Built-in `CONFIG_SATA_AHCI=y` |
| USB 3.x (XHCI) | Module | Built-in `CONFIG_USB_XHCI_HCD=y` |
| VirtIO block | Module | Built-in `CONFIG_VIRTIO_BLK=y` |
| `scsi.cgz` | 87 `.ko` modules for kernel 3.10.5 | Empty stub (modules not needed) |

---

## initrd Patches (Step 4)

All patches are minimal and surgical. Originals are saved as `.orig` files.

### `scripts/diskscan.sh` — Patch A1: add NVMe to device scan list

When HP CCISS RAID is present the script builds an explicit device list. NVMe was missing:

```diff
  ls /dev | grep -q cciss && d='/dev/cciss!c?d? /dev/sd? /dev/hd?'
+ ls /dev | grep -q nvme  && d="$d /dev/nvme?n?"
```

### `scripts/diskscan.sh` — Patch A2: fix NVMe disk-name extraction

`sed 's/[0-9]//g'` strips all digits, turning `nvme0n1p1` → `nvmenp` (wrong). Fixed:

```diff
- d=`basename $dev | sed 's/[0-9]//g'`
+ d=`basename $dev`
+ case "$d" in
+   nvme*) d=`echo "$d" | sed 's/p[0-9]*$//'` ;;
+   *)     d=`echo "$d" | sed 's/[0-9]*$//'`  ;;
+ esac
```

### `scripts/findwin.sh` — Patch B: exclude bare NVMe disk from mount scan

`/proc/partitions` awk matched all entries ending in a digit. NVMe disk `nvme0n1` ends in `1` and was wrongly treated as a partition:

```diff
- !/(sr|fd)[0-9]$/ && /[0-9]$/ {
+ !/(sr|fd)[0-9]$/ && /[0-9]$/ && !/(nvme[0-9]+n[0-9]+)$/ {
```

NVMe *partitions* (`nvme0n1p1`, ending in `p1`) are NOT excluded.

### `scripts/stage2` — Patch C: wait for block devices before scanning

NVMe controllers probe asynchronously. `mdev -s` was running before the NVMe device appeared in sysfs:

```sh
# Poll /proc/partitions until a block device appears (up to 10 seconds)
for i in 1 2 3 4 5 6 7 8 9 10; do
    grep -qE '(sd[a-z]|nvme[0-9]|vd[a-z]|hd[a-z])' /proc/partitions && break
    sleep 1
done
mdev -s   # rescan sysfs after devices settle
```

Also resets VTs 1–4 to a clean 80×25 state (`ESC[2J`) so all consoles look consistent.

### `scripts/prepdriver.sh` — Patch D: guard empty `/drivers` directory

With a monolithic kernel the stub `scsi.cgz` provides an empty `/drivers/`. The original `mv *` would fail on an empty directory:

```diff
- cd $DRVDIR
- mv * $MODDIR
+ cd $DRVDIR
+ ls * 2>/dev/null && mv * $MODDIR || true
```

### `init` — Patch E: update boot banner (cosmetic)

```diff
- /bin/busybox echo "### Booting ntpasswd"
+ /bin/busybox echo "### Booting ntpasswd (chntpw-modern kernel)"
```

---

## Kernel Configuration (Step 7)

Generated at `work/kernel/kernel.config`. Targets Linux **6.x and 7.x** (step 8 rejects versions < 6).

Key design decisions:

| Setting | Value | Reason |
|---------|-------|--------|
| `CONFIG_MODULES=n` | off | Monolithic — all drivers compiled in, no `.ko` needed |
| `CONFIG_IA32_EMULATION=y` | on | Run original 32-bit i386 chntpw/busybox/ntfs-3g binaries |
| `CONFIG_X86_X32_ABI=n` | off | Explicitly disabled for 6.0–6.6 (removed in 6.7, ignored after) |
| `CONFIG_BLK_DEV_NVME=y` | on | NVMe SSD support |
| `CONFIG_SATA_AHCI=y` | on | SATA/AHCI — covers 95% of modern systems and QEMU |
| `CONFIG_ATA_PIIX=y` | on | Intel ICH/PIIX — default QEMU SATA controller |
| `CONFIG_VIRTIO_BLK=y` | on | VirtIO block device for QEMU/KVM/cloud |
| `CONFIG_USB_XHCI_HCD=y` | on | USB 3.x host controller |
| `CONFIG_USB_STORAGE=y` | on | USB mass storage → `/dev/sd*` |
| `CONFIG_NTFS3_FS=y` | on | Kernel-native NTFS read/write |
| `CONFIG_FUSE_FS=y` | on | Required by `ntfs-3g` FUSE driver |
| `CONFIG_EFI_STUB=y` | on | Kernel bootable directly as EFI application |
| `CONFIG_FB_EFI=y` | on | EFI GOP framebuffer |
| `CONFIG_DEVTMPFS_MOUNT=y` | on | Kernel auto-populates `/dev` before init |
| `CONFIG_SCSI_SCAN_ASYNC=n` | off | Synchronous scan — all devices ready before userspace |

Known cross-version notes baked into the config:
- `CONFIG_EFI_VARS` — **removed in Linux 6.0**, not set; `CONFIG_EFIVAR_FS=y` used instead
- `CONFIG_ATA_VERBOSE_ERROR` — became always-on in 6.x; kept, silently ignored
- `CONFIG_NTFS3_LZX_XPRESS` — always-on in 6.x; kept for reference
- `CONFIG_SCSI_HISI_SAS` — ARM-only dependency; silently skipped on x86_64

---

## EFI Boot Design (Steps 10–11)

### Why FAT16 and not FAT32

FAT32 requires at least 65,525 clusters. At 16 MiB with 512-byte sectors that gives only ~32,768 clusters — `mkdosfs` emits a warning and OVMF's strict FAT driver refuses to mount the image ("no bootable image"). FAT16 has no minimum cluster count and is explicitly required by the UEFI spec §12.3.1.

### Why a standalone GRUB2 binary

`grub-mkstandalone` bakes the boot menu directly into `BOOTX64.EFI`. This avoids a chicken-and-egg problem: if GRUB uses a `configfile` redirect to find `grub.cfg` on the ISO, it needs `$prefix` pointing at its module memdisk — but any path lookup before modules are loaded causes GRUB to drop to an interactive prompt with a broken `$prefix`, making every command fail with "module not found". Embedding the menu means no filesystem reads are needed at startup.

### Why `$isoroot` instead of `$root`

The standalone EFI binary loads its GRUB modules from an internal memdisk; `$root` points there. After finding the ISO 9660 volume (by label `CHNTPW_MODERN`), the config stores it in `$isoroot` — a separate variable — so `$root` is never clobbered and module loading continues to work for the duration of the session.

---

## QEMU Test Lab (T)

The test lab is fully automated from the menu. Manually the commands are:

### Create test drives (T → 1)

The script creates `work/test_sata.qcow2` and `work/test_nvme.qcow2` with:
- GPT partition table
- 100 MiB FAT32 EFI partition
- Remaining space NTFS with a **fake Windows install** (`Windows/System32/config/SAM`, `SYSTEM`, `SOFTWARE`, `SECURITY`) generated by `make_regf.py`

The fake SAM contains one Administrator account with a blank password so `chntpw` detects and lists it.

### BIOS + SATA (T → 2)

```bash
qemu-system-x86_64 \
    -m 512M -smp 2 \
    -cdrom release/chntpw-modern.iso -boot order=d \
    -drive  file=work/test_sata.qcow2,if=none,id=sata0,format=qcow2 \
    -device ich9-ahci,id=ahci \
    -device ide-hd,drive=sata0,bus=ahci.0 \
    -vga std -no-reboot
```

### BIOS + NVMe (T → 3)

```bash
qemu-system-x86_64 \
    -m 512M -smp 2 \
    -cdrom release/chntpw-modern.iso -boot order=d \
    -drive  file=work/test_nvme.qcow2,if=none,id=nvme0,format=qcow2 \
    -device nvme,serial=chntpw0,drive=nvme0 \
    -vga std -no-reboot
```

### UEFI + SATA (T → 4)

```bash
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd /tmp/ovmf_vars.fd

qemu-system-x86_64 -machine q35 \
    -m 512M -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
    -drive if=pflash,format=raw,file=/tmp/ovmf_vars.fd \
    -device ich9-ahci,id=ahci_cd \
    -drive  file=release/chntpw-modern.iso,media=cdrom,if=none,id=cdrom0,readonly=on \
    -device ide-cd,drive=cdrom0,bus=ahci_cd.0 \
    -device ich9-ahci,id=ahci_hd \
    -drive  file=work/test_sata.qcow2,if=none,id=sata0,format=qcow2 \
    -device ide-hd,drive=sata0,bus=ahci_hd.0 \
    -vga std -no-reboot
```

> **Note:** UEFI (Q35 machine) requires the CD-ROM attached via explicit AHCI controller, not the `-cdrom` shorthand — OVMF may not probe the legacy IDE path reliably.

### UEFI + NVMe (T → 5)

Same as above but replace the SATA hard drive lines with:

```bash
    -drive  file=work/test_nvme.qcow2,if=none,id=nvme0,format=qcow2 \
    -device nvme,serial=chntpw0,drive=nvme0 \
```

---

## make_regf.py

A pure-Python script (no third-party libraries) that generates minimal but structurally valid Windows Registry hive files in the **REGF binary format** (version 1.3, Windows XP era — the most broadly compatible).

Used only during QEMU test drive creation. Produces:

| File | Contents |
|------|----------|
| `SAM` | Root → SAM → Domains → Account → Users → `000001F4` (Administrator RID 500) with valid NK/VK/LF/SK cells and a V blob containing the username and blank-password hash stubs |
| `SYSTEM` | Minimal stub with a single root NK — sufficient for chntpw's SYSKEY check |
| `SOFTWARE` | Minimal stub root NK |
| `SECURITY` | Minimal stub root NK |

The Administrator V blob has `hash_flag = 0` (no hash stored) which chntpw treats as a blank password — allowing the password change flow to be tested end-to-end without needing real Windows hive files.

---

## Architecture Notes

### Why 32-bit binaries work on a 64-bit kernel

The original chntpw, busybox, and ntfs-3g are **32-bit i386 ELF** binaries linked against uClibc 0.9.27. `CONFIG_IA32_EMULATION=y` provides full 32-bit ABI compatibility at the syscall level — the same mechanism every 64-bit Linux distro uses to run 32-bit libc. No recompilation needed.

### Boot flow

```
Power on
│
├─[BIOS]────────────────────────────────────────────────────────
│   MBR (isohdpfx.bin hybrid) → El Torito → isolinux.bin
│   isolinux.cfg → vmlinuz  initrd=initrd.cgz,scsi.cgz
│
└─[UEFI]────────────────────────────────────────────────────────
    GPT → EFI partition (efiboot.img, FAT16)
    EFI/BOOT/BOOTX64.EFI  (standalone GRUB2, menu baked in)
    Searches ISO 9660 by volume label CHNTPW_MODERN → $isoroot
    linux ($isoroot)/isolinux/vmlinuz
    initrd ($isoroot)/isolinux/initrd.cgz ($isoroot)/isolinux/scsi.cgz

Kernel boots (x86_64, monolithic — all drivers built-in)
    devtmpfs auto-mounted on /dev by kernel before init
    init → mount /proc /sys → mdev -s
    stage2:
        poll /proc/partitions until sd*/nvme*/vd* appears (≤10s)
        mdev -s  (rescan after NVMe async probe settles)
        prepdriver.sh  (mv empty /drivers → noop; depmod -a)
        autoscsi.sh    (modprobe calls fail silently — no .ko files)
        mdev -s
        main.sh → findwin.sh → mount NTFS → chntpw
```

---

## Requirements

```bash
# Arch Linux
sudo pacman -S xorriso grub mtools dosfstools ntfs-3g \
               qemu-full parted syslinux edk2-ovmf python rsync

# Debian / Ubuntu
sudo apt-get install xorriso grub-efi-amd64-bin mtools dosfstools ntfs-3g \
                     qemu-system-x86 parted isolinux syslinux-common \
                     ovmf python3 rsync

# Kernel compile (Step 9) also needs:
sudo apt-get install build-essential libssl-dev libelf-dev flex bison \
                     bc pahole libncurses-dev dwarves
```

Disk space: ~20 GB for a full build with kernel source.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| No drives listed at boot | Kernel driver missing | Verify `CONFIG_BLK_DEV_NVME=y` / `CONFIG_SATA_AHCI=y` |
| NVMe not listed despite driver | Async probe timing | Already fixed by stage2 wait loop; increase sleep count if needed |
| `modprobe: not found` at boot | Expected | Harmless — monolithic kernel, no modules to load |
| UEFI black screen | No font for gfxterm | Fixed — EFI config forces `terminal_output console` before any video module |
| UEFI won't boot at all | Secure Boot enabled | Disable Secure Boot — the EFI binary is unsigned |
| GRUB `file not found` | Volume label mismatch | Check `ISO_VOLID` matches the `search --label` in grub config |
| chntpw shows empty partition list | No Windows on test drive | Run T → 1 to create drives with fake Windows; or use a real Windows disk |
| ntfs-3g fails | No `/dev/fuse` | `mdev -s` should create it; `CONFIG_FUSE_FS=y` must be set |
| 32-bit crash / illegal instruction | IA32 emulation missing | Verify `CONFIG_IA32_EMULATION=y` |
| Ugly font on VT2 / VT3 | Was `vga=1` (40×25 mode) | Fixed — now `vga=normal` (80×25); VT reset sent to all consoles |
| `make_regf.py` fails | Python < 3.6 | Update Python; script uses only stdlib |

---

## Licence

The **chntpw-modernizer scripts** are released under the **MIT Licence**.

The **chntpw tool** (`chntpw`, `reged`, `sampasswd`, `samusrgrp`) is © 1998–2014 Petter Nordahl-Hagen, distributed under **GNU GPL v2**. Not modified.

The **Linux kernel** is distributed under **GNU GPL v2**.

---

## Credits

- **Petter Nordahl-Hagen** — original chntpw tool and boot environment (1998–2014)
- **nodefive** — chntpw-modern: UEFI/NVMe modernization layer, kernel 6.x/7.x build system, and dual-mode boot infrastructure built on top of Petter's original work. All original chntpw binaries and wizard scripts are preserved untouched; everything else in this repository is new work.
- **The Linux kernel team** — for a kernel that still runs 2013 binaries
- **The GRUB2 / syslinux teams** — for dual-mode boot infrastructure
