#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# sukisu-setup.sh -- reproducible SukiSU Nova + SUSFS integration for the
# miatoll/excalibur 4.14.357 tree. Run BEFORE building; the CI workflow calls
# it automatically, so a clean checkout always produces the same kernel.
#
# Stages (all idempotent):
#   1. clone SukiSU-Nova (builtin) and wire drivers/Makefile + drivers/Kconfig
#   2. apply the two 4.14 compatibility fixes to the SukiSU source
#   3. apply the manual KernelSU hook call sites
#   4. install SUSFS v2.3.0 core files (fs/susfs.c + headers)
#   5. apply the SUSFS 4.14 kernel patch, hand-fixing the two known rejects
#   6. apply the 4.14 backport shim + fsnotify signature fixes
#   7. set the defconfig symbols
#   8. verify
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
#     matches what SukiSU Nova calls. The upstream kernel-4.14 branch is stale
#     at v1.5.5 and is NOT compatible (11 of 15 symbols missing).
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
if [[ ! -d KernelSU/kernel ]]; then
    log "cloning SukiSU-Nova ($KSU_REF)"
    curl -LSs "$SETUP_URL" -o /tmp/ksu-setup.sh || die "cannot fetch setup.sh"
    sh /tmp/ksu-setup.sh "$KSU_REF" || die "setup.sh failed"
else
    log "KernelSU/ already present, skipping clone"
fi

[[ -L drivers/kernelsu || -d drivers/kernelsu ]] || die "drivers/kernelsu symlink missing"
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
# The native 4.14 patch applies with only two rejects, which we fix below.
if ! grep -q 'susfs' fs/Makefile; then
    log "fetching SUSFS 4.14 kernel patch ($SUSFS_PATCH_REF)"
    rm -rf "$SUSFS_PATCH_DIR"
    git clone --depth 1 -b "$SUSFS_PATCH_REF" "$SUSFS_PATCH_REPO" "$SUSFS_PATCH_DIR" \
        || die "cannot clone SUSFS 4.14 patch"
    log "applying SUSFS 4.14 kernel patch"
    patch -p1 --forward < "$SUSFS_PATCH_DIR/kernel_patches/50_add_susfs_in_kernel-4.14.patch" \
        || log "patch reported rejects (expected: 2, fixed below)"
else
    log "SUSFS kernel patch already applied"
fi

# --- reject 1: fs/proc/task_mmu.c include ---
python3 - <<'PY'
p = "fs/proc/task_mmu.c"
s = open(p).read()
if "susfs_def.h" in s:
    print("[sukisu] task_mmu include already present")
else:
    old = "#include <linux/mm_inline.h>\n"
    new = ("#include <linux/mm_inline.h>\n"
           "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n"
           "#include <linux/susfs_def.h>\n"
           "#endif\n")
    if old not in s:
        raise SystemExit("[sukisu] ERROR: task_mmu anchor missing")
    open(p, "w").write(s.replace(old, new, 1))
    print("[sukisu] task_mmu include added")
PY

# --- reject 2: kernel/sys.c newuname spoof ---
python3 - <<'PY'
p = "kernel/sys.c"
s = open(p).read()
if "susfs_spoof_uname" in s:
    print("[sukisu] newuname hook already present")
else:
    old = ("SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)\n"
           "{\n"
           "\tstruct new_utsname tmp;\n"
           "\n"
           "\tdown_read(&uts_sem);\n"
           "\tmemcpy(&tmp, utsname(), sizeof(tmp));\n")
    new = ("#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
           "extern void susfs_spoof_uname(struct new_utsname *tmp);\n"
           "#endif\n"
           "SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)\n"
           "{\n"
           "\tstruct new_utsname tmp;\n"
           "\n"
           "\tdown_read(&uts_sem);\n"
           "\tmemcpy(&tmp, utsname(), sizeof(tmp));\n"
           "#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
           "\tsusfs_spoof_uname(&tmp);\n"
           "#endif\n")
    if old not in s:
        raise SystemExit("[sukisu] ERROR: newuname anchor missing")
    open(p, "w").write(s.replace(old, new, 1))
    print("[sukisu] newuname hook added")
PY

rm -f fs/proc/task_mmu.c.rej kernel/sys.c.rej
find . -name '*.orig' -delete 2>/dev/null || true

# ------------------------------- 6. 4.14 backport shim + fsnotify signatures
python3 - <<'PY'
p = "include/linux/susfs_def.h"
s = open(p).read()

# (a) the 4.14 patch hunks use v1.5.5 macro names; map them onto v2.3.0.
if "SUSFS_414_COMPAT" not in s:
    shim = """
/* ===== 4.14 backport shim: v1.5.5 macro names used by the 4.14 patch hunks,
 * mapped onto the v2.3.0 AS_FLAGS_* / TIF_* scheme. ===== */
#define SUSFS_414_COMPAT 1
#ifndef DEFAULT_SUS_MNT_ID
#define DEFAULT_SUS_MNT_ID 100000
#endif
#ifndef DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE
#define DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE 1000000
#endif
#ifndef DEFAULT_SUS_MNT_GROUP_ID
#define DEFAULT_SUS_MNT_GROUP_ID 1000
#endif
#ifndef INODE_STATE_SUS_PATH
#define INODE_STATE_SUS_PATH AS_FLAGS_SUS_PATH
#endif
#ifndef INODE_STATE_SUS_MOUNT
#define INODE_STATE_SUS_MOUNT AS_FLAGS_SUS_MOUNT
#endif
#ifndef INODE_STATE_SUS_KSTAT
#define INODE_STATE_SUS_KSTAT AS_FLAGS_SUS_KSTAT
#endif
#ifndef INODE_STATE_OPEN_REDIRECT
#define INODE_STATE_OPEN_REDIRECT AS_FLAGS_OPEN_REDIRECT
#endif
#ifndef TASK_STRUCT_NON_ROOT_USER_APP_PROC
#define TASK_STRUCT_NON_ROOT_USER_APP_PROC TIF_PROC_UMOUNTED
#endif
"""
    s = s.replace("#endif // #ifndef KSU_SUSFS_DEF_H",
                  shim + "\n#endif // #ifndef KSU_SUSFS_DEF_H")
    print("[sukisu] 4.14 macro shim added")
else:
    print("[sukisu] 4.14 macro shim already present")

# (b) current_uid()/sched.h are needed by the inline helpers.
if "#include <linux/cred.h>" not in s:
    old = "#include <linux/bits.h>\n#include <linux/string.h>\n"
    new = ("#include <linux/bits.h>\n#include <linux/string.h>\n"
           "#include <linux/cred.h>\n#include <linux/sched.h>\n")
    if old in s:
        s = s.replace(old, new, 1)
        print("[sukisu] cred/sched includes added")
    else:
        print("[sukisu] WARN: include anchor missing")
open(p, "w").write(s)
PY

# (c) fsnotify changed between 4.9 and 4.14: handle_event gained
#     `const void *data` + `iter_info`, and fsnotify_add_mark lost the group arg.
python3 - <<'PY'
p = "fs/susfs.c"
s = open(p).read()
changed = False

old_a = ("\tu32 mask, void *data, int data_type,\n"
         "\tconst unsigned char *file_name, u32 cookie)\n{\n")
new_a = ("\tu32 mask, const void *data, int data_type,\n"
         "\tconst unsigned char *file_name, u32 cookie,\n"
         "\tstruct fsnotify_iter_info *iter_info)\n{\n")
if old_a in s:
    s = s.replace(old_a, new_a, 1); changed = True
    print("[sukisu] fsnotify handle_event signature fixed")

old_b = ("\tfsnotify_init_mark(m, NULL);\n"
         "\tm->mask = mask;\n"
         "\tif (fsnotify_add_mark(m, g, inode, NULL, 0)) {\n")
new_b = ("\tfsnotify_init_mark(m, g);\n"
         "\tm->mask = mask;\n"
         "\tif (fsnotify_add_mark(m, inode, NULL, 0)) {\n")
if old_b in s:
    s = s.replace(old_b, new_b, 1); changed = True
    print("[sukisu] fsnotify_add_mark signature fixed")

if changed:
    open(p, "w").write(s)
else:
    print("[sukisu] fsnotify signatures already fixed")
PY

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
    # drop the old "not set" line if the KSU block is already there
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
grep -q 'SUSFS_414_COMPAT' include/linux/susfs_def.h || die "4.14 shim missing"
grep -q 'fsnotify_iter_info' fs/susfs.c || die "fsnotify signature not fixed"
log "SUSFS version: $(grep -E '^#define SUSFS_VERSION' include/linux/susfs.h | cut -d' ' -f3)"
log "all checks passed"

if [[ "${1:-}" == "--check" ]]; then
    log "check-only mode, done"
fi
