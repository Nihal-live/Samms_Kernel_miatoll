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
#   1. run kptools -p on out/arch/arm64/boot/Image    -> oImage
#      (KernelPatch's own CLI. The SukiSU bundle's patch_linux wrapper does the
#      same thing but hands kptools an embedded kpimg through a memfd, and in
#      the pinned bundle that payload arrives 16 bytes long -- see section 4.)
#   2. sanity check that oImage is still an arm64 Image and carries the payload
#   3. rebuild Image.gz and Image.gz-dtb around it, byte-identically to the
#      kernel's own rule: gzip(Image) + the DTB blob, taken from the original
#      Image.gz-dtb when present and from dtb.img when make was only asked for
#      the images (both rules cat the same device tree list)
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

# The injected payload starts with its own preset magic, which is the marker
# kptools itself scans for. Section 4 re-reads it from the kpimg file that is
# actually used; this default only has to cover the idempotency check that runs
# before the tools are fetched.
KPIMG_MAGIC="${KPIMG_MAGIC:-KP1158}"
already_patched() {
    grep -qa -- "$KPIMG_MAGIC" "$1"
}

# Image.gz has to decompress to Image, and Image.gz-dtb has to be exactly that
# gzip stream followed by the device tree blob. Decompressing Image.gz-dtb
# itself proves nothing: gzip reports the appended dtb as trailing garbage,
# which is how the kernel's own Makefile builds it.
verify_repack() {
    [[ -f "$BOOT_DIR/Image.gz" && -f "$BOOT_DIR/Image.gz-dtb" ]] || return 0
    gzip -dc "$BOOT_DIR/Image.gz" | cmp -s - "$BOOT_DIR/Image" \
        || die "Image.gz no longer decompresses to Image"
    local gz_size dtb_start
    gz_size="$(stat -c%s "$BOOT_DIR/Image.gz")"
    head -c "$gz_size" "$BOOT_DIR/Image.gz-dtb" | cmp -s - "$BOOT_DIR/Image.gz" \
        || die "Image.gz-dtb does not start with Image.gz"
    # od skips in place; `tail | od -N4` would leave tail writing into a closed
    # pipe, and with pipefail that "Broken pipe" is a failure of the check.
    dtb_start="$(od -An -tx1 -j "$gz_size" -N4 "$BOOT_DIR/Image.gz-dtb" | tr -d ' \n')"
    [[ "$dtb_start" == "d00dfeed" ]] \
        || die "Image.gz-dtb does not end with a device tree blob (got $dtb_start)"
    ok "Image.gz decompresses to Image; Image.gz-dtb is gzip + dtb"
}

check_image "$BOOT_DIR/Image"

if already_patched "$BOOT_DIR/Image"; then
    ok "Image already carries KernelPatch, nothing to do"
    # --check and a re-run both land here; the payload files still have to be
    # consistent, which is most of the point of checking.
    if [[ -f "$BOOT_DIR/Image.gz" && -f "$BOOT_DIR/Image.gz-dtb" ]]; then
        verify_repack
    fi
    exit 0
fi

if [[ "$MODE" == check ]]; then
    die "Image is not patched for KPM (run without --check)"
fi

# --------------------------------------------------------------- 1. tools ---

if [[ ! -x "$TOOL_DIR/kpm/kptools-linux" || ! -f "$TOOL_DIR/kpm/kpimg" ]]; then
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
chmod +x "$TOOL_DIR/kpm/kptools-linux"

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
elif [[ -f "$BOOT_DIR/dtb.img" ]]; then
    # A bare `make` on this tree produces Image, Image.gz and dtb.img but not
    # the combined artefact (that is an explicit make target). Both rules cat
    # the same $(DTB_OBJS) list in the same order, so Image.gz-dtb is exactly
    # Image.gz followed by dtb.img; building it here keeps the flashable
    # artefact identical whether or not make was asked for it.
    DTB_SIZE="$(stat -c%s "$BOOT_DIR/dtb.img")"
    (( DTB_SIZE > 0 )) || die "$BOOT_DIR/dtb.img is empty"
    DTB_BLOB="$(mktemp)"
    cp "$BOOT_DIR/dtb.img" "$DTB_BLOB"
    fdt_magic="$(od -An -tx1 -N4 "$DTB_BLOB" | tr -d ' \n')"
    [[ "$fdt_magic" == "d00dfeed" ]] \
        || die "dtb.img does not start with an FDT magic ($fdt_magic)"
    ok "dtb blob: ${DTB_SIZE} bytes (from dtb.img; Image.gz-dtb will be created)"
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

# KernelPatch's CLI, not the SukiSU bundle's patch_linux wrapper.
#
# patch_linux decrypts an embedded kpimg into a memfd and execs kptools with
# "-k /proc/self/fd/N". In the pinned bundle that descriptor comes out as a
# 16-byte file, so the patched image reported success while carrying no
# payload at all:
#
#   [+] layout kimg: 0x0,0x2930810, kpimg: 0x2931000,0x10, ...   <- 16 bytes
#   [+] kpimg version: 0
#   [+] kpimg compile time:
#
# kpimg is shipped next to kptools in the same directory, and can be inspected
# before it is used, so the payload is passed through from there. The arguments
# are the ones patch_linux uses, including its superkey.
KPTOOLS="$TOOL_DIR/kpm/kptools-linux"
KPIMG="$TOOL_DIR/kpm/kpimg"
KPM_SUPERKEY="${KPM_SUPERKEY:-123}"

[[ -x "$KPTOOLS" ]] || die "no kptools in $TOOL_DIR/kpm"
[[ -f "$KPIMG" ]] || die "no kpimg in $TOOL_DIR/kpm (kptools needs the payload)"

KPIMG_SIZE="$(stat -c%s "$KPIMG")"
KPIMG_MAGIC="$(head -c 8 "$KPIMG" | tr -d '\0')"
[[ "$KPIMG_MAGIC" =~ ^KP[0-9]+$ ]] \
    || die "kpimg does not start with a KernelPatch preset magic ('$KPIMG_MAGIC')"
log "kpimg: ${KPIMG_MAGIC}, ${KPIMG_SIZE} bytes"
"$KPTOOLS" -k "$KPIMG" -l 2>&1 | sed 's/^/[kpm] payload: /' || true

log "patching Image with kptools -p"
PATCH_LOG="$(mktemp)"
patch_rc=0
set +e
"$KPTOOLS" -p -s "$KPM_SUPERKEY" -i "$BOOT_DIR/Image" -k "$KPIMG" \
    -o "$BOOT_DIR/oImage" 2>&1 | tee "$PATCH_LOG"
patch_rc=${PIPESTATUS[0]}
set -e

ann() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::error file=scripts/kpm-patch.sh::%s\n' "${1//%/}"
    fi
}
if (( patch_rc != 0 )); then
    while IFS= read -r line; do ann "kptools: $line"; done < "$PATCH_LOG"
    die "kptools exited $patch_rc"
fi
if grep -q '^\[-\]' "$PATCH_LOG"; then
    while IFS= read -r line; do ann "kptools: $line"; done < <(grep '^\[-\]' "$PATCH_LOG")
    die "kptools reported a failure: $(grep -m1 '^\[-\]' "$PATCH_LOG")"
fi

if [[ ! -f "$BOOT_DIR/oImage" ]]; then
    die "kptools did not produce oImage (output: $(tr '\n' ' ' < "$PATCH_LOG"))"
fi
check_image "$BOOT_DIR/oImage"
already_patched "$BOOT_DIR/oImage" \
    || die "oImage does not carry the ${KPIMG_MAGIC} payload -- the image was patched without it"

ORIG_SIZE="$(stat -c%s "$BOOT_DIR/Image")"
NEW_SIZE="$(stat -c%s "$BOOT_DIR/oImage")"
GROWTH=$((NEW_SIZE - ORIG_SIZE))
log "Image ${ORIG_SIZE} -> ${NEW_SIZE} bytes (+${GROWTH})"
# The layout is 4K-aligned image + kpimg + extra items, so the file has to
# grow by at least the payload. Anything less means the payload was dropped,
# which is exactly the failure mode this bypasses.
(( GROWTH >= KPIMG_SIZE )) \
    || die "Image only grew by ${GROWTH} bytes, less than the ${KPIMG_SIZE}-byte payload"

# kptools can read the result back; keep that in the log, it is the same
# parser the boot-time patcher uses.
"$KPTOOLS" -l -i "$BOOT_DIR/oImage" 2>&1 | sed 's/^/[kpm] oImage: /' || true

mv -f "$BOOT_DIR/oImage" "$BOOT_DIR/Image"
rm -f "$PATCH_LOG"
ok "Image patched"

# ------------------------------------------------------- 5. repack payload ---

if [[ -n "$DTB_BLOB" ]]; then
    gzip -n -f -9 < "$BOOT_DIR/Image" > "$BOOT_DIR/Image.gz"
    cat "$BOOT_DIR/Image.gz" "$DTB_BLOB" > "$BOOT_DIR/Image.gz-dtb"
    rm -f "$DTB_BLOB"
    ok "Image.gz-dtb written ($(stat -c%s "$BOOT_DIR/Image.gz-dtb") bytes)"
else
    log "no Image.gz-dtb in this build; only Image was patched"
fi

# ------------------------------------------------------------- 6. verify ---

already_patched "$BOOT_DIR/Image" || die "patched Image lost KernelPatch"
verify_repack
if [[ -n "$DTB_BLOB" ]]; then
    # The rebuilt payload must still be the original dtb blob, byte for byte.
    GZ_SIZE="$(stat -c%s "$BOOT_DIR/Image.gz")"
    [[ "$(stat -c%s "$BOOT_DIR/Image.gz-dtb")" -eq "$((GZ_SIZE + DTB_SIZE))" ]] \
        || die "Image.gz-dtb is not Image.gz + the original dtb blob"
fi

log "KPM ready: the image carries KernelPatch, CONFIG_KPM=y is in the kernel"
