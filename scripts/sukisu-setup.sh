#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# sukisu-setup.sh -- make the SukiSU Nova integration reproducible from a clean
# checkout. Run this BEFORE building (the CI workflow calls it automatically).
#
# It does four things, all idempotent:
#   1. clones SukiSU-Nova (builtin branch) and wires drivers/Makefile + Kconfig
#   2. applies two 4.14 compatibility fixes to the SukiSU source
#   3. applies the manual hook call sites to the kernel tree
#   4. verifies the result
#
# Usage: ./scripts/sukisu-setup.sh [--check]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

KSU_REPO="${KSU_REPO:-https://github.com/SukiSU-Nova/SukiSU-Nova}"
KSU_REF="${KSU_REF:-builtin}"
SETUP_URL="${SETUP_URL:-https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/builtin/kernel/setup.sh}"

log()  { printf '[sukisu] %s\n' "$*"; }
die()  { printf '[sukisu] ERROR: %s\n' "$*" >&2; exit 1; }

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

# ------------------------------------------------------------- 3b. defconfig
python3 - <<'PYEOF'
DEFCONFIG = "arch/arm64/configs/vendor/xiaomi/miatoll_defconfig"
WANT = [
    "CONFIG_KSU=y",
    "CONFIG_KSU_FEATURE_ADBROOT=y",
    "# CONFIG_KSU_DEBUG is not set",
    "# CONFIG_KPM is not set",
    "# CONFIG_KSU_SUSFS is not set",
    "CONFIG_KALLSYMS=y",
    "CONFIG_KALLSYMS_ALL=y",
    "CONFIG_KPROBES=y",
]
s = open(DEFCONFIG).read()
if "CONFIG_KSU=y" in s:
    print("[sukisu] defconfig already has KSU symbols")
else:
    block = "\n# --- SukiSU Nova (kernel-level root) ---\n" + "\n".join(WANT) + "\n"
    open(DEFCONFIG, "w").write(s.rstrip("\n") + "\n" + block)
    print("[sukisu] defconfig updated")
PYEOF

# ---------------------------------------------------------------- 4. verify
log "verifying"
DEFCONFIG="arch/arm64/configs/vendor/xiaomi/miatoll_defconfig"
for sym in CONFIG_KSU=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y CONFIG_KPROBES=y; do
    grep -qx "$sym" "$DEFCONFIG" || die "defconfig missing $sym"
done
for f in fs/exec.c fs/open.c kernel/reboot.c kernel/sys.c drivers/input/input.c; do
    grep -q 'ksu_handle' "$f" || die "hook missing in $f"
done
log "all checks passed"

if [[ "${1:-}" == "--check" ]]; then
    log "check-only mode, done"
fi
