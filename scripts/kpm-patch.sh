#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# kpm-patch.sh -- post-build step that makes CONFIG_KPM actually work.
#
# KPM (Kernel Patch Module) is not implemented in SukiSU-Nova itself: the
# kernel side is only a bridge that calls KernelPatch's supercall through the
# truncate syscall. The modules are loaded by KernelPatch, which has to be
# injected into the *built* kernel image, after the link and before packaging.
#
# That is what this script does, with ShirkNeko's prebuilt SukiSU KernelPatch
# tools (patched KernelPatch whose supercall speaks the SUKISU_KPM_* ABI):
#
#   1. run patch_linux on out/arch/arm64/boot/Image   -> oImage
#   2. sanity check that oImage is still an arm64 Image
#   3. rebuild Image.gz-dtb around it, byte-identically to the kernel's own
#      rule: gzip(Image) + the DTB blob that was appended to the original
#
#   ./scripts/kpm-patch.sh                 patch in place, verify
#   ./scripts/kpm-patch.sh --check         verify only, change nothing
#
# Everything is idempotent: an image that already carries KernelPatch is
# detected and left alone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$REPO_ROOT}"
[[ -f "$KERNEL_DIR/Makefile" && -f "$KERNEL_DIR/arch/arm64/Makefile" ]] \
    || KERNEL_DIR="$REPO_ROOT/kernel"

OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
BOOT_DIR="$OUT_DIR/arch/arm64/boot"

# Pinned: the tools embed kpimg, so an unpinned ref would silently change the
# payload that ends up in the kernel.
SUKISU_PATCH_REPO="${SUKISU_PATCH_REPO:-https://github.com/ShirkNeko/SukiSU_patch}"
SUKISU_PATCH_REF="${SUKISU_PATCH_REF:-4ee085a39e3c95e44c9cac7af040e83bf926e6fa}"
TOOL_DIR="${TOOL_DIR:-$KERNEL_DIR/.kpm-tools}"

MODE=apply
for arg in "$@"; do
    case "$arg" in
        --check)   MODE=check ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
    esac
done

log()  { printf '[kpm] %s\n' "$*"; }
ok()   { printf '[kpm]   ok: %s\n' "$*"; }
die()  { printf '[kpm] ERROR: %s\n' "$*" >&2; exit 1; }

cd "$KERNEL_DIR"

[[ -f "$BOOT_DIR/Image" ]] \
    || die "no $BOOT_DIR/Image -- build the kernel before patching for KPM"

# arm64 Image header magic at offset 0x38 is "ARM\x64" (0x644d5241).
image_magic() {
    dd if="$1" bs=1 skip=56 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n'
}
ARM64_MAGIC="41524d64"

check_image() {
    local f=$1
    [[ -s "$f" ]] || die "$f is empty"
    local magic
    magic="$(image_magic "$f")"
    [[ "$magic" == "$ARM64_MAGIC" ]] \
        || die "$f does not look like an arm64 Image (header magic $magic)"
}

# KernelPatch leaves its version string in the injected blob, so its presence
# is how an already-patched image is recognised.
already_patched() {
    grep -qa 'KernelPatch Version' "$1"
}

check_image "$BOOT_DIR/Image"

if already_patched "$BOOT_DIR/Image"; then
    ok "Image already carries KernelPatch, nothing to do"
    exit 0
fi

if [[ "$MODE" == check ]]; then
    die "Image is not patched for KPM (run without --check)"
fi

# --------------------------------------------------------------- 1. tools ---

if [[ ! -x "$TOOL_DIR/kpm/patch_linux" ]]; then
    log "fetching SukiSU KernelPatch tools (${SUKISU_PATCH_REF:0:12})"
    rm -rf "$TOOL_DIR"
    mkdir -p "$TOOL_DIR"
    git -C "$TOOL_DIR" init -q
    git -C "$TOOL_DIR" remote add origin "$SUKISU_PATCH_REPO"
    # A sha cannot come from a shallow clone, so fetch it by name.
    git -C "$TOOL_DIR" fetch -q --depth 1 origin "$SUKISU_PATCH_REF" \
        || die "cannot fetch ${SUKISU_PATCH_REPO} at ${SUKISU_PATCH_REF}"
    git -C "$TOOL_DIR" checkout -q FETCH_HEAD \
        || die "cannot check out ${SUKISU_PATCH_REF}"
    ok "tools at $(git -C "$TOOL_DIR" rev-parse --short HEAD)"
fi
chmod +x "$TOOL_DIR/kpm/patch_linux"

# --------------------------------------------------- 2. remember the layout --

# Image.gz-dtb is `cat Image.gz DTB_OBJS` (arch/arm64/boot/Makefile), so the
# bytes after the gzip stream are the device trees. Record the split before
# anything is regenerated, then reuse the exact same blob afterwards instead of
# re-deriving the DTB list from make.
ORIG_GZ_SIZE=0
DTB_BLOB=""
if [[ -f "$BOOT_DIR/Image.gz-dtb" ]]; then
    [[ -f "$BOOT_DIR/Image.gz" ]] || die "Image.gz-dtb exists without Image.gz"
    ORIG_GZ_SIZE="$(stat -c%s "$BOOT_DIR/Image.gz")"
    IMGDTB_SIZE="$(stat -c%s "$BOOT_DIR/Image.gz-dtb")"
    DTB_SIZE=$((IMGDTB_SIZE - ORIG_GZ_SIZE))
    (( DTB_SIZE > 0 )) \
        || die "Image.gz-dtb is not Image.gz + dtb (${IMGDTB_SIZE} <= ${ORIG_GZ_SIZE})"
    DTB_BLOB="$(mktemp)"
    tail -c "$DTB_SIZE" "$BOOT_DIR/Image.gz-dtb" > "$DTB_BLOB"
    # Device trees start with the FDT magic 0xd00dfeed (big endian).
    fdt_magic="$(od -An -tx1 -N4 "$DTB_BLOB" | tr -d ' \n')"
    [[ "$fdt_magic" == "d00dfeed" ]] \
        || log "note: the appended blob does not start with an FDT magic ($fdt_magic)"
    ok "dtb blob: ${DTB_SIZE} bytes"
fi

# --------------------------------------------------------- 3. diagnostics ---

# If patch_linux rejects the image, these are the facts that decide whether it
# is the image or the tool: the version strings it scans for, and the version
# of the payload it injects.
log "image: $(stat -c%s "$BOOT_DIR/Image") bytes"
log "kernel release: $(strings "$BOOT_DIR/Image" | grep -m1 '^Linux version ' || echo '<not found>')"
if [[ -x "$TOOL_DIR/kpm/kptools-linux" ]]; then
    "$TOOL_DIR/kpm/kptools-linux" -k "$TOOL_DIR/kpm/kpimg" -l 2>&1 | sed 's/^/[kpm] payload: /' || true
fi

# ------------------------------------------------------------ 4. patch it ---

log "patching Image with patch_linux"

# patch_linux reports failures with a "[-] file:line/function(): reason" line
# and still exits 0, so its exit status says nothing. Keep its output, and turn
# every line of it into a workflow annotation: a failure here happens after a
# fifteen-minute build, and the runner's log is not always reachable.
PATCH_LOG="$(mktemp)"
patch_rc=0
( cd "$BOOT_DIR" && "$TOOL_DIR/kpm/patch_linux" Image ) 2>&1 | tee "$PATCH_LOG" || patch_rc=$?
ann() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::error file=scripts/kpm-patch.sh::%s\n' "${1//%/}"
    fi
}
if (( patch_rc != 0 )); then
    while IFS= read -r line; do ann "patch_linux: $line"; done < "$PATCH_LOG"
    die "patch_linux exited $patch_rc"
fi
if grep -q '^\[-\]' "$PATCH_LOG"; then
    while IFS= read -r line; do ann "patch_linux: $line"; done < <(grep '^\[-\]' "$PATCH_LOG")
    die "patch_linux reported a failure: $(grep -m1 '^\[-\]' "$PATCH_LOG")"
fi

# Kept until the image is accepted: the messages below quote it.
if [[ ! -f "$BOOT_DIR/oImage" ]]; then
    while IFS= read -r line; do ann "patch_linux: $line"; done < <(grep '^\[-\]' "$PATCH_LOG" 2>/dev/null || true)
    die "patch_linux did not produce oImage (output: $(tr '\n' ' ' < "$PATCH_LOG" 2>/dev/null))"
fi
check_image "$BOOT_DIR/oImage"
already_patched "$BOOT_DIR/oImage" \
    || die "oImage does not contain KernelPatch (patch_linux output looks wrong)"

ORIG_SIZE="$(stat -c%s "$BOOT_DIR/Image")"
NEW_SIZE="$(stat -c%s "$BOOT_DIR/oImage")"
log "Image ${ORIG_SIZE} -> ${NEW_SIZE} bytes (+$((NEW_SIZE - ORIG_SIZE)))"

mv -f "$BOOT_DIR/oImage" "$BOOT_DIR/Image"
rm -f "$PATCH_LOG"
ok "Image patched"

# ------------------------------------------------------- 5. repack payload ---

if [[ -n "$DTB_BLOB" ]]; then
    gzip -n -f -9 < "$BOOT_DIR/Image" > "$BOOT_DIR/Image.gz"
    cat "$BOOT_DIR/Image.gz" "$DTB_BLOB" > "$BOOT_DIR/Image.gz-dtb"
    rm -f "$DTB_BLOB"
    ok "Image.gz-dtb rebuilt ($(stat -c%s "$BOOT_DIR/Image.gz-dtb") bytes)"
else
    log "no Image.gz-dtb in this build; only Image was patched"
fi

# ------------------------------------------------------------- 6. verify ---

already_patched "$BOOT_DIR/Image" || die "patched Image lost KernelPatch"
if [[ -f "$BOOT_DIR/Image.gz-dtb" ]]; then
    # Image.gz must decompress to exactly the patched Image, and Image.gz-dtb
    # must be that gzip stream plus the original dtb blob, byte for byte.
    # (Decompressing Image.gz-dtb itself is not a test: gzip reports the dtb as
    # trailing garbage, which is exactly how the kernel builds it.)
    gzip -dc "$BOOT_DIR/Image.gz" | cmp -s - "$BOOT_DIR/Image" \
        || die "Image.gz no longer decompresses to Image"
    GZ_SIZE="$(stat -c%s "$BOOT_DIR/Image.gz")"
    [[ "$(stat -c%s "$BOOT_DIR/Image.gz-dtb")" -eq "$((GZ_SIZE + DTB_SIZE))" ]] \
        || die "Image.gz-dtb is not Image.gz + the original dtb blob"
    ok "Image.gz decompresses to the patched Image; dtb blob intact"
fi

log "KPM ready: the image carries KernelPatch, CONFIG_KPM=y is in the kernel"
