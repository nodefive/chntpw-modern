#!/bin/bash
# ===========================================================================
#  chntpw ISO Modernization Workshop
#
#  Usage:   sudo bash chntpw-modernizer.sh
#
#  Edit the USER-CONFIGURABLE SETTINGS below, then run the script.
# ===========================================================================
set -euo pipefail

# ===========================================================================
# ★  USER-CONFIGURABLE SETTINGS
#    These are the only values you should ever need to change.
# ===========================================================================

# --- Kernel build ---------------------------------------------------------
KERNEL_VERSION="7.1"          # Default version (Step 8 will prompt to override)

# --- Output ISO -----------------------------------------------------------
ISO_OUTPUT_NAME="chntpw-modern.iso"          # Filename written into release/
ISO_VOLID="CHNTPW_MODERN"                    # Volume label (max 32 chars, UPPERCASE)
ISO_PREPARER="chntpw-modern <github.com/chntpw-modern>"
ISO_PUBLISHER="chntpw-modern"
EFI_IMG_SIZE=16               # MiB for the FAT16 EFI boot image

# --- Non-interactive / batch mode -----------------------------------------
#     Set to 1 via --batch flag; skips all interactive prompts.
BATCH_MODE=0

# --- QEMU test lab --------------------------------------------------------
QEMU_IMG_SIZE="4G"            # Capacity of each dummy test drive
QEMU_MEMORY="512M"            # RAM given to each QEMU VM
QEMU_SMP=2                    # vCPUs given to each QEMU VM
QEMU_VGA="std"                # -vga flag: std | virtio | vmware | qxl

# --- UEFI firmware (OVMF) -------------------------------------------------
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS="/usr/share/edk2/x64/OVMF_VARS.4m.fd"

# --- Syslinux / ISOLINUX paths (BIOS boot) --------------------------------
#     Auto-detected at startup by detect_syslinux_paths(); these are the
#     Arch Linux defaults and act as a last-resort fallback.
#     Debian/Ubuntu: /usr/lib/ISOLINUX  and  /usr/lib/syslinux/modules/bios
#     Arch Linux:    /usr/lib/syslinux/bios  (all in one dir)
ISOLINUX_BIN="/usr/lib/syslinux/bios/isolinux.bin"
ISOHDPFX_BIN="/usr/lib/syslinux/bios/isohdpfx.bin"
SYSLINUX_MODULES="/usr/lib/syslinux/bios"

# --- Executables ----------------------------------------------------------
#     Override if a tool lives outside PATH or has a distro-specific name.
PYTHON3="python3"                         # some systems: python
XORRISO="xorriso"
GRUB_MKSTANDALONE="grub-mkstandalone"    # Fedora/RHEL: grub2-mkstandalone
MKDOSFS="mkdosfs"                        # also: mkfs.fat
MKNTFS="mkntfs"                          # from ntfs-3g-progs / ntfsprogs
NTFS3G="ntfs-3g"
QEMU="qemu-system-x86_64"               # may also be: qemu-kvm
QEMU_IMG="qemu-img"
PARTED="parted"
LOSETUP="losetup"
UDEVADM="udevadm"
MMD="mmd"                                # mtools package
MCOPY="mcopy"                            # mtools package
RSYNC="rsync"
MAKE="make"
PKG_INSTALL="apt-get install -y"         # Arch: "pacman -S", Fedora: "dnf install -y"

# ===========================================================================
# PROJECT ROOT  (auto-detected from script location — do not change)
# ===========================================================================
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# DERIVED PATHS
# ---------------------------------------------------------------------------

LEGACY_DIR="$BASE_DIR/legacy"          # Original chntpw ISO lives here
SOURCE_DIR="$BASE_DIR/source"          # Assembled ISO tree — ready to pack
WORK_DIR="$BASE_DIR/work"              # All intermediate build files
RELEASE_DIR="$BASE_DIR/release"        # Final ISO output

ISO_SOURCE="$LEGACY_DIR/chntpw.iso"
ISO_EXTRACT="$WORK_DIR/iso_extract"
INITRD_EXTRACT="$WORK_DIR/initrd_extract"
INITRD_PATCHED="$WORK_DIR/initrd_patched"
KERNEL_DIR="$WORK_DIR/kernel"
EFI_WORK="$WORK_DIR/efi"

KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/${KERNEL_TARBALL}"

QEMU_SATA_IMG="$WORK_DIR/test_sata.qcow2"
QEMU_NVME_IMG="$WORK_DIR/test_nvme.qcow2"

# ---------------------------------------------------------------------------
# COLORS & FORMATTING
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
MAG='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()     { echo -e "${DIM}[$(date +%H:%M:%S)]${NC} $*"; }
info()    { echo -e "${BLU}[INFO]${NC}  $*"; }
success() { echo -e "${GRN}[OK]${NC}    $*"; }
warn()    { echo -e "${YLW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYN}  ──▶  $*${NC}"; }
die()     { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# BOX-DRAWING HELPERS  (total box width = 70 chars)
# ---------------------------------------------------------------------------
_hfill() { printf '═%.0s' $(seq 1 "$1"); }

_box_top()  { echo -e "${BLU}${BOLD}╔$(_hfill 68)╗${NC}"; }
_box_bot()  { echo -e "${BLU}${BOLD}╚$(_hfill 68)╝${NC}"; }
_box_sep()  { echo -e "${BLU}${BOLD}╠$(_hfill 68)╣${NC}"; }
_box_blank() { echo -e "${BLU}${BOLD}║${NC}$(printf '%68s')${BLU}${BOLD}║${NC}"; }

_box_row() {
    printf "${BLU}${BOLD}║${NC}  %-65s ${BLU}${BOLD}║${NC}\n" "$1"
}

_box_sect() {
    local title=" $1 "
    local tlen=${#title}
    local fill=$(( 68 - tlen ))
    local left=$(( fill / 2 ))
    local right=$(( fill - left ))
    printf "${BLU}${BOLD}╠$(_hfill $left)${YLW}${BOLD}${title}${BLU}$(_hfill $right)╣${NC}\n"
}

_box_item() {
    local key="$1"
    local desc="$2"
    local kfmt="[${key}]"
    local pad=$(( 62 - ${#kfmt} - ${#desc} ))
    [[ $pad -lt 0 ]] && pad=0
    printf "${BLU}${BOLD}║${NC}  ${CYN}${BOLD}${kfmt}${NC}  ${desc}%${pad}s  ${BLU}${BOLD}║${NC}\n" ""
}

_box_item_note() {
    local key="$1"
    local desc="$2"
    local note="$3"
    local kfmt="[${key}]"
    local pad=$(( 62 - ${#kfmt} - ${#desc} - ${#note} ))
    [[ $pad -lt 0 ]] && pad=0
    printf "${BLU}${BOLD}║${NC}  ${CYN}${BOLD}${kfmt}${NC}  ${desc}%${pad}s${DIM}${note}${NC}  ${BLU}${BOLD}║${NC}\n" ""
}

banner() {
    echo
    _box_top
    _box_blank
    printf "${BLU}${BOLD}║${NC}  ${BOLD}${CYN}%s%23s${NC} ${BLU}${BOLD}║${NC}\n" \
        "chntpw ISO Modernization Workshop  ·  v2.0" ""
    printf "${BLU}${BOLD}║${NC}  ${DIM}%-65s${NC} ${BLU}${BOLD}║${NC}\n" \
        "Bring a 2014 Windows password tool into the NVMe + UEFI era"
    _box_blank
    _box_bot
    echo
}

pause() { [[ "$BATCH_MODE" -eq 1 ]] && return 0; echo; read -rp "$(echo -e "${DIM}Press Enter to continue...${NC}")"; }

confirm() {
    [[ "$BATCH_MODE" -eq 1 ]] && return 0
    local msg="${1:-Continue?}"
    read -rp "$(echo -e "${YLW}$msg [y/N] ${NC}")" ans
    [[ "${ans,,}" == "y" ]]
}

# ---------------------------------------------------------------------------
# TOOL CHECK
# ---------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."
}

check_tools() {
    step "Checking required tools"
    local missing=()
    local tools=(
        "$XORRISO" cpio gzip find file
        "$GRUB_MKSTANDALONE" "$MKDOSFS" "$MKNTFS"
        "$QEMU" "$QEMU_IMG"
        "$PARTED" "$LOSETUP"
        zcat mount umount
    )
    for t in "${tools[@]}"; do
        if ! command -v "$t" &>/dev/null; then
            missing+=("$t")
            echo -e "  ${RED}MISSING${NC}: $t"
        else
            echo -e "  ${GRN}FOUND${NC}:   $t"
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing tools: ${missing[*]}"
        warn "Install with: sudo apt-get install xorriso grub-efi-amd64-bin dosfstools ntfs-3g qemu-system-x86 parted"
        return 1
    fi
    success "All required tools present"
}

# ---------------------------------------------------------------------------
# STEP 0 — PROJECT SETUP
# ---------------------------------------------------------------------------
setup_project() {
    step "Setting up project directory structure"

    local dirs=(
        "$LEGACY_DIR"
        "$SOURCE_DIR"
        "$WORK_DIR/iso_extract"
        "$WORK_DIR/initrd_extract"
        "$WORK_DIR/initrd_patched"
        "$WORK_DIR/kernel"
        "$WORK_DIR/efi"
        "$RELEASE_DIR"
    )

    for d in "${dirs[@]}"; do
        mkdir -p "$d"
        echo -e "  ${GRN}✓${NC} $d"
    done

    # Move ISO if it lives in the project root
    if [[ -f "$BASE_DIR/chntpw.iso" && ! -f "$ISO_SOURCE" ]]; then
        mv "$BASE_DIR/chntpw.iso" "$ISO_SOURCE"
        success "Moved chntpw.iso → legacy/"
    fi

    [[ -f "$ISO_SOURCE" ]] || warn "legacy/chntpw.iso not found — place the original ISO there."
    success "Project structure ready under: $BASE_DIR"
}

# ---------------------------------------------------------------------------
# STEP 1 — EXTRACT ORIGINAL ISO
# ---------------------------------------------------------------------------
extract_iso() {
    step "Extracting original ISO → $ISO_EXTRACT"

    [[ -f "$ISO_SOURCE" ]] || die "ISO not found: $ISO_SOURCE"

    rm -rf "$ISO_EXTRACT"
    mkdir -p "$ISO_EXTRACT"

    local mnt
    mnt=$(mktemp -d /tmp/chntpw_mnt.XXXXXX)
    trap "umount '$mnt' 2>/dev/null; rmdir '$mnt'" EXIT

    mount -o loop,ro "$ISO_SOURCE" "$mnt"
    cp -a "$mnt"/. "$ISO_EXTRACT"/
    umount "$mnt"
    rmdir "$mnt"
    trap - EXIT

    chmod -R u+w "$ISO_EXTRACT"

    echo -e "\n${BOLD}ISO contents:${NC}"
    find "$ISO_EXTRACT" -type f | sort | while read -r f; do
        printf "  %-40s %s\n" "$(basename "$f")" "$(du -sh "$f" | cut -f1)"
    done

    success "ISO extracted to $ISO_EXTRACT"
}

# ---------------------------------------------------------------------------
# STEP 2 — UNPACK initrd.cgz
# ---------------------------------------------------------------------------
unpack_initrd() {
    step "Unpacking initrd.cgz → $INITRD_EXTRACT"

    local cgz="$ISO_EXTRACT/initrd.cgz"
    [[ -f "$cgz" ]] || die "initrd.cgz not found — run Step 1 first."

    rm -rf "$INITRD_EXTRACT"
    mkdir -p "$INITRD_EXTRACT"

    (cd "$INITRD_EXTRACT" && zcat "$cgz" | cpio -id --quiet)

    echo -e "\n${BOLD}initrd contents (top-level):${NC}"
    find "$INITRD_EXTRACT" -maxdepth 2 -type f | sort | sed "s|$INITRD_EXTRACT/||" | while read -r f; do
        echo "  $f"
    done

    success "initrd unpacked: $(find "$INITRD_EXTRACT" -type f | wc -l) files"
}

# ---------------------------------------------------------------------------
# STEP 3 — PATCH initrd FOR MODERN HARDWARE
# ---------------------------------------------------------------------------
patch_initrd() {
    step "Patching initrd scripts for NVMe + modern hardware"

    [[ -d "$INITRD_EXTRACT" ]] || die "initrd not unpacked — run Step 2 first."

    $RSYNC -a "$INITRD_EXTRACT/" "$INITRD_PATCHED/"

    local dscan="$INITRD_PATCHED/scripts/diskscan.sh"
    cp "$dscan" "${dscan}.orig"

    $PYTHON3 - "$dscan" <<'PYEOF'
import sys, re

path = sys.argv[1]
text = open(path).read()

old = "ls /dev | grep -q cciss && d='/dev/cciss!c?d? /dev/sd? /dev/hd?'"
new = (
    "ls /dev | grep -q cciss && d='/dev/cciss!c?d? /dev/sd? /dev/hd?'\n"
    "# NVMe: add to explicit list so it is scanned alongside CCISS arrays\n"
    "ls /dev | grep -q nvme  && d=\"$d /dev/nvme?n?\""
)
if old not in text:
    print("  Patch A1: pattern not found (already patched?)")
    sys.exit(0)
text = text.replace(old, new)
open(path, 'w').write(text)
marker = 'grep -q nvme'
print(f"  Patch A1 applied: NVMe added to device list [marker present={marker in text}]")
PYEOF

    $PYTHON3 - "$dscan" <<'PYEOF'
import sys

path = sys.argv[1]
text = open(path).read()

old_extract = "d=`basename $dev | sed 's/[0-9]//g'`"

new_extract = (
    "d=`basename $dev`\n"
    "  case \"$d\" in\n"
    "    nvme*) d=`echo \"$d\" | sed 's/p[0-9]*$//'` ;;\n"
    "    *)     d=`echo \"$d\" | sed 's/[0-9]*$//'`  ;;\n"
    "  esac"
)

count = text.count(old_extract)
text = text.replace(old_extract, new_extract)
open(path, 'w').write(text)
print(f"  Patch A2 applied: NVMe-safe disk-name extraction ({count} occurrence(s))")
PYEOF

    local fwin="$INITRD_PATCHED/scripts/findwin.sh"
    cp "$fwin" "${fwin}.orig"

    $PYTHON3 - "$fwin" <<'PYEOF'
import sys

path = sys.argv[1]
text = open(path).read()

old_awk = "  !/(sr|fd)[0-9]$/ && /[0-9]$/ {"
new_awk = (
    "  !/(sr|fd)[0-9]$/ && /[0-9]$/ && !/(nvme[0-9]+n[0-9]+)$/ {"
)

text = text.replace(old_awk, new_awk)
open(path, 'w').write(text)
print("  Patch B applied: NVMe whole-disk excluded from mount-scan")
PYEOF

    # --- Patch C: stage2 — wait for NVMe async probe before mdev -s ---
    local stage2="$INITRD_PATCHED/scripts/stage2"
    if [[ -f "$stage2" ]]; then
        cp "$stage2" "${stage2}.orig"
        $PYTHON3 - "$stage2" <<'PYEOF'
import sys

path = sys.argv[1]
text = open(path).read()

wait_loop = (
    "# Wait up to 10 s for NVMe/SATA async probe to settle\n"
    "for i in 1 2 3 4 5 6 7 8 9 10; do\n"
    "    grep -qE '(sd[a-z]|nvme[0-9]|vd[a-z]|hd[a-z])' /proc/partitions && break\n"
    "    sleep 1\n"
    "done\n"
    "# Reset VT consoles to clean 80x25 state\n"
    "for vt in 1 2 3 4; do printf '\\033[2J' > /dev/tty${vt} 2>/dev/null || true; done\n"
)

old = 'mdev -s'
if old not in text:
    print("  Patch C: 'mdev -s' not found in stage2 (already patched?)")
    sys.exit(0)

text = text.replace(old, wait_loop + old, 1)
open(path, 'w').write(text)
print("  Patch C applied: NVMe async wait loop inserted before first mdev -s")
PYEOF
    else
        warn "scripts/stage2 not found — skipping Patch C."
    fi

    # --- Patch D: prepdriver.sh — guard mv * on empty drivers dir ---
    local prepdrv="$INITRD_PATCHED/scripts/prepdriver.sh"
    if [[ -f "$prepdrv" ]]; then
        cp "$prepdrv" "${prepdrv}.orig"
        $PYTHON3 - "$prepdrv" <<'PYEOF'
import sys

path = sys.argv[1]
text = open(path).read()

patterns = [
    ("mv * $MODDIR",    "ls * 2>/dev/null && mv * $MODDIR || true"),
    ('mv * "$MODDIR"',  'ls * 2>/dev/null && mv * "$MODDIR" || true'),
]

applied = 0
for old, new in patterns:
    if old in text:
        text = text.replace(old, new)
        applied += 1

if applied == 0:
    print("  Patch D: mv pattern not found in prepdriver.sh (already patched?)")
else:
    open(path, 'w').write(text)
    print(f"  Patch D applied: empty-drivers guard added ({applied} replacement(s))")
PYEOF
    else
        warn "scripts/prepdriver.sh not found — skipping Patch D."
    fi

    local init_file="$INITRD_PATCHED/init"
    cp "$init_file" "${init_file}.orig"
    sed -i 's|/bin/busybox echo "### Booting ntpasswd"|/bin/busybox echo "### Booting ntpasswd (chntpw-modern kernel)"|' "$init_file"

    touch "$INITRD_PATCHED/dev/.nvme_placeholder" 2>/dev/null || true

    echo
    echo -e "${BOLD}Patch summary:${NC}"
    diff -u "${dscan}.orig" "$dscan" | grep -E "^\+[^+]|^-[^-]" | head -20 || true
    echo "---"
    diff -u "${fwin}.orig" "$fwin" | grep -E "^\+[^+]|^-[^-]" | head -20 || true
    echo "---"
    [[ -f "${stage2}.orig" ]] && diff -u "${stage2}.orig" "$stage2" | grep -E "^\+[^+]|^-[^-]" | head -20 || true
    echo "---"
    [[ -f "${prepdrv}.orig" ]] && diff -u "${prepdrv}.orig" "$prepdrv" | grep -E "^\+[^+]|^-[^-]" | head -20 || true

    success "initrd patched in $INITRD_PATCHED"
}

# ---------------------------------------------------------------------------
# STEP 4 — REPACK initrd.cgz
# ---------------------------------------------------------------------------
repack_initrd() {
    step "Repacking patched initrd → work/initrd.cgz"

    [[ -d "$INITRD_PATCHED" ]] || die "Patched initrd not found — run Step 3 first."

    local out_cgz="$WORK_DIR/initrd.cgz"

    (
        cd "$INITRD_PATCHED"
        find . | sort | cpio -o -H newc --quiet | gzip -9 > "$out_cgz"
    )

    local orig_size new_size
    orig_size=$(stat -c%s "$ISO_EXTRACT/initrd.cgz" 2>/dev/null || echo 0)
    new_size=$(stat -c%s "$out_cgz")

    printf "  Original size: %'d bytes\n" "$orig_size"
    printf "  New size:      %'d bytes\n" "$new_size"

    success "New initrd.cgz written: $out_cgz"
}

# ---------------------------------------------------------------------------
# STEP 5 — BUILD STUB scsi.cgz
# ---------------------------------------------------------------------------
build_stub_scsi() {
    step "Building stub scsi.cgz (empty drivers dir for monolithic kernel)"

    local stub_dir
    stub_dir=$(mktemp -d /tmp/scsi_stub.XXXXXX)
    mkdir -p "$stub_dir/drivers"

    local out_cgz="$WORK_DIR/scsi.cgz"
    (cd "$stub_dir" && find . | cpio -o -H newc --quiet | gzip -9 > "$out_cgz")
    rm -rf "$stub_dir"

    success "Stub scsi.cgz written: $out_cgz ($(stat -c%s "$out_cgz") bytes)"
}

# ---------------------------------------------------------------------------
# STEP 6 — KERNEL CONFIGURATION FILE
# ---------------------------------------------------------------------------
generate_kernel_config() {
    step "Generating Linux ${KERNEL_VERSION} kernel .config"

    # Warn if KERNEL_VERSION is outside the tested range
    local _major="${KERNEL_VERSION%%.*}"
    if (( _major < 6 )); then
        warn "Kernel config is designed for 6.x and 7.x — $KERNEL_VERSION may not build correctly."
        warn "Continuing anyway; expect make errors or missing drivers."
    fi

    mkdir -p "$KERNEL_DIR"
    local cfg="$KERNEL_DIR/kernel.config"

    cat > "$cfg" <<'KCONFIG'
# ===================================================================
# chntpw-modern kernel configuration — Linux 6.x / 7.x
# Monolithic (no modules), maximum storage hardware compatibility.
# Target: x86_64 with 32-bit IA32 userspace (original chntpw tools).
#
# Compatibility notes:
#   CONFIG_EFI_VARS          removed in 6.0  → use CONFIG_EFIVAR_FS instead
#   CONFIG_X86_X32_ABI       removed in 6.7  → kept as =n for 6.0-6.6
#   CONFIG_NTFS3_LZX_XPRESS  always-on in 6+ → kept for 5.x compat, ignored
#   CONFIG_ATA_VERBOSE_ERROR  always-on in 6+ → kept, ignored on newer builds
# ===================================================================

# --- Architecture ---
CONFIG_64BIT=y
CONFIG_X86_64=y
CONFIG_SMP=y
CONFIG_NR_CPUS=32
CONFIG_HZ_250=y

# --- No loadable modules — all drivers built into the image ---
CONFIG_MODULES=n

# --- 32-bit compatibility for original chntpw/busybox binaries ---
CONFIG_IA32_EMULATION=y
CONFIG_X86_X32_ABI=n          # Removed in 6.7; explicit =n needed for 6.0-6.6

# ---------------------------------------------------------------
# BLOCK LAYER
# ---------------------------------------------------------------
CONFIG_BLOCK=y
CONFIG_BLK_DEV=y
CONFIG_BLK_DEV_RAM=y
CONFIG_BLK_DEV_RAM_COUNT=4
CONFIG_BLK_DEV_RAM_SIZE=65536
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_RD_BZIP2=y
CONFIG_RD_XZ=y

# ---------------------------------------------------------------
# SCSI CORE
# ---------------------------------------------------------------
CONFIG_SCSI=y
CONFIG_SCSI_COMMON=y
CONFIG_SCSI_DMA=y
CONFIG_SCSI_PROC_FS=y
CONFIG_BLK_DEV_SD=y
CONFIG_BLK_DEV_SR=y
CONFIG_CHR_DEV_SG=y
CONFIG_SCSI_SCAN_ASYNC=n
CONFIG_SCSI_LOWLEVEL=y

# --- Enterprise SCSI / SAS / RAID ---
CONFIG_SCSI_AACRAID=y
CONFIG_SCSI_AIC7XXX=y
CONFIG_SCSI_AIC79XX=y
CONFIG_SCSI_HPTIOP=y
CONFIG_SCSI_3W_9XXX=y
CONFIG_SCSI_3W_SAS=y
CONFIG_MEGARAID_SAS=y
CONFIG_SCSI_MPT3SAS=y
CONFIG_SCSI_MVSAS=y
CONFIG_SCSI_ISCI=y
CONFIG_SCSI_SMARTPQI=y
CONFIG_SCSI_HISI_SAS=y       # ARM-only — silently skipped on x86_64
CONFIG_SCSI_VIRTIO=y

# ---------------------------------------------------------------
# SATA / AHCI
# ---------------------------------------------------------------
CONFIG_ATA=y
CONFIG_ATA_VERBOSE_ERROR=y
CONFIG_ATA_ACPI=y
CONFIG_ATA_BMDMA=y
CONFIG_ATA_SFF=y
CONFIG_SATA_HOST=y
CONFIG_SATA_AHCI=y
CONFIG_SATA_AHCI_PLATFORM=y
CONFIG_ATA_PIIX=y
CONFIG_ATA_GENERIC=y
CONFIG_SATA_SIS=y
CONFIG_SATA_VIA=y
CONFIG_SATA_NFORCE=y
CONFIG_SATA_MV=y
CONFIG_SATA_NV=y
CONFIG_SATA_PROMISE=y
CONFIG_SATA_SIL=y
CONFIG_SATA_SIL24=y
CONFIG_SATA_SVW=y
CONFIG_SATA_ULI=y
CONFIG_SATA_SX4=y
CONFIG_SATA_INIC162X=y
CONFIG_SATA_ACARD_AHCI=y

# ---------------------------------------------------------------
# PATA / IDE  (legacy hardware)
# ---------------------------------------------------------------
CONFIG_PATA_ACPI=y
CONFIG_PATA_ALI=y
CONFIG_PATA_AMD=y
CONFIG_PATA_ARTOP=y
CONFIG_PATA_ATIIXP=y
CONFIG_PATA_CMD64X=y
CONFIG_PATA_CS5520=y
CONFIG_PATA_CS5530=y
CONFIG_PATA_CS5535=y
CONFIG_PATA_CS5536=y
CONFIG_PATA_EFAR=y
CONFIG_PATA_HPT366=y
CONFIG_PATA_HPT37X=y
CONFIG_PATA_HPT3X2N=y
CONFIG_PATA_HPT3X3=y
CONFIG_PATA_IT8213=y
CONFIG_PATA_IT821X=y
CONFIG_PATA_JMICRON=y
CONFIG_PATA_MARVELL=y
CONFIG_PATA_MPIIX=y
CONFIG_PATA_NETCELL=y
CONFIG_PATA_OLDPIIX=y
CONFIG_PATA_OPTIDMA=y
CONFIG_PATA_PDC_OLD=y
CONFIG_PATA_RDC=y
CONFIG_PATA_SCH=y
CONFIG_PATA_SERVERWORKS=y
CONFIG_PATA_SIL680=y
CONFIG_PATA_SIS=y
CONFIG_PATA_TOSHIBA=y
CONFIG_PATA_TRIFLEX=y
CONFIG_PATA_VIA=y
CONFIG_PATA_WINBOND=y

# ---------------------------------------------------------------
# NVMe  +  Intel VMD (Volume Management Device)
# ---------------------------------------------------------------
# CONFIG_VMD: Intel 11th Gen+ platforms put NVMe behind a VMD bridge.
#   lspci shows the drive under domain 10000: instead of 0000:.
#   Without this driver the bridge is invisible, taking the NVMe with it.
#   AMD platforms do NOT use VMD; their NVMe is plain PCIe (no bridge needed).
CONFIG_VMD=y
CONFIG_NVME_CORE=y
CONFIG_BLK_DEV_NVME=y
# MULTIPATH: harmless on single-drive systems; required for enterprise
#   dual-port NVMe or NVMe-oF configurations.
CONFIG_NVME_MULTIPATH=y
# HWMON: exposes drive temperature; also causes the driver to check and
#   sanitise APST (Autonomous Power State Transitions) settings at init,
#   which prevents DRAM-less drives (WD SN350, SK Hynix BC901, etc.) from
#   dropping into unrecoverable deep power states during boot.
CONFIG_NVME_HWMON=y

# ---------------------------------------------------------------
# Thunderbolt / USB4  (external NVMe docks, TB enclosures)
# ---------------------------------------------------------------
# Without these, NVMe drives connected via Thunderbolt dock or enclosure
# are invisible — the TB host never enumerates its downstream PCIe tree.
# Covers: TB1/2/3 (CONFIG_THUNDERBOLT) and TB4/USB4 (CONFIG_USB4).
CONFIG_THUNDERBOLT=y
CONFIG_USB4=y

# ---------------------------------------------------------------
# USB
# ---------------------------------------------------------------
CONFIG_USB_SUPPORT=y
CONFIG_USB=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_OHCI_HCD=y
CONFIG_USB_UHCI_HCD=y
CONFIG_USB_STORAGE=y
CONFIG_USB_UAS=y

# ---------------------------------------------------------------
# VirtIO  (QEMU/KVM/cloud VMs)
# ---------------------------------------------------------------
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_SCSI=y

# ---------------------------------------------------------------
# MMC / SD card  +  eMMC (budget/tablet Windows machines)
# ---------------------------------------------------------------
# SDHCI covers most SD/eMMC host controllers.
# MMC_DW (DesignWare) is the eMMC controller on Intel BayTrail / Cherry Trail
#   SoCs used in cheap Windows tablets and 2-in-1s (Surface 3, ASUS T100, etc.)
#   Without MMC_DW_PCI those machines have no visible storage at all.
CONFIG_MMC=y
CONFIG_MMC_BLOCK=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_PCI=y
CONFIG_MMC_SDHCI_ACPI=y
CONFIG_MMC_RICOH_MMC=y
CONFIG_MMC_DW=y
CONFIG_MMC_DW_PCI=y

# ---------------------------------------------------------------
# FILESYSTEMS
# ---------------------------------------------------------------
CONFIG_EXT2_FS=y
CONFIG_EXT3_FS=y
CONFIG_EXT4_FS=y
CONFIG_VFAT_FS=y
CONFIG_FAT_FS=y
CONFIG_MSDOS_FS=y
CONFIG_ISO9660_FS=y
CONFIG_JOLIET=y
CONFIG_ZISOFS=y
CONFIG_UDF_FS=y
CONFIG_FUSE_FS=y
CONFIG_NTFS3_FS=y
CONFIG_NTFS3_LZX_XPRESS=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y

# ---------------------------------------------------------------
# EFI / UEFI
# ---------------------------------------------------------------
CONFIG_EFI=y
CONFIG_EFI_STUB=y
# CONFIG_EFI_VARS is NOT set — removed in Linux 6.0; use EFIVAR_FS below
CONFIG_EFI_RUNTIME_WRAPPERS=y
CONFIG_EFIVAR_FS=y

# ---------------------------------------------------------------
# DISPLAY / FRAMEBUFFER
# ---------------------------------------------------------------
CONFIG_FB=y
CONFIG_FB_EFI=y
CONFIG_FB_VESA=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
CONFIG_CONSOLE_TRANSLATIONS=y
CONFIG_DUMMY_CONSOLE=y

# ---------------------------------------------------------------
# PCI / PCIe
# ---------------------------------------------------------------
CONFIG_PCI=y
CONFIG_PCIEPORTBUS=y
CONFIG_PCIEASPM=y
CONFIG_PCI_MSI=y
CONFIG_PCI_QUIRKS=y
CONFIG_HOTPLUG_PCI=y
CONFIG_HOTPLUG_PCI_PCIE=y
CONFIG_HOTPLUG_PCI_ACPI=y

# ---------------------------------------------------------------
# POWER / ACPI
# ---------------------------------------------------------------
CONFIG_ACPI=y
CONFIG_PM=y
CONFIG_ACPI_AC=y
CONFIG_ACPI_BATTERY=y
CONFIG_ACPI_BUTTON=y
CONFIG_ACPI_VIDEO=y

# ---------------------------------------------------------------
# SERIAL / CONSOLE
# ---------------------------------------------------------------
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y

# ---------------------------------------------------------------
# CRYPTO
# ---------------------------------------------------------------
CONFIG_CRYPTO=y
CONFIG_CRYPTO_CRC32C=y
CONFIG_CRYPTO_CRC32=y
CONFIG_CRYPTO_AES=y
CONFIG_CRYPTO_SHA256=y
CONFIG_CRYPTO_SHA512=y
CONFIG_CRYPTO_MD5=y

# ---------------------------------------------------------------
# MISC
# ---------------------------------------------------------------
CONFIG_PRINTK=y
CONFIG_EARLY_PRINTK=y
CONFIG_PANIC_ON_OOPS=n
CONFIG_STACKTRACE=n
CONFIG_KALLSYMS=n
CONFIG_DEBUG_KERNEL=n
KCONFIG

    echo -e "\n${BOLD}Key storage drivers in config:${NC}"
    grep -E "^CONFIG_(BLK_DEV_NVME|BLK_DEV_SD|SATA_AHCI|ATA_PIIX|USB_STORAGE|SCSI=|MEGARAID|MPT3SAS|EFI_STUB|IA32_EMUL|MODULES)=" "$cfg"

    success "Kernel config written: $cfg  ($(wc -l < "$cfg") lines)"
    info "Run Step 8 (download) then Step 9 (compile) to build the new kernel."
}

# ---------------------------------------------------------------------------
# STEP 7 — DOWNLOAD KERNEL SOURCE
# ---------------------------------------------------------------------------
download_kernel() {
    step "Downloading Linux kernel source"

    mkdir -p "$KERNEL_DIR"

    local _ver=""
    if [[ "$BATCH_MODE" -eq 0 ]]; then
        echo
        read -rp "$(echo -e "${CYN}Kernel version to download [${KERNEL_VERSION}]: ${NC}")" _ver
    fi
    [[ -z "$_ver" ]] && _ver="$KERNEL_VERSION"

    if ! echo "$_ver" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        die "Invalid version '$_ver' — expected X.Y or X.Y.Z (e.g. 7.1 or 6.12.5)"
    fi

    local _vmajor="${_ver%%.*}"
    if (( _vmajor < 6 )); then
        die "Linux ${_vmajor}.x is not supported. This script builds for 6.x and 7.x only."
    fi

    KERNEL_VERSION="$_ver"
    KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
    local major="${KERNEL_VERSION%%.*}"
    KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/${KERNEL_TARBALL}"

    local tarball="$KERNEL_DIR/$KERNEL_TARBALL"

    if [[ -f "$tarball" ]]; then
        info "Tarball already present: $tarball"
    else
        info "Downloading from kernel.org …"
        info "URL: $KERNEL_URL"
        if command -v wget &>/dev/null; then
            wget -c -O "$tarball" "$KERNEL_URL"
        elif command -v curl &>/dev/null; then
            curl -L -C - -o "$tarball" "$KERNEL_URL"
        else
            die "Neither wget nor curl found. Install one first."
        fi
    fi

    if [[ -d "$KERNEL_DIR/linux-${KERNEL_VERSION}" ]]; then
        info "Source already extracted."
    else
        step "Extracting kernel source (this takes a few minutes)…"
        tar -xf "$tarball" -C "$KERNEL_DIR"
        success "Extracted to $KERNEL_DIR/linux-${KERNEL_VERSION}/"
    fi
}

# ---------------------------------------------------------------------------
# STEP 8 — COMPILE KERNEL
# ---------------------------------------------------------------------------
compile_kernel() {
    step "Compiling Linux ${KERNEL_VERSION}"

    local src="$KERNEL_DIR/linux-${KERNEL_VERSION}"
    [[ -d "$src" ]] || die "Kernel source not found — run Step 7 first."

    info "Checking build dependencies …"
    local _missing=()
    for _t in gcc flex bison bc pahole; do
        command -v "$_t" &>/dev/null || _missing+=("$_t")
    done
    if [[ ${#_missing[@]} -eq 0 ]]; then
        success "Build dependencies already present."
    else
        info "Missing: ${_missing[*]} — attempting install …"
        $PKG_INSTALL \
            build-essential libssl-dev libelf-dev \
            flex bison bc pahole \
            libncurses-dev dwarves \
            > /dev/null 2>&1 \
            || warn "Auto-install failed. Install manually: gcc flex bison bc pahole libssl-dev libelf-dev libncurses-dev dwarves"
    fi

    local cfg="$KERNEL_DIR/kernel.config"
    [[ -f "$cfg" ]] || die "kernel.config not found — run Step 6 first."
    cp "$cfg" "$src/.config"

    info "Running 'make olddefconfig' to fill in new symbols …"
    $MAKE -C "$src" olddefconfig 2>&1 | tail -5

    local ncpus
    ncpus=$(nproc)
    info "Building with $ncpus parallel jobs … (this takes 15-60 minutes)"
    info "Logs: $KERNEL_DIR/build.log"

    $MAKE -C "$src" -j"$ncpus" bzImage 2>&1 | tee "$KERNEL_DIR/build.log" | tail -20

    local bzimage="$src/arch/x86/boot/bzImage"
    [[ -f "$bzimage" ]] || die "Build failed — check $KERNEL_DIR/build.log"

    cp "$bzimage" "$WORK_DIR/vmlinuz-modern"
    success "Kernel built: $WORK_DIR/vmlinuz-modern  ($(du -sh "$WORK_DIR/vmlinuz-modern" | cut -f1))"
}

# ---------------------------------------------------------------------------
# STEP 9 — ASSEMBLE SOURCE TREE (ready to pack)
# ---------------------------------------------------------------------------
assemble_iso_tree() {
    step "Assembling source/ tree → $SOURCE_DIR"

    [[ -f "$ISO_EXTRACT/initrd.cgz" ]] || die "ISO not extracted — run Step 1 first."

    local vmlinuz_src initrd_src scsi_src

    if [[ -f "$WORK_DIR/vmlinuz-modern" ]]; then
        vmlinuz_src="$WORK_DIR/vmlinuz-modern"
        info "Using compiled modern kernel: $vmlinuz_src"
    else
        vmlinuz_src="$ISO_EXTRACT/vmlinuz"
        warn "Modern kernel not compiled — using ORIGINAL kernel (NVMe will NOT work)."
        warn "Run Steps 6-8 to compile the new kernel, then re-run this step."
    fi

    if [[ -f "$WORK_DIR/initrd.cgz" ]]; then
        initrd_src="$WORK_DIR/initrd.cgz"
        info "Using patched initrd: $initrd_src"
    else
        initrd_src="$ISO_EXTRACT/initrd.cgz"
        warn "Patched initrd not found — using ORIGINAL (no NVMe patches)."
    fi

    if [[ -f "$WORK_DIR/scsi.cgz" ]]; then
        scsi_src="$WORK_DIR/scsi.cgz"
        info "Using stub scsi.cgz (monolithic kernel)"
    else
        scsi_src="$ISO_EXTRACT/scsi.cgz"
        warn "Using ORIGINAL scsi.cgz (old modules, may cause harmless modprobe errors)."
    fi

    rm -rf "$SOURCE_DIR"
    mkdir -p "$SOURCE_DIR"/{isolinux,EFI/BOOT,boot/grub}

    # --- BIOS boot: isolinux ---
    cp "$ISOLINUX_BIN"                         "$SOURCE_DIR/isolinux/isolinux.bin"
    cp "$SYSLINUX_MODULES/ldlinux.c32"         "$SOURCE_DIR/isolinux/"
    cp "$SYSLINUX_MODULES/menu.c32"            "$SOURCE_DIR/isolinux/"
    cp "$SYSLINUX_MODULES/libutil.c32"         "$SOURCE_DIR/isolinux/"
    cp "$SYSLINUX_MODULES/vesamenu.c32"        "$SOURCE_DIR/isolinux/" 2>/dev/null || true

    cp "$vmlinuz_src"   "$SOURCE_DIR/isolinux/vmlinuz"
    cp "$initrd_src"    "$SOURCE_DIR/isolinux/initrd.cgz"
    cp "$scsi_src"      "$SOURCE_DIR/isolinux/scsi.cgz"

    for f in boot.msg readme.txt syslinux.exe; do
        [[ -f "$ISO_EXTRACT/$f" ]] && cp "$ISO_EXTRACT/$f" "$SOURCE_DIR/isolinux/" || true
    done
    [[ -f "$ISO_EXTRACT/readme.txt" ]] && cp "$ISO_EXTRACT/readme.txt" "$SOURCE_DIR/"

    [[ -f "$ISO_EXTRACT/thisiscd" ]] && cp "$ISO_EXTRACT/thisiscd" "$SOURCE_DIR/" || touch "$SOURCE_DIR/thisiscd"

    # --- isolinux.cfg (BIOS menu) ---
    cat > "$SOURCE_DIR/isolinux/isolinux.cfg" <<'ISOCFG'
UI menu.c32
PROMPT 0
TIMEOUT 100
DEFAULT boot

MENU TITLE chntpw Modern — NT Password & Registry Editor

LABEL boot
  MENU LABEL ^Boot chntpw (NVMe + SATA + Legacy BIOS)
  KERNEL vmlinuz
  APPEND rw vga=normal initrd=initrd.cgz,scsi.cgz loglevel=1 quiet

LABEL verbose
  MENU LABEL Boot chntpw ^Verbose (debug output)
  KERNEL vmlinuz
  APPEND rw vga=normal initrd=initrd.cgz,scsi.cgz loglevel=7

LABEL nousb
  MENU LABEL Boot chntpw (^No USB)
  KERNEL vmlinuz
  APPEND rw vga=normal initrd=initrd.cgz,scsi.cgz loglevel=1 nousb quiet

LABEL serial
  MENU LABEL Boot chntpw (^Serial console ttyS0 115200)
  KERNEL vmlinuz
  APPEND rw vga=normal initrd=initrd.cgz,scsi.cgz loglevel=1 console=ttyS0,115200n8 quiet
ISOCFG

    # --- GRUB2 config (UEFI) ---
    cat > "$SOURCE_DIR/boot/grub/grub.cfg" <<'GRUBCFG'
set timeout=10
set default=0

insmod all_video
insmod gzio
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660

if search --no-floppy --label --set=isoroot CHNTPW_MODERN; then
    true
else
    search --no-floppy --file --set=isoroot /isolinux/vmlinuz
fi

menuentry "chntpw Modern -- NT Password & Registry Editor (NVMe + UEFI)" {
    echo "Loading kernel..."
    linux  ($isoroot)/isolinux/vmlinuz rw vga=normal loglevel=1 quiet
    echo "Loading initrd..."
    initrd ($isoroot)/isolinux/initrd.cgz ($isoroot)/isolinux/scsi.cgz
}

menuentry "chntpw Modern -- Verbose mode (debug)" {
    linux  ($isoroot)/isolinux/vmlinuz rw vga=normal loglevel=7
    initrd ($isoroot)/isolinux/initrd.cgz ($isoroot)/isolinux/scsi.cgz
}

menuentry "chntpw Modern -- No USB" {
    linux  ($isoroot)/isolinux/vmlinuz rw vga=normal loglevel=1 nousb quiet
    initrd ($isoroot)/isolinux/initrd.cgz ($isoroot)/isolinux/scsi.cgz
}

menuentry "chntpw Modern -- Serial console (ttyS0 115200)" {
    linux  ($isoroot)/isolinux/vmlinuz rw vga=normal loglevel=1 console=ttyS0,115200n8 quiet
    initrd ($isoroot)/isolinux/initrd.cgz ($isoroot)/isolinux/scsi.cgz
}
GRUBCFG

    success "source/ tree assembled at $SOURCE_DIR"
}

# ---------------------------------------------------------------------------
# STEP 10 — BUILD EFI BOOT IMAGE
# ---------------------------------------------------------------------------
build_efi_image() {
    step "Building EFI boot image (efiboot.img)"

    [[ -d "$SOURCE_DIR/boot/grub" ]] || die "source/ tree not assembled — run Step 9 first."

    local embed_cfg="$EFI_WORK/grub-embedded.cfg"
    mkdir -p "$EFI_WORK"

    cat > "$embed_cfg" <<EMBCFG
set timeout=10
set default=0

terminal_input  console
terminal_output console

insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod gzio

if search --no-floppy --label --set=isoroot CHNTPW_MODERN; then
    true
else
    search --no-floppy --file --set=isoroot /isolinux/vmlinuz
fi

menuentry "chntpw Modern -- NT Password & Registry Editor (NVMe + UEFI)" {
    echo "Loading kernel..."
    linux  (\$isoroot)/isolinux/vmlinuz rw vga=normal loglevel=1 quiet
    echo "Loading initrd..."
    initrd (\$isoroot)/isolinux/initrd.cgz (\$isoroot)/isolinux/scsi.cgz
}

menuentry "chntpw Modern -- Verbose mode (debug)" {
    linux  (\$isoroot)/isolinux/vmlinuz rw vga=normal loglevel=7
    initrd (\$isoroot)/isolinux/initrd.cgz (\$isoroot)/isolinux/scsi.cgz
}

menuentry "chntpw Modern -- No USB" {
    linux  (\$isoroot)/isolinux/vmlinuz rw vga=normal loglevel=1 nousb quiet
    initrd (\$isoroot)/isolinux/initrd.cgz (\$isoroot)/isolinux/scsi.cgz
}

menuentry "chntpw Modern -- Serial console (ttyS0 115200)" {
    linux  (\$isoroot)/isolinux/vmlinuz rw vga=normal loglevel=1 console=ttyS0,115200n8 quiet
    initrd (\$isoroot)/isolinux/initrd.cgz (\$isoroot)/isolinux/scsi.cgz
}
EMBCFG

    local efi_bin="$SOURCE_DIR/EFI/BOOT/BOOTX64.EFI"
    info "Building BOOTX64.EFI with $GRUB_MKSTANDALONE …"

    $GRUB_MKSTANDALONE \
        --format=x86_64-efi \
        --output="$efi_bin" \
        --locales="" \
        --fonts="unicode" \
        "boot/grub/grub.cfg=$embed_cfg"

    success "BOOTX64.EFI created ($(du -sh "$efi_bin" | cut -f1))"

    local efi_img="$SOURCE_DIR/EFI/efiboot.img"
    local efi_size=$EFI_IMG_SIZE

    info "Creating ${efi_size}MiB FAT16 image: $efi_img"
    dd if=/dev/zero of="$efi_img" bs=1M count="$efi_size" status=none
    $MKDOSFS -F 16 "$efi_img" > /dev/null

    $MMD   -i "$efi_img" ::EFI
    $MMD   -i "$efi_img" ::EFI/BOOT
    $MMD   -i "$efi_img" ::boot
    $MMD   -i "$efi_img" ::boot/grub
    $MCOPY -i "$efi_img" "$efi_bin"                         ::EFI/BOOT/BOOTX64.EFI
    $MCOPY -i "$efi_img" "$SOURCE_DIR/boot/grub/grub.cfg"  ::boot/grub/grub.cfg

    success "EFI boot image: $efi_img"
}

# ---------------------------------------------------------------------------
# STEP 11 — BUILD FINAL HYBRID ISO
# ---------------------------------------------------------------------------
build_final_iso() {
    step "Building final hybrid ISO → release/$ISO_OUTPUT_NAME"

    [[ -f "$SOURCE_DIR/EFI/efiboot.img" ]]       || die "EFI image missing — run Step 10 first."
    [[ -f "$SOURCE_DIR/isolinux/isolinux.bin" ]]  || die "isolinux.bin missing — run Step 9 first."

    local out_iso="$RELEASE_DIR/$ISO_OUTPUT_NAME"
    mkdir -p "$RELEASE_DIR"

    $XORRISO -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -joliet \
        -joliet-long \
        -rational-rock \
        -volid "$ISO_VOLID" \
        -preparer "$ISO_PREPARER" \
        -publisher "$ISO_PUBLISHER" \
        -eltorito-boot       isolinux/isolinux.bin \
        -eltorito-catalog    isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-alt-boot \
        -e                   EFI/efiboot.img \
        -no-emul-boot \
        -isohybrid-mbr       "$ISOHDPFX_BIN" \
        -isohybrid-gpt-basdat \
        -o "$out_iso" \
        "$SOURCE_DIR"

    local size
    size=$(du -sh "$out_iso" | cut -f1)
    success "Final ISO built: $out_iso  ($size)"
}

# ---------------------------------------------------------------------------
# STEP 12 — EXPORT ARTIFACTS (kernel config to project root)
# ---------------------------------------------------------------------------
sync_artifacts() {
    step "Exporting artifacts to project root"

    if [[ -f "$KERNEL_DIR/kernel.config" ]]; then
        cp "$KERNEL_DIR/kernel.config" "$BASE_DIR/kernel.config"
        success "kernel.config → $BASE_DIR/"
    else
        warn "kernel.config not found — run Step 6 first."
    fi

    echo
    echo -e "${BOLD}Build summary:${NC}"
    [[ -f "$WORK_DIR/vmlinuz-modern"           ]] && echo -e "  ${GRN}✓${NC} vmlinuz-modern        $(du -sh "$WORK_DIR/vmlinuz-modern" | cut -f1)" \
                                                  || echo -e "  ${YLW}-${NC} vmlinuz-modern        (not built)"
    [[ -f "$WORK_DIR/initrd.cgz"               ]] && echo -e "  ${GRN}✓${NC} initrd.cgz            $(du -sh "$WORK_DIR/initrd.cgz" | cut -f1)" \
                                                  || echo -e "  ${YLW}-${NC} initrd.cgz            (not built)"
    [[ -f "$SOURCE_DIR/isolinux/vmlinuz"       ]] && echo -e "  ${GRN}✓${NC} source/ tree          ready" \
                                                  || echo -e "  ${YLW}-${NC} source/ tree          (not assembled)"
    [[ -f "$RELEASE_DIR/$ISO_OUTPUT_NAME"      ]] && echo -e "  ${GRN}✓${NC} $ISO_OUTPUT_NAME   $(du -sh "$RELEASE_DIR/$ISO_OUTPUT_NAME" | cut -f1)" \
                                                  || echo -e "  ${YLW}-${NC} $ISO_OUTPUT_NAME   (not built)"

    success "Done. Commit the project root to version-control."
}

# ---------------------------------------------------------------------------
# QEMU TESTS — Helper
# ---------------------------------------------------------------------------
_ovmf_vars() {
    local tmp="$WORK_DIR/ovmf_vars_runtime.fd"
    if [[ ! -f "$tmp" ]]; then
        cp "$OVMF_VARS" "$tmp"
    fi
    echo "$tmp"
}

# ---------------------------------------------------------------------------
# QEMU TEST — Create dummy NTFS drives
# ---------------------------------------------------------------------------
qemu_create_drives() {
    step "Creating QEMU test drives (dummy NTFS, mimics Windows installation)"

    local iso="$RELEASE_DIR/$ISO_OUTPUT_NAME"
    if [[ ! -f "$iso" ]]; then
        warn "ISO not found at $iso — some tests will boot from original ISO."
        iso="$ISO_SOURCE"
    fi

    for img_path in "$QEMU_SATA_IMG" "$QEMU_NVME_IMG"; do
        local label
        label=$(basename "${img_path%.qcow2}")

        if [[ -f "$img_path" ]]; then
            info "Drive already exists: $img_path"
            continue
        fi

        step "Creating $label ($QEMU_IMG_SIZE raw qcow2)"
        $QEMU_IMG create -f qcow2 "$img_path" "$QEMU_IMG_SIZE"

        local raw_tmp
        raw_tmp=$(mktemp /tmp/chntpw_raw.XXXXXX)

        $QEMU_IMG convert -f qcow2 -O raw "$img_path" "$raw_tmp"

        $PARTED -s "$raw_tmp" mklabel gpt
        $PARTED -s "$raw_tmp" mkpart "EFI"     fat32  1MiB  101MiB
        $PARTED -s "$raw_tmp" mkpart "Windows" ntfs  101MiB  100%
        $PARTED -s "$raw_tmp" set 1 esp on

        local loop
        loop=$($LOSETUP --find --show --partscan "$raw_tmp")

        sleep 1
        $UDEVADM settle 2>/dev/null || true

        $MKDOSFS -F 32 "${loop}p1" > /dev/null 2>&1 || warn "FAT format failed (${loop}p1)"
        $MKNTFS  -F -Q "${loop}p2" > /dev/null 2>&1 || warn "NTFS format failed (${loop}p2)"

        local mnt
        mnt=$(mktemp -d /tmp/chntpw_mnt.XXXXXX)
        if $NTFS3G "${loop}p2" "$mnt" -o rw 2>/dev/null; then
            local hive_dir="$mnt/Windows/System32/config"
            mkdir -p "$hive_dir"
            $PYTHON3 "$BASE_DIR/make_regf.py" "$hive_dir" 2>/dev/null \
                && success "  Windows registry skeleton written to $hive_dir" \
                || warn "  make_regf.py failed — partition visible but SAM will be missing"
            umount "$mnt"
        else
            warn "ntfs-3g mount failed — Windows directory not seeded"
        fi
        rmdir "$mnt" 2>/dev/null || true

        $LOSETUP -d "$loop"

        $QEMU_IMG convert -f raw -O qcow2 "$raw_tmp" "$img_path"
        rm -f "$raw_tmp"

        success "Created: $img_path"
    done

    success "Test drives ready."
    info "  SATA image: $QEMU_SATA_IMG"
    info "  NVMe image: $QEMU_NVME_IMG"
}

# ---------------------------------------------------------------------------
# QEMU TESTS — Core launch
# ---------------------------------------------------------------------------
_qemu_launch() {
    local mode="$1"
    local drive="$2"
    local iso="${3:-$RELEASE_DIR/$ISO_OUTPUT_NAME}"

    [[ -f "$iso" ]] || { iso="$ISO_SOURCE"; warn "Using original ISO for test."; }

    local ovmf_vars
    ovmf_vars=$(_ovmf_vars)

    local machine_opts=() fw_opts=() cdrom_opts=() boot_opts=() drive_opts=()
    local test_img=""

    if [[ "$mode" == "uefi" ]]; then
        machine_opts=(-machine q35)
        fw_opts=(
            -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
            -drive "if=pflash,format=raw,file=$ovmf_vars"
        )
        cdrom_opts=(
            -device ich9-ahci,id=ahci_cd
            -drive  "file=$iso,media=cdrom,if=none,id=cdrom0,readonly=on"
            -device ide-cd,drive=cdrom0,bus=ahci_cd.0
        )
        if [[ "$drive" == "nvme" ]]; then
            test_img="$QEMU_NVME_IMG"
            [[ ! -f "$test_img" ]] && { warn "NVMe test image not found."; test_img=""; }
            [[ -n "$test_img" ]] && drive_opts=(
                -drive  "file=$test_img,if=none,id=nvme0,format=qcow2"
                -device nvme,serial=chntpw0,drive=nvme0
            )
        else
            test_img="$QEMU_SATA_IMG"
            [[ ! -f "$test_img" ]] && { warn "SATA test image not found."; test_img=""; }
            [[ -n "$test_img" ]] && drive_opts=(
                -device ich9-ahci,id=ahci_hd
                -drive  "file=$test_img,if=none,id=sata0,format=qcow2"
                -device ide-hd,drive=sata0,bus=ahci_hd.0
            )
        fi
    else
        cdrom_opts=(-cdrom "$iso")
        boot_opts=(-boot order=d)
        if [[ "$drive" == "nvme" ]]; then
            test_img="$QEMU_NVME_IMG"
            [[ ! -f "$test_img" ]] && { warn "NVMe test image not found."; test_img=""; }
            [[ -n "$test_img" ]] && drive_opts=(
                -drive  "file=$test_img,if=none,id=nvme0,format=qcow2"
                -device nvme,serial=chntpw0,drive=nvme0
            )
        else
            test_img="$QEMU_SATA_IMG"
            [[ ! -f "$test_img" ]] && { warn "SATA test image not found."; test_img=""; }
            [[ -n "$test_img" ]] && drive_opts=(
                -drive  "file=$test_img,if=none,id=sata0,format=qcow2"
                -device ich9-ahci,id=ahci
                -device ide-hd,drive=sata0,bus=ahci.0
            )
        fi
    fi

    echo -e "\n${BOLD}${CYN}Launching QEMU — Mode: ${mode^^}  Drive: ${drive^^}${NC}"
    echo -e "${DIM}ISO: $iso${NC}"
    echo -e "${DIM}Drive: ${test_img:-NONE}${NC}"
    echo

    local cmd=(
        $QEMU
        "${machine_opts[@]}"
        -name "chntpw-test-${mode}-${drive}"
        -m "$QEMU_MEMORY" -smp "$QEMU_SMP"
        "${fw_opts[@]}"
        "${cdrom_opts[@]}"
        "${boot_opts[@]}"
        "${drive_opts[@]}"
        -vga "$QEMU_VGA" -no-reboot
    )

    echo -e "${YLW}Command:${NC}"
    printf "  %s \\\n" "${cmd[@]}"
    echo

    "${cmd[@]}"
}

qemu_test_bios_sata() { step "QEMU Test: Legacy BIOS + SATA/AHCI"; _qemu_launch bios sata; }
qemu_test_bios_nvme() { step "QEMU Test: Legacy BIOS + NVMe";      _qemu_launch bios nvme; }
qemu_test_uefi_sata() { step "QEMU Test: UEFI (OVMF) + SATA/AHCI"; _qemu_launch uefi sata; }
qemu_test_uefi_nvme() { step "QEMU Test: UEFI (OVMF) + NVMe";      _qemu_launch uefi nvme; }

# ---------------------------------------------------------------------------
# AUTOMATED BUILD — Suboption runners
# ---------------------------------------------------------------------------
_run_suboption_1() {
    step "Suboption 1: Extraction & Patching (Steps 1–6)"
    setup_project
    extract_iso
    unpack_initrd
    patch_initrd
    repack_initrd
    build_stub_scsi
}

_run_suboption_2() {
    step "Suboption 2: Kernel Build (Steps 7–9)"
    generate_kernel_config
    download_kernel
    compile_kernel
}

_run_suboption_3() {
    step "Suboption 3: ISO Assembly (Steps 10–12)"
    assemble_iso_tree
    build_efi_image
    build_final_iso
}

# ---------------------------------------------------------------------------
# AUTOMATED BUILD — Submenu
# ---------------------------------------------------------------------------
automated_build_menu() {
    while true; do
        echo
        _box_top
        printf "${BLU}${BOLD}║${NC}  ${MAG}${BOLD}%-65s${NC}  ${BLU}${BOLD}║${NC}\n" \
            "AUTOMATED BUILD"
        _box_sect "SUBOPTIONS"
        _box_item "1" "Extraction & Patching    (Steps 1–6)"
        _box_item "2" "Kernel Build             (Steps 7–9)"
        _box_item "3" "ISO Assembly             (Steps 10–12)"
        _box_sep
        _box_item "A" "ALL  (Steps 1–12)"
        _box_sep
        _box_item "0" "Back to main menu"
        _box_bot
        echo
        echo -e "${DIM}  Combine suboptions: e.g.  13  runs suboptions 1 and 3${NC}"
        echo
        read -rp "$(echo -e "${CYN}${BOLD}  Automated Build ▶ ${NC}")" choice

        case "${choice^^}" in
            0|Q) return ;;
            A)
                _run_suboption_1
                _run_suboption_2
                _run_suboption_3
                echo -e "\n${BOLD}${GRN}Automated build complete!${NC}"
                echo -e "ISO: ${CYN}$RELEASE_DIR/$ISO_OUTPUT_NAME${NC}"
                ;;
            *)
                local _ran=0
                [[ "$choice" == *1* ]] && { _run_suboption_1; _ran=1; }
                [[ "$choice" == *2* ]] && { _run_suboption_2; _ran=1; }
                [[ "$choice" == *3* ]] && { _run_suboption_3; _ran=1; }
                if [[ "$_ran" -eq 0 ]]; then
                    warn "Invalid choice: $choice"
                    continue
                fi
                echo -e "\n${BOLD}${GRN}Selected suboptions complete!${NC}"
                ;;
        esac
        pause
    done
}

# ---------------------------------------------------------------------------
# CLEAN WORKSPACE
# ---------------------------------------------------------------------------
_clean_all() {
    echo
    _box_top
    _box_blank
    _box_row "CLEAN EVERYTHING will permanently DELETE:"
    _box_blank
    _box_row "  - work/      (kernel tarball + source + all build files)"
    _box_row "  - release/   (final ISO)"
    _box_row "  - source/    (assembled ISO tree)"
    _box_blank
    _box_row "Kept: legacy/  chntpw-workshop.sh  chntpw-modernizer.sh"
    _box_row "      make_regf.py  README.md  kernel.config"
    _box_blank
    _box_bot
    echo
    if [[ "$BATCH_MODE" -eq 0 ]]; then
        read -rp "$(echo -e "${YLW}${BOLD}  Type 'yes' to confirm: ${NC}")" ans
        [[ "$ans" == "yes" ]] || { info "Cancelled."; return; }
    fi

    info "Removing work/ ..."
    rm -rf "$WORK_DIR"
    info "Removing release/ ..."
    rm -rf "$RELEASE_DIR"
    info "Removing source/ ..."
    rm -rf "$SOURCE_DIR"

    # Remove any empty directories left behind
    find "$BASE_DIR" -mindepth 1 -maxdepth 3 -type d -empty -delete 2>/dev/null || true

    success "Full clean complete. Run Step 1 to start a fresh build."
}

_clean_work() {
    echo
    _box_top
    _box_blank
    _box_row "WIPE WORK will permanently DELETE:"
    _box_blank
    _box_row "  - work/  (kernel tarball + source + all intermediate files)"
    _box_blank
    _box_row "Kept: legacy/  source/  release/  scripts  README.md"
    _box_blank
    _box_bot
    echo
    read -rp "$(echo -e "${YLW}${BOLD}  Type 'yes' to confirm: ${NC}")" ans
    [[ "$ans" == "yes" ]] || { info "Cancelled."; return; }

    info "Removing work/ ..."
    rm -rf "$WORK_DIR"

    find "$BASE_DIR" -mindepth 1 -maxdepth 3 -type d -empty -delete 2>/dev/null || true

    success "Work directory wiped. source/ and release/ preserved."
}

clean_workspace() {
    step "Clean workspace"
    echo
    _box_top
    _box_sect "CLEAN OPTIONS"
    _box_item "A" "Clean everything  (work/ + release/ + source/)"
    _box_item "W" "Wipe work only    (keep source/ and release/)"
    _box_sep
    _box_item "0" "Cancel"
    _box_bot
    echo
    read -rp "$(echo -e "${CYN}${BOLD}  Clean ▶ ${NC}")" choice

    case "${choice^^}" in
        A) _clean_all ;;
        W) _clean_work ;;
        0|Q) info "Cancelled."; return ;;
        *) warn "Invalid choice '$choice'."; return ;;
    esac
}

# ---------------------------------------------------------------------------
# QEMU SUBMENU
# ---------------------------------------------------------------------------
qemu_menu() {
    while true; do
        echo
        _box_top
        printf "${BLU}${BOLD}║${NC}  ${CYN}${BOLD}%-65s${NC}  ${BLU}${BOLD}║${NC}\n" \
            "QEMU Test Lab  —  boot the ISO without leaving your desk"
        _box_sect "TEST DRIVES"
        _box_item  "1" "Create dummy NTFS test drives  (qcow2, ${QEMU_IMG_SIZE} each)"
        _box_sect "LEGACY BIOS TESTS"
        _box_item  "2" "Legacy BIOS  +  SATA / AHCI"
        _box_item  "3" "Legacy BIOS  +  NVMe"
        _box_sect "UEFI TESTS  (OVMF firmware)"
        _box_item  "4" "UEFI (OVMF)  +  SATA / AHCI"
        _box_item  "5" "UEFI (OVMF)  +  NVMe"
        _box_sep
        _box_item  "0" "Back to main menu"
        _box_bot
        echo
        read -rp "$(echo -e "${CYN}${BOLD}  QEMU ▶ ${NC}")" choice

        case "$choice" in
            1) qemu_create_drives ;;
            2) qemu_test_bios_sata ;;
            3) qemu_test_bios_nvme ;;
            4) qemu_test_uefi_sata ;;
            5) qemu_test_uefi_nvme ;;
            0|q|Q) return ;;
            *) warn "Invalid choice: $choice" ;;
        esac
        pause
    done
}

# ---------------------------------------------------------------------------
# MAIN MENU
# ---------------------------------------------------------------------------
main_menu() {
    banner
    while true; do
        _box_top
        _box_sect "EXTRACTION  &  PATCHING"
        _box_item  "1"  "Setup project folders"
        _box_item  "2"  "Extract original ISO  →  work/iso_extract/"
        _box_item  "3"  "Unpack initrd.cgz     →  work/initrd_extract/"
        _box_item  "4"  "Patch initrd for NVMe + modern hardware"
        _box_item  "5"  "Repack patched initrd.cgz"
        _box_item  "6"  "Build stub scsi.cgz  (replaces old kernel modules)"
        _box_sect "KERNEL BUILD  (Linux ${KERNEL_VERSION})"
        _box_item  "7"  "Generate kernel .config"
        _box_item  "8"  "Download Linux ${KERNEL_VERSION} source  (~130 MB)"
        _box_item_note "9"  "Compile kernel" "(15-60 min, needs build-essential)"
        _box_sect "ISO ASSEMBLY"
        _box_item  "10" "Assemble source/ tree  (BIOS + UEFI configs)"
        _box_item  "11" "Build EFI boot image  (BOOTX64.EFI + efiboot.img)"
        _box_item  "12" "Build final hybrid ISO  →  release/$ISO_OUTPUT_NAME"
        _box_sect "UTILITIES"
        _box_item  "13" "Export kernel config to project root"
        _box_item  "T"  "QEMU Test Lab  (NVMe / SATA  x  BIOS / UEFI)"
        _box_item  "A"  "Automated build"
        _box_item  "C"  "Check required tools"
        _box_item  "X"  "Clean workspace"
        _box_item  "Z"  "Exit"
        _box_bot
        echo
        read -rp "$(echo -e "${CYN}${BOLD}  Workshop ▶ ${NC}")" choice

        case "$choice" in
             1) setup_project        ;;
             2) extract_iso          ;;
             3) unpack_initrd        ;;
             4) patch_initrd         ;;
             5) repack_initrd        ;;
             6) build_stub_scsi      ;;
             7) generate_kernel_config ;;
             8) download_kernel      ;;
             9) compile_kernel       ;;
            10) assemble_iso_tree    ;;
            11) build_efi_image      ;;
            12) build_final_iso      ;;
            13) sync_artifacts       ;;
            [Tt]) qemu_menu          ;;
            [Aa]) automated_build_menu ;;
            [Cc]) check_tools        ;;
            [Xx]) clean_workspace    ;;
            [Zz]) echo -e "${GRN}Goodbye.${NC}"; exit 0 ;;
            *) warn "Unknown option: $choice" ;;
        esac
        pause
    done
}

# ---------------------------------------------------------------------------
# SYSLINUX PATH DETECTION
# ---------------------------------------------------------------------------
detect_syslinux_paths() {
    # Arch Linux: all files under /usr/lib/syslinux/bios/
    if [[ -f "/usr/lib/syslinux/bios/isolinux.bin" ]]; then
        ISOLINUX_BIN="/usr/lib/syslinux/bios/isolinux.bin"
        ISOHDPFX_BIN="/usr/lib/syslinux/bios/isohdpfx.bin"
        SYSLINUX_MODULES="/usr/lib/syslinux/bios"
        info "Syslinux layout: Arch Linux  ($SYSLINUX_MODULES)"
    # Debian/Ubuntu: isolinux.bin + isohdpfx.bin in /usr/lib/ISOLINUX,
    #                c32 modules in /usr/lib/syslinux/modules/bios
    elif [[ -f "/usr/lib/ISOLINUX/isolinux.bin" ]]; then
        ISOLINUX_BIN="/usr/lib/ISOLINUX/isolinux.bin"
        ISOHDPFX_BIN="/usr/lib/ISOLINUX/isohdpfx.bin"
        SYSLINUX_MODULES="/usr/lib/syslinux/modules/bios"
        info "Syslinux layout: Debian/Ubuntu"
        info "  isolinux bin : /usr/lib/ISOLINUX/"
        info "  modules      : $SYSLINUX_MODULES"
    else
        warn "Could not auto-detect syslinux paths; using configured defaults."
        warn "  ISOLINUX_BIN=$ISOLINUX_BIN"
        warn "  SYSLINUX_MODULES=$SYSLINUX_MODULES"
        warn "Install 'isolinux' (Debian) or 'syslinux' (Arch) if Step 10 fails."
    fi
}

# ---------------------------------------------------------------------------
# ENTRY POINT
# ---------------------------------------------------------------------------
check_root

if [[ "${1:-}" == "--batch" ]]; then
    BATCH_MODE=1
    detect_syslinux_paths
    step "BATCH MODE: Clean + Steps 1-12"
    _clean_all
    setup_project
    extract_iso
    unpack_initrd
    patch_initrd
    repack_initrd
    build_stub_scsi
    generate_kernel_config
    download_kernel
    compile_kernel
    assemble_iso_tree
    build_efi_image
    build_final_iso
    echo
    success "Full batch build complete!"
    echo -e "  ISO: ${CYN}$RELEASE_DIR/$ISO_OUTPUT_NAME${NC}"
    exit 0
fi

detect_syslinux_paths
main_menu
