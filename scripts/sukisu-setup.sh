#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# sukisu-setup.sh -- reproducible SukiSU Nova + SUSFS v2.3.0 integration for
# the miatoll/excalibur 4.14.357 tree. Run BEFORE building; the CI workflow
# calls it automatically, so a clean checkout always produces the same kernel.
#
# Stages (all idempotent):
#   1. clone SukiSU-Nova (builtin, SHA-pinned) and wire drivers/Makefile + drivers/Kconfig
#   2. apply the two 4.14 compatibility fixes to the SukiSU source
#   3. apply the manual KernelSU hook call sites
#   4. install the SUSFS v2.3.0 core (fs/susfs.c + headers, SHA-pinned)
#   5. apply the native SUSFS 4.14 kernel patch (the fs/ hook hunks)
#   6. RECONCILE the v1.5.5 patch against the v2.3.0 core  <-- the fix
#   6.5 re-install the SPOOF_UNAME hook in kernel/sys.c (patch hunk rejects there)
#   7. set the defconfig symbols
#   8. verify
#
# WHY STAGE 6 EXISTS
#   No single SUSFS branch has both halves we need:
#     * kernel-4.14 (upstream) is frozen at v1.5.5 -- its API does not match
#       what SukiSU Nova calls (11 of 15 symbols missing).
#     * kernel-4.9-v2 (wxx9248) is v2.3.0 -- the API SukiSU Nova expects, but
#       its patch is written for 4.9 and rejects 41 times on 4.14.
#   So we take the v2.3.0 CORE + the native 4.14 PATCH, and bridge the API gap
#   in scripts/susfs_414_reconcile.py. Without stage 6 the build fails at the
#   final link with 7 "undefined symbol: susfs_*" errors.
#
# STAGE 10 (RECONCILE): BOOTLOOP FIX
#   The v2.3.0 core's susfs_spoof_cmdline_or_bootconfig() seq_puts() a NULL
#   buffer when userspace never programmed a fake /proc/cmdline, and Android
#   init reads /proc/cmdline during early boot. Pre-fix builds (#5/#6/#7)
#   panicked before the boot animation. Stage 10 gates both spoof hooks on
#   their static keys (v1.5.5 semantics) and makes cmdline.c fall through to
#   saved_command_line.
#
# ENV OVERRIDES
#   SUSFS_DISABLE="CONFIG_KSU_SUSFS_SUS_MOUNT CONFIG_KSU_SUSFS_SUS_MAP"
#     write the matching defconfig symbols as 'is not set' (Kconfig default is
#     y). Use for CI bisection, or "CONFIG_KSU_SUSFS" to disable SUSFS
#     entirely (a Nova-only control build).
#
# Usage: ./scripts/sukisu-setup.sh [--check]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Pinned to the exact commits the verified SUSFS CI build was produced from, so
# a clean checkout is reproducible bit-for-bit. Override via the environment to
# upgrade deliberately (bump both the ref AND re-run the SUSFS CI build).
KSU_REPO="${KSU_REPO:-https://github.com/SukiSU-Nova/SukiSU-Nova}"
KSU_REF="${KSU_REF:-4bec532dd447e2852aa8932afa768255350c103a}"  # SukiSU-Nova builtin HEAD the verified SUSFS CI build used

# SUSFS needs TWO sources, because no single branch has both halves:
#   * the v2.3.0 CORE (fs/susfs.c + headers) -- the only API generation that
#     matches what SukiSU Nova calls.
#   * the native 4.14 KERNEL PATCH (the fs/ hook hunks) -- only upstream ships
#     a 4.14 variant; the v2.3.0 branch only has a 4.9 patch.
SUSFS_CORE_REPO="${SUSFS_CORE_REPO:-https://github.com/wxx9248/susfs4ksu}"
SUSFS_CORE_REF="${SUSFS_CORE_REF:-71345ded5af28f55d76ebcdc7a9df9cea56111e1}"  # kernel-4.9-v2 HEAD (v2.3.0 port)
SUSFS_CORE_DIR="${SUSFS_CORE_DIR:-/tmp/susfs-core}"

# The only native 4.14 SUSFS patch lives in upstream simonpunk/susfs4ksu
# (v1.5.5, on GitLab,). This default fetches it from a GitHub mirror whose
# kernel-4.14 branch tip is the EXACT SAME commit SHA as GitLab upstream
# (77905b5a...), so its content is identical by construction -- but it needs no
# gitlab.com access, which is what made this dependency the flaky leg of the
# build (GitLab throttles Actions runner IPs). Set SUSFS_PATCH_REPO to the
# GitLab URL to use upstream directly. Pinned by SHA, so the mirror's sync
# cadence does not affect us; bump deliberately.
SUSFS_PATCH_REPO="${SUSFS_PATCH_REPO:-https://github.com/Ante0/susfs4ksu}"
SUSFS_PATCH_REF="${SUSFS_PATCH_REF:-77905b5a071e6f3669e3b1814cea30147c0801da}"  # == upstream kernel-4.14 tip (Feb 23 2025, "Remove support for Shamiko")
SUSFS_PATCH_DIR="${SUSFS_PATCH_DIR:-/tmp/susfs-patch}"

DEFCONFIG="arch/arm64/configs/vendor/xiaomi/miatoll_defconfig"

log() { printf '[sukisu] %s\n' "$*"; }
die() { printf '[sukisu] ERROR: %s\n' "$*" >&2; exit 1; }

# fetch_pinned URL REF DEST -- REF may be a branch/tag name or a full 40-char
# commit SHA. A 40-char SHA is fetched directly (GitHub allows reachable-SHA
# fetch; git clone -b cannot check out a raw SHA), giving a bit-for-bit
# reproducible tree. Any other REF is cloned with -b as usual.
fetch_pinned() {
    local url="$1" ref="$2" dest="$3"
    rm -rf "$dest"
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        mkdir -p "$dest"
        git -C "$dest" init -q
        git -C "$dest" remote add origin "$url"
        git -C "$dest" fetch --depth 1 origin "$ref" || return 1
        git -C "$dest" checkout -q --detach FETCH_HEAD
    else
        git clone --depth 1 -b "$ref" "$url" "$dest" || return 1
    fi
}

# ---------------------------------------------------------------- 1. upstream
# KernelSU/ is an untracked clone; drivers/kernelsu is an untracked symlink.
# A partial state (clone present, symlink gone) is possible after a cleanup,
# so re-create the symlink whenever the clone exists. The clone is done with
# git only (no raw.githubusercontent.com/setup.sh dependency).
if [[ ! -e KernelSU/kernel ]]; then
    log "cloning SukiSU-Nova ($KSU_REF)"
    fetch_pinned "$KSU_REPO" "$KSU_REF" "KernelSU" || die "cannot fetch SukiSU-Nova"
else
    log "KernelSU/ already present, skipping clone"
fi

if [[ ! -e drivers/kernelsu ]]; then
    log "creating drivers/kernelsu symlink"
    ln -sfn ../KernelSU/kernel drivers/kernelsu
fi

# Enforce the pin: a pre-existing KernelSU/ clone is not silently reused when
# it does not match the pinned ref (this is how a stale local tree would leak
# into an otherwise reproducible build).
if [[ "$KSU_REF" =~ ^[0-9a-f]{40}$ ]]; then
    [[ -d KernelSU/.git ]] || die "KernelSU/ is missing or not a git checkout"
    cur="$(git -C KernelSU rev-parse HEAD)"
    if [[ "$cur" != "$KSU_REF" ]]; then
        die "KernelSU/ is at $cur but the pin wants $KSU_REF -- remove KernelSU/ and re-run"
    fi
    log "KernelSU pinned at $cur"
fi

[[ -L drivers/kernelsu || -d drivers/kernelsu ]] || die "drivers/kernelsu symlink missing"

# The wiring lives in tracked files, so a `git checkout` can undo it while the
# untracked clone survives. Re-apply it whenever it is missing.
if ! grep -q 'kernelsu' drivers/Makefile; then
    log "wiring drivers/Makefile"
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig; then
    log "wiring drivers/Kconfig"
    printf '\nsource "drivers/kernelsu/Kconfig"\n' >> drivers/Kconfig
fi

grep -q 'kernelsu' drivers/Makefile || die "drivers/Makefile not wired"
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || die "drivers/Kconfig not wired"
log "upstream wiring OK"

# ------------------------------------------------- 2. 4.14 compatibility fixes
# (a) linux/static_call.h only exists on 5.10+; the include is unused on 4.14.
python3 - <<'PY'
import sys
p = "drivers/kernelsu/kernel_includes.h"
s = open(p).read()
if "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n#include <linux/static_call.h>" in s:
    print("[sukisu] static_call guard already applied")
else:
    old = "#include <linux/static_call.h>\n"
    new = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
           "#include <linux/static_call.h>\n"
           "#endif\n")
    if old not in s:
        sys.exit("[sukisu] ERROR: static_call anchor missing")
    open(p, "w").write(s.replace(old, new, 1))
    print("[sukisu] applied static_call guard")
PY

# (b) KPM needs 5.10+ interfaces but upstream guards it at 4.4.0, which pulls
#     task_struct.pids / set_memory.h into 4.14 and fails to compile.
python3 - <<'PY'
import sys
p = "drivers/kernelsu/kernel_compat.h"
s = open(p).read()
old = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 4, 0)\n"
       "#define KSU_CAN_USE_KPM\n"
       "#endif")
new = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
       "#define KSU_CAN_USE_KPM\n"
       "#endif")
if new in s:
    print("[sukisu] KPM guard already fixed")
elif old in s:
    open(p, "w").write(s.replace(old, new, 1))
    print("[sukisu] fixed KPM guard 4.4.0 -> 5.10.0")
else:
    sys.exit("[sukisu] ERROR: KPM guard anchor missing")
PY

# ------------------------------------------------------------- 3. hook sites
python3 - <<'PY'
import sys

def patch(path, old, new, label):
    s = open(path).read()
    if "ksu_handle" in s and new.splitlines()[0] in s:
        print("[sukisu] %s already patched" % label); return
    if old not in s:
        sys.exit("[sukisu] ERROR: anchor missing in %s" % label)
    open(path, "w").write(s.replace(old, new, 1))
    print("[sukisu] patched %s" % label)

patch("fs/exec.c",
"static int do_execveat_common(int fd, struct filename *filename,\n"
"\t\t\t      struct user_arg_ptr argv,\n"
"\t\t\t      struct user_arg_ptr envp,\n"
"\t\t\t      int flags)\n"
"{\n"
"\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);\n"
"}",
"#ifdef CONFIG_KSU\n"
"extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
"\t\t\t       void *argv, void *envp, int *flags);\n"
"#endif\n"
"\n"
"static int do_execveat_common(int fd, struct filename *filename,\n"
"\t\t\t      struct user_arg_ptr argv,\n"
"\t\t\t      struct user_arg_ptr envp,\n"
"\t\t\t      int flags)\n"
"{\n"
"#ifdef CONFIG_KSU\n"
"\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
"#endif\n"
"\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);\n"
"}", "fs/exec.c")

patch("fs/open.c",
"SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n"
"{\n"
"\tconst struct cred *old_cred;",
"#ifdef CONFIG_KSU\n"
"extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n"
"\t\t\t\tint *mode, int *__unused_flags);\n"
"#endif\n"
"\n"
"SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n"
"{\n"
"#ifdef CONFIG_KSU\n"
"\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
"#endif\n"
"\tconst struct cred *old_cred;", "fs/open.c")

patch("kernel/reboot.c",
"SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n"
"\t\tvoid __user *, arg)\n"
"{\n"
"\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);",
"#ifdef CONFIG_KSU\n"
"extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n"
"\t\t\t\t void __user **arg);\n"
"#endif\n"
"\n"
"SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n"
"\t\tvoid __user *, arg)\n"
"{\n"
"#ifdef CONFIG_KSU\n"
"\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
"#endif\n"
"\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);", "kernel/reboot.c")

patch("kernel/sys.c",
"SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)\n"
"{\n"
"\tstruct user_namespace *ns = current_user_ns();",
"#ifdef CONFIG_KSU\n"
"extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n"
"#endif\n"
"\n"
"SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)\n"
"{\n"
"#ifdef CONFIG_KSU\n"
"\tksu_handle_setresuid(ruid, euid, suid);\n"
"#endif\n"
"\tstruct user_namespace *ns = current_user_ns();", "kernel/sys.c")

patch("drivers/input/input.c",
"static void input_handle_event(struct input_dev *dev,\n"
"\t\t\t       unsigned int type, unsigned int code, int value)\n"
"{\n"
"\tint disposition = input_get_disposition(dev, type, code, &value);",
"#ifdef CONFIG_KSU\n"
"extern int ksu_handle_input_handle_event(unsigned int *type,\n"
"\t\t\t\t\t unsigned int *code, int *value);\n"
"#endif\n"
"\n"
"static void input_handle_event(struct input_dev *dev,\n"
"\t\t\t       unsigned int type, unsigned int code, int value)\n"
"{\n"
"#ifdef CONFIG_KSU\n"
"\tksu_handle_input_handle_event(&type, &code, &value);\n"
"#endif\n"
"\tint disposition = input_get_disposition(dev, type, code, &value);",
"drivers/input/input.c")
PY

# ------------------------------------------------------- 4. SUSFS core files
if [[ ! -f fs/susfs.c ]]; then
    log "fetching SUSFS v2.3.0 core ($SUSFS_CORE_REF)"
    fetch_pinned "$SUSFS_CORE_REPO" "$SUSFS_CORE_REF" "$SUSFS_CORE_DIR" \
        || die "cannot fetch SUSFS core"
    cp "$SUSFS_CORE_DIR/kernel_patches/fs/susfs.c"                 fs/susfs.c
    cp "$SUSFS_CORE_DIR/kernel_patches/include/linux/susfs.h"     include/linux/susfs.h
    cp "$SUSFS_CORE_DIR/kernel_patches/include/linux/susfs_def.h" include/linux/susfs_def.h
    log "SUSFS core installed"
else
    log "fs/susfs.c already present, skipping"
fi

# --------------------------------------------- 5. SUSFS 4.14 kernel patch
# The native 4.14 patch leaves exactly two hunks rejected on this tree, both
# because the tree carries Xiaomi/openela FAKE_UNAME bpfloader code:
#   * fs/proc/task_mmu.c (include hunk) -- re-applied by stage 6
#     (susfs_414_reconcile.py).
#   * kernel/sys.c (SPOOF_UNAME in newuname)   -- re-applied by stage 6.5 here.
if ! grep -q 'susfs' fs/Makefile; then
    log "fetching SUSFS 4.14 kernel patch ($SUSFS_PATCH_REF)"
    fetch_pinned "$SUSFS_PATCH_REPO" "$SUSFS_PATCH_REF" "$SUSFS_PATCH_DIR" \
        || die "cannot fetch SUSFS 4.14 patch (GitHub unreachable, or set SUSFS_PATCH_REPO to a gitlab mirror)"
    log "applying SUSFS 4.14 kernel patch"
    patch -p1 --forward < "$SUSFS_PATCH_DIR/kernel_patches/50_add_susfs_in_kernel-4.14.patch" \
        || log "patch reported rejects (expected: 2, re-applied in stages 6 and 6.5)"
else
    log "SUSFS kernel patch already applied"
fi

# ------------------------------------- 6. RECONCILE v1.5.5 patch <-> v2.3.0 core
# This is the stage that makes the build link. It:
#   * adds compat wrappers for the v1.5.5-named functions the patch calls
#   * rewrites fs/readdir.c to the v2.3.0 ilookup()/inode-flag style
#   * moves i_state bit tests to i_mapping->flags (v2.3.0 scheme)
#   * replaces current->susfs_task_state tests with the v2.3.0 helper
#   * fixes the fsnotify handle_event / fsnotify_add_mark 4.14 signatures
#   * adds the missing declarations and includes
RECONCILE="scripts/susfs_414_reconcile.py"
[[ -f "$RECONCILE" ]] || die "$RECONCILE missing (must be committed to the repo)"
log "reconciling v1.5.5 patch with v2.3.0 core"
python3 "$RECONCILE" || die "reconcile failed"

# --------------------------- 6.5. SUSFS SPOOF_UNAME hook for newuname
# The patch's kernel/sys.c hunk cannot apply: the tree's newuname() carries the
# Xiaomi/openela FAKE_UNAME bpfloader block between memcpy() and up_read().
# Without this stage, CONFIG_KSU_SUSFS_SPOOF_UNAME=y compiles but uname spoof is
# silently inert (susfs_spoof_uname never runs). Insert the same hook the hunk
# would have added, right before up_read().
python3 - <<'PY'
import sys
p = "kernel/sys.c"
s = open(p).read()
if "susfs_spoof_uname" in s:
    print("[sukisu] SPOOF_UNAME hook already present")
    sys.exit(0)
extern = ("#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
          "extern void susfs_spoof_uname(struct new_utsname *tmp);\n"
          "#endif\n"
          "SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)\n"
          "{")
old_extern = "SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)\n{"
if old_extern not in s:
    sys.exit("[sukisu] ERROR: newuname anchor missing")
s = s.replace(old_extern, extern, 1)
old_call = ("#endif\n"
            "\tup_read(&uts_sem);\n"
            "\tif (copy_to_user(name, &tmp, sizeof(tmp)))\n"
            "\t\treturn -EFAULT;\n"
            "\n"
            "\tif (override_release(")
new_call = ("#endif\n"
            "#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
            "\tsusfs_spoof_uname(&tmp);\n"
            "#endif\n"
            "\tup_read(&uts_sem);\n"
            "\tif (copy_to_user(name, &tmp, sizeof(tmp)))\n"
            "\t\treturn -EFAULT;\n"
            "\n"
            "\tif (override_release(")
if old_call not in s:
    sys.exit("[sukisu] ERROR: uts_sem anchor missing")
s = s.replace(old_call, new_call, 1)
open(p, "w").write(s)
print("[sukisu] SPOOF_UNAME hook installed (extern + call before up_read)")
PY

rm -f fs/proc/task_mmu.c.rej kernel/sys.c.rej
find . -name '*.orig' -delete 2>/dev/null || true

# ------------------------------------------------------------- 7. defconfig
# SUSFS_DISABLE lets CI bisect SUSFS without editing the script: pass a
# space-separated list of symbols to turn off (e.g.
#   SUSFS_DISABLE="CONFIG_KSU_SUSFS_SUS_MOUNT"
# or "CONFIG_KSU_SUSFS" to disable SUSFS entirely). The feature is then
# written as '# CONFIG_X is not set' because the Kconfig symbols default y.
python3 - <<'PY'
import os
DEFCONFIG = "arch/arm64/configs/vendor/xiaomi/miatoll_defconfig"
SUSFS_FEATURES = [
    "CONFIG_KSU_SUSFS_SUS_PATH",
    "CONFIG_KSU_SUSFS_SUS_MOUNT",
    "CONFIG_KSU_SUSFS_SUS_KSTAT",
    "CONFIG_KSU_SUSFS_SPOOF_UNAME",
    "CONFIG_KSU_SUSFS_ENABLE_LOG",
    "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS",
    "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG",
    "CONFIG_KSU_SUSFS_OPEN_REDIRECT",
    "CONFIG_KSU_SUSFS_SUS_MAP",
]
DISABLE = set(os.environ.get("SUSFS_DISABLE", "").split())
for d in list(DISABLE):
    if not d.startswith("CONFIG_KSU_SUSFS"):
        print("[sukisu] WARNING: SUSFS_DISABLE symbol %r is not a KSU_SUSFS symbol, ignoring" % d)
        DISABLE.discard(d)

lines = open(DEFCONFIG).read().splitlines()
# Drop any previously appended SUSFS block (idempotent reruns); keep everything
# else, including the SukiSU Nova block added by the very same script.
lines = [l for l in lines
         if l != "# --- SUSFS v2.3.0 (kernel-level root hiding) ---"
         and not l.startswith("CONFIG_KSU_SUSFS")
         and not l.startswith("# CONFIG_KSU_SUSFS")]
text = "\n".join(lines).rstrip("\n") + "\n"

if "CONFIG_KSU=y" not in text:
    nova = "\n# --- SukiSU Nova (kernel-level root) ---\n" + "\n".join([
        "CONFIG_KSU=y",
        "CONFIG_KSU_FEATURE_ADBROOT=y",
        "# CONFIG_KSU_DEBUG is not set",
        "# CONFIG_KPM is not set",
        "CONFIG_KALLSYMS=y",
        "CONFIG_KALLSYMS_ALL=y",
        "CONFIG_KPROBES=y",
    ]) + "\n"
    text += nova
    print("[sukisu] Nova defconfig symbols appended")

if "CONFIG_KSU_SUSFS" in DISABLE:
    block = ["# CONFIG_KSU_SUSFS is not set",
             "# CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER is not set"] + \
            ["# %s is not set" % f for f in SUSFS_FEATURES]
else:
    block = ["CONFIG_KSU_SUSFS=y"]
    for f in SUSFS_FEATURES:
        block.append("# %s is not set" % f if f in DISABLE else "%s=y" % f)
    block.append("# CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER is not set")
text += "\n# --- SUSFS v2.3.0 (kernel-level root hiding) ---\n" + "\n".join(block) + "\n"
open(DEFCONFIG, "w").write(text)
print("[sukisu] defconfig SUSFS symbols written (disabled: %s)" %
      (", ".join(sorted(DISABLE)) or "none"))
PY

# ---------------------------------------------------------------- 8. verify
is_disabled() { case " ${SUSFS_DISABLE:-} " in *" $1 "*) return 0;; *) return 1;; esac; }
# Disabling the master symbol disables every feature with it.
susfs_disabled() { is_disabled CONFIG_KSU_SUSFS || is_disabled "$1"; }

log "verifying"
for sym in CONFIG_KSU=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y CONFIG_KPROBES=y; do
    grep -qx "$sym" "$DEFCONFIG" || die "defconfig missing $sym"
done
for sym in CONFIG_KSU_SUSFS=y CONFIG_KSU_SUSFS_SUS_PATH=y CONFIG_KSU_SUSFS_SUS_MOUNT=y \
           CONFIG_KSU_SUSFS_SUS_KSTAT=y CONFIG_KSU_SUSFS_SPOOF_UNAME=y \
           CONFIG_KSU_SUSFS_OPEN_REDIRECT=y CONFIG_KSU_SUSFS_SUS_MAP=y; do
    if susfs_disabled "${sym%%=*}"; then
        log "skipping disabled ${sym%%=*}"
        continue
    fi
    grep -qx "$sym" "$DEFCONFIG" || die "defconfig missing $sym"
done
for f in fs/exec.c fs/open.c kernel/reboot.c kernel/sys.c drivers/input/input.c; do
    grep -q 'ksu_handle' "$f" || die "hook missing in $f"
done
grep -q 'susfs_spoof_uname' kernel/sys.c || die "SPOOF_UNAME hook missing in kernel/sys.c (stage 6.5 did not run)"
if is_disabled CONFIG_KSU_SUSFS; then
    log "SUSFS disabled via SUSFS_DISABLE; skipping SUSFS source checks"
    if [[ "${1:-}" == "--check" ]]; then
        log "check-only mode, done"
    fi
    exit 0
fi
[[ -f fs/susfs.c ]] || die "fs/susfs.c missing"
grep -q 'susfs' fs/Makefile || die "fs/Makefile not wired for susfs"
grep -q 'SUSFS_VERSION' include/linux/susfs.h || die "susfs.h missing version"
grep -q '4.14 compat layer' fs/susfs.c || die "compat layer missing (stage 6 did not run)"
grep -q 'fsnotify_iter_info' fs/susfs.c || die "fsnotify signature not fixed"
grep -q 'static_key_enabled(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)' fs/susfs.c || die "cmdline spoof gate missing (stage 10 BOOTLOOP FIX did not run)"
grep -q 'static_branch_unlikely' fs/proc/cmdline.c || die "cmdline.c static-key fall-through missing (stage 10 BOOTLOOP FIX did not run)"
grep -q 'susfs_is_inode_sus_path' fs/readdir.c || die "readdir.c not reconciled"
! grep -rq 'INODE_STATE_SUS_PATH' fs/ || die "v1.5.5 i_state guards remain"
log "SUSFS version: $(grep -E '^#define SUSFS_VERSION' include/linux/susfs.h | cut -d' ' -f3)"
log "all checks passed"

if [[ "${1:-}" == "--check" ]]; then
    log "check-only mode, done"
fi
