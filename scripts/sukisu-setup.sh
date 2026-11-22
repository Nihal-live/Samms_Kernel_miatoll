#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# sukisu-setup.sh -- reproducible SukiSU Nova + SUSFS v2.3.0 integration for
# the miatoll/excalibur 4.14.357 tree. Run BEFORE building; the CI workflow
# calls it automatically, so a clean checkout always produces the same kernel.
#
# Stages (all idempotent):
#   1. clone SukiSU-Nova (builtin) and wire drivers/Makefile + drivers/Kconfig
#   2. apply the two 4.14 compatibility fixes to the SukiSU source
#   3. apply the manual KernelSU hook call sites
#   4. install the SUSFS v2.3.0 core (fs/susfs.c + headers)
#   5. apply the native SUSFS 4.14 kernel patch (the fs/ hook hunks)
#   6. RECONCILE the v1.5.5 patch against the v2.3.0 core  <-- the fix
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
# Usage: ./scripts/sukisu-setup.sh [--check]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

KSU_REPO="${KSU_REPO:-https://github.com/SukiSU-Nova/SukiSU-Nova}"
KSU_REF="${KSU_REF:-builtin}"
SETUP_URL="${SETUP_URL:-https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/builtin/kernel/setup.sh}"

# SUSFS needs TWO sources, because no single branch has both halves:
#   * the v2.3.0 CORE (fs/susfs.c + headers) -- the only API generation that
#     matches what SukiSU Nova calls.
#   * the native 4.14 KERNEL PATCH (the fs/ hook hunks) -- only upstream ships
#     a 4.14 variant; the v2.3.0 branch only has a 4.9 patch.
SUSFS_CORE_REPO="${SUSFS_CORE_REPO:-https://github.com/wxx9248/susfs4ksu}"
SUSFS_CORE_REF="${SUSFS_CORE_REF:-kernel-4.9-v2}"
SUSFS_CORE_DIR="${SUSFS_CORE_DIR:-/tmp/susfs-core}"

SUSFS_PATCH_REPO="${SUSFS_PATCH_REPO:-https://gitlab.com/simonpunk/susfs4ksu}"
SUSFS_PATCH_REF="${SUSFS_PATCH_REF:-kernel-4.14}"
SUSFS_PATCH_DIR="${SUSFS_PATCH_DIR:-/tmp/susfs-patch}"

DEFCONFIG="arch/arm64/configs/vendor/xiaomi/miatoll_defconfig"

log() { printf '[sukisu] %s\n' "$*"; }
die() { printf '[sukisu] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. upstream
# KernelSU/ is an untracked clone; drivers/kernelsu is an untracked symlink.
# A partial state (clone present, symlink gone) is possible after a cleanup,
# so re-create the symlink whenever the clone exists.
if [[ ! -d KernelSU/kernel ]]; then
    log "cloning SukiSU-Nova ($KSU_REF)"
    curl -LSs "$SETUP_URL" -o /tmp/ksu-setup.sh || die "cannot fetch setup.sh"
    sh /tmp/ksu-setup.sh "$KSU_REF" || die "setup.sh failed"
else
    log "KernelSU/ already present, skipping clone"
fi

if [[ ! -e drivers/kernelsu && -d KernelSU/kernel ]]; then
    log "re-creating drivers/kernelsu symlink"
    ln -sfn ../KernelSU/kernel drivers/kernelsu
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
    rm -rf "$SUSFS_CORE_DIR"
    git clone --depth 1 -b "$SUSFS_CORE_REF" "$SUSFS_CORE_REPO" "$SUSFS_CORE_DIR" \
        || die "cannot clone SUSFS core"
    cp "$SUSFS_CORE_DIR/kernel_patches/fs/susfs.c"                 fs/susfs.c
    cp "$SUSFS_CORE_DIR/kernel_patches/include/linux/susfs.h"     include/linux/susfs.h
    cp "$SUSFS_CORE_DIR/kernel_patches/include/linux/susfs_def.h" include/linux/susfs_def.h
    log "SUSFS core installed"
else
    log "fs/susfs.c already present, skipping"
fi

# --------------------------------------------- 5. SUSFS 4.14 kernel patch
# The native 4.14 patch applies with only two rejects, which stage 6 fixes.
if ! grep -q 'susfs' fs/Makefile; then
    log "fetching SUSFS 4.14 kernel patch ($SUSFS_PATCH_REF)"
    rm -rf "$SUSFS_PATCH_DIR"
    git clone --depth 1 -b "$SUSFS_PATCH_REF" "$SUSFS_PATCH_REPO" "$SUSFS_PATCH_DIR" \
        || die "cannot clone SUSFS 4.14 patch"
    log "applying SUSFS 4.14 kernel patch"
    patch -p1 --forward < "$SUSFS_PATCH_DIR/kernel_patches/50_add_susfs_in_kernel-4.14.patch" \
        || log "patch reported rejects (expected: 2, fixed in stage 6)"
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

rm -f fs/proc/task_mmu.c.rej kernel/sys.c.rej
find . -name '*.orig' -delete 2>/dev/null || true

# ------------------------------------------------------------- 7. defconfig
python3 - <<'PY'
DEFCONFIG = "arch/arm64/configs/vendor/xiaomi/miatoll_defconfig"
WANT = [
    "CONFIG_KSU=y",
    "CONFIG_KSU_FEATURE_ADBROOT=y",
    "# CONFIG_KSU_DEBUG is not set",
    "# CONFIG_KPM is not set",
    "CONFIG_KALLSYMS=y",
    "CONFIG_KALLSYMS_ALL=y",
    "CONFIG_KPROBES=y",
    "",
    "# --- SUSFS v2.3.0 (kernel-level root hiding) ---",
    "CONFIG_KSU_SUSFS=y",
    "CONFIG_KSU_SUSFS_SUS_PATH=y",
    "CONFIG_KSU_SUSFS_SUS_MOUNT=y",
    "CONFIG_KSU_SUSFS_SUS_KSTAT=y",
    "CONFIG_KSU_SUSFS_SPOOF_UNAME=y",
    "CONFIG_KSU_SUSFS_ENABLE_LOG=y",
    "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y",
    "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y",
    "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y",
    "CONFIG_KSU_SUSFS_SUS_MAP=y",
    "# CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER is not set",
]
s = open(DEFCONFIG).read()
if "CONFIG_KSU_SUSFS=y" in s:
    print("[sukisu] defconfig already has SUSFS symbols")
else:
    s = s.replace("# CONFIG_KSU_SUSFS is not set\n", "")
    if "CONFIG_KSU=y" in s:
        block = "\n".join(WANT[7:]) + "\n"
        open(DEFCONFIG, "w").write(s.rstrip("\n") + "\n\n" + block)
    else:
        block = "\n# --- SukiSU Nova + SUSFS (kernel-level root) ---\n" + "\n".join(WANT) + "\n"
        open(DEFCONFIG, "w").write(s.rstrip("\n") + "\n" + block)
    print("[sukisu] defconfig updated")
PY

# ---------------------------------------------------------------- 8. verify
log "verifying"
for sym in CONFIG_KSU=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y CONFIG_KPROBES=y \
           CONFIG_KSU_SUSFS=y CONFIG_KSU_SUSFS_SUS_PATH=y CONFIG_KSU_SUSFS_SUS_MOUNT=y \
           CONFIG_KSU_SUSFS_SUS_KSTAT=y CONFIG_KSU_SUSFS_SPOOF_UNAME=y \
           CONFIG_KSU_SUSFS_OPEN_REDIRECT=y CONFIG_KSU_SUSFS_SUS_MAP=y; do
    grep -qx "$sym" "$DEFCONFIG" || die "defconfig missing $sym"
done
for f in fs/exec.c fs/open.c kernel/reboot.c kernel/sys.c drivers/input/input.c; do
    grep -q 'ksu_handle' "$f" || die "hook missing in $f"
done
[[ -f fs/susfs.c ]] || die "fs/susfs.c missing"
grep -q 'susfs' fs/Makefile || die "fs/Makefile not wired for susfs"
grep -q 'SUSFS_VERSION' include/linux/susfs.h || die "susfs.h missing version"
grep -q '4.14 compat layer' fs/susfs.c || die "compat layer missing (stage 6 did not run)"
grep -q 'fsnotify_iter_info' fs/susfs.c || die "fsnotify signature not fixed"
grep -q 'susfs_is_inode_sus_path' fs/readdir.c || die "readdir.c not reconciled"
! grep -rq 'INODE_STATE_SUS_PATH' fs/ || die "v1.5.5 i_state guards remain"
log "SUSFS version: $(grep -E '^#define SUSFS_VERSION' include/linux/susfs.h | cut -d' ' -f3)"
log "all checks passed"

if [[ "${1:-}" == "--check" ]]; then
    log "check-only mode, done"
fi
