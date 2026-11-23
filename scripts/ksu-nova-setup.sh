#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ksu-nova-setup.sh -- reproducible SukiSU-Nova integration for the miatoll
# Linux 4.14.357 tree.
#
# Everything below is applied to a *clean checkout* on every run, so the build
# is reproducible and nothing depends on someone's dirty working tree. Run it
# before scripts/build.sh; the CI workflow does that automatically.
#
#   ./scripts/ksu-nova-setup.sh            apply + verify
#   ./scripts/ksu-nova-setup.sh --check    verify only, change nothing
#
# WHAT GETS INSTALLED
#   SukiSU-Nova (branch `builtin`) at a pinned commit -- the source-integrated
#   tree, i.e. the kernel calls ksu_handle_*() directly instead of relying on
#   kprobes (kprobes are unreliable on 4.x).
#
#   No SUSFS. Root hiding (SUSFS) is deliberately *not* part of this kernel:
#   it needs a kernel-side port that no upstream branch ships for 4.14 with the
#   API SukiSU-Nova calls, and a half-ported root-hiding layer is exactly the
#   kind of thing that turns a working root into an unstable device. What this
#   script touches outside drivers/ is: the manual hook call sites (section
#   4), the KPM syscall-wrapper stub (section 3.5) and the SELinux support
#   file behind "hide SELinux modification" and AVC log spoofing (section
#   3.6), which replaces SUSFS's share of those two features.
#
# WHY A PINNED COMMIT
#   `builtin` moves. Every KernelSU setup.sh ends its checkout with
#   `git checkout "$1" || echo "checkout default branch"`, so a stale branch
#   name does not fail -- it silently leaves you on the default branch and you
#   ship a kernel with none of what you asked for. This script resolves the ref
#   first and compares HEAD afterwards.
#
# Everything is idempotent: re-running over an already-patched tree reports
# "already applied" instead of failing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Auto-detect the kernel root: repository root, or kernel/ before the flatten
# workflow has run. The integration is identical either way.
if [[ -f "$REPO_ROOT/Makefile" && -f "$REPO_ROOT/arch/arm64/Makefile" ]]; then
    KERNEL_DIR="$REPO_ROOT"
else
    KERNEL_DIR="$REPO_ROOT/kernel"
fi

KSU_REPO="${KSU_REPO:-https://github.com/SukiSU-Nova/SukiSU-Nova}"
# Pinned 2026-11-16, "bump Version Number". Override with a tag or another
# commit if you know what you are doing; a branch name is accepted too, but it
# makes the build non-reproducible and the log will say so.
KSU_REF="${KSU_REF:-4bec532dd447e2852aa8932afa768255350c103a}"
KSU_DIR="${KSU_DIR:-KernelSU}"

DEFCONFIG="${DEFCONFIG:-arch/arm64/configs/vendor/xiaomi/miatoll_defconfig}"

MODE=apply
for arg in "$@"; do
    case "$arg" in
        --check)   MODE=check ;;
        -h|--help) sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
    esac
done

log()  { printf '[ksu-nova] %s\n' "$*"; }
ok()   { printf '[ksu-nova]   ok: %s\n' "$*"; }
warn() { printf '[ksu-nova]   warn: %s\n' "$*" >&2; }
die()  { printf '[ksu-nova] ERROR: %s\n' "$*" >&2; exit 1; }

cd "$KERNEL_DIR"

# --------------------------------------------------------------- 0. sanity ---

KVER="$(sed -n -e 's/^VERSION = //p' -e 's/^PATCHLEVEL = //p' Makefile | paste -sd. -)"
[[ "$KVER" == "4.14" ]] || die "this integration targets Linux 4.14, found $KVER"
[[ -f "$DEFCONFIG" ]] || die "defconfig not found: $DEFCONFIG"
ok "kernel $KVER, defconfig $DEFCONFIG"

# ------------------------------------------------------------- 1. SukiSU-Nova

# A 40/12/7-hex ref is a commit, not a branch: ls-remote cannot resolve it, so
# it is validated by the fetch itself and then by comparing HEAD.
is_commit_ref() { [[ "${1:-}" =~ ^[0-9a-f]{7,40}$ ]]; }

resolve_ref() {
    local out
    out=$(git ls-remote "$KSU_REPO" \
            "refs/heads/$KSU_REF" "refs/tags/$KSU_REF" "refs/tags/$KSU_REF^{}" \
            2>/dev/null) || return 0
    printf '%s\n' "$out" | awk 'NR==1{print $1}'
}

if [[ "$MODE" == check ]]; then
    [[ -d "$KSU_DIR/kernel" ]] || die "$KSU_DIR/ is missing; run without --check"
    HEAD_SHA="$(git -C "$KSU_DIR" rev-parse HEAD)"
    ok "SukiSU-Nova present at $HEAD_SHA"
else
    WANT_SHA=""
    if is_commit_ref "$KSU_REF"; then
        ok "ref '$KSU_REF' is a pinned commit (validated by the fetch)"
    else
        WANT_SHA="$(resolve_ref)"
        if [[ -z "$WANT_SHA" ]]; then
            die "ref '$KSU_REF' does not exist in $KSU_REPO.
       Available branches:
$(git ls-remote --heads "$KSU_REPO" 2>/dev/null | awk '{print "         " $2}' | sed 's@refs/heads/@@' | grep -v dependabot)
       Pick a branch/tag/commit and re-run with KSU_REF=<ref>."
        fi
        ok "ref '$KSU_REF' -> $WANT_SHA"
        warn "KSU_REF is a moving ref; pin a commit for reproducible builds"
    fi

    if [[ -d "$KSU_DIR/kernel" ]]; then
        HEAD_SHA="$(git -C "$KSU_DIR" rev-parse HEAD)"
        if [[ -n "$WANT_SHA" && "$HEAD_SHA" != "$WANT_SHA" ]]; then
            log "checkout at $HEAD_SHA does not match $KSU_REF; re-fetching"
            rm -rf "$KSU_DIR"
        elif [[ -z "$WANT_SHA" && "$HEAD_SHA" != "$KSU_REF" ]]; then
            log "checkout at $HEAD_SHA does not match $KSU_REF; re-fetching"
            rm -rf "$KSU_DIR"
        fi
    fi

    if [[ ! -d "$KSU_DIR/kernel" ]]; then
        log "fetching SukiSU-Nova ($KSU_REF)"
        rm -rf "$KSU_DIR"
        mkdir -p "$KSU_DIR"
        git -C "$KSU_DIR" init -q .
        git -C "$KSU_DIR" remote add origin "$KSU_REPO"
        # --depth 1 on a SHA: GitHub allows fetching an arbitrary reachable
        # commit, so a pinned build stays a one-commit download.
        git -C "$KSU_DIR" fetch -q --depth 1 origin "$KSU_REF" \
            || die "cannot fetch '$KSU_REF' from $KSU_REPO.
       It is not a branch, tag or reachable commit. Branches:
$(git ls-remote --heads "$KSU_REPO" 2>/dev/null | awk '{print "         " $2}' | sed 's@refs/heads/@@' | grep -v dependabot)"
        git -C "$KSU_DIR" checkout -q FETCH_HEAD
    fi

    HEAD_SHA="$(git -C "$KSU_DIR" rev-parse HEAD)"
    # Catches the silent fallback for refs that are branches, and a wrong
    # commit for pinned ones.
    if [[ -n "$WANT_SHA" && "$HEAD_SHA" != "$WANT_SHA" ]]; then
        die "checked out $HEAD_SHA, expected $WANT_SHA for ref '$KSU_REF'"
    fi
    if is_commit_ref "$KSU_REF" && [[ "$HEAD_SHA" != "$KSU_REF" ]]; then
        die "checked out $HEAD_SHA, expected $KSU_REF"
    fi
    ok "SukiSU-Nova checked out at $HEAD_SHA"
fi

[[ -f "$KSU_DIR/kernel/Kconfig" ]] || die "$KSU_DIR/kernel/Kconfig missing"
[[ -f "$KSU_DIR/kernel/Makefile" ]] || die "$KSU_DIR/kernel/Makefile missing"

# ------------------------------------------------------------ 2. KSU wiring ---
#
# Wiring goes into tracked files, so it is re-applied whenever it is missing
# (a `git checkout` can undo it while the untracked clone survives).

if [[ ! -e drivers/kernelsu ]]; then
    if [[ "$MODE" == check ]]; then die "drivers/kernelsu symlink missing"; fi
    log "creating drivers/kernelsu -> ../$KSU_DIR/kernel"
    ln -sfn "../$KSU_DIR/kernel" drivers/kernelsu
fi
[[ -d drivers/kernelsu ]] || die "drivers/kernelsu does not point at $KSU_DIR/kernel"

if [[ "$MODE" != check ]]; then
    # setup.sh only greps for the word "kernelsu", so a vendor tree that
    # carries a stale `obj-$(CONFIG_WITH_KERNEL_SU) += kernelsu/` line makes it
    # report success without ever adding the CONFIG_KSU rule. The build then
    # fails at the final link with every ksu_handle_* symbol undefined.
    if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' drivers/Makefile; then
        if grep -qE '^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' drivers/Makefile; then
            sed -i -E 's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' drivers/Makefile
            warn "normalized stale drivers/Makefile guard to CONFIG_KSU"
        else
            log "wiring drivers/Makefile"
            printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
        fi
    fi
    if ! grep -qF 'drivers/kernelsu/Kconfig' drivers/Kconfig; then
        log "wiring drivers/Kconfig"
        # Appended, not inserted before the first `endmenu`: two `endmenu`
        # lines exist in some vendor trees and sed would split the menu.
        printf '\nsource "drivers/kernelsu/Kconfig"\n' >> drivers/Kconfig
    fi
fi
grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' drivers/Makefile \
    || die "drivers/Makefile is not wired for CONFIG_KSU"
grep -qF 'drivers/kernelsu/Kconfig' drivers/Kconfig \
    || die "drivers/Kconfig is not wired for config KSU"
ok "drivers/Makefile + drivers/Kconfig wired"

# ------------------------------------------- 3. SukiSU-Nova 4.14 fixes -------
#
# Five upstream conditionals are wrong for 4.14, and KPM's 5.10 assumptions are
# ported rather than avoided. Each edit is guarded so that this step fails
# loudly when upstream rewrites the surrounding code.

if [[ "$MODE" != check ]]; then
    python3 - "$KSU_DIR/kernel/kernel_includes.h" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

guard = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
         "#include <linux/static_call.h>\n"
         "#endif\n")
plain = "#include <linux/static_call.h>\n"

if guard in src:
    print("[ksu-nova]   static_call include already guarded")
elif plain in src:
    # include/linux/static_call.h does not exist before 5.10. The header is
    # included for KPM's static-call based hooks, which are compiled out on
    # 4.14 anyway, so the include can simply be dropped there.
    open(path, "w").write(src.replace(plain, guard, 1))
    print("[ksu-nova]   guarded linux/static_call.h include for < 5.10")
else:
    sys.exit("[ksu-nova] ERROR: static_call include anchor missing in "
             + path + " (upstream changed)")
PY

    python3 - "$KSU_DIR/kernel/kernel_compat.h" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

want = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 4, 0)\n"
        "#define KSU_CAN_USE_KPM\n"
        "#endif\n")
raised = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
          "#define KSU_CAN_USE_KPM\n"
          "#endif\n")

if raised in src:
    # An earlier version of this script raised the guard to 5.10 to keep KPM's
    # dead code dead. KPM is wanted now, and section 3.4 makes it compile on
    # 4.14, so put upstream's guard back.
    open(path, "w").write(src.replace(raised, want, 1))
    print("[ksu-nova]   KPM guard restored to 4.4.0")
elif want in src:
    print("[ksu-nova]   KPM guard already >= 4.4")
else:
    sys.exit("[ksu-nova] ERROR: KPM guard anchor missing in " + path
             + " (upstream changed)")
PY
fi

grep -q 'KSU_CAN_USE_KPM' "$KSU_DIR/kernel/kernel_compat.h" || die "KPM guard vanished"

# -- 3.4 KPM on 4.14 ---------------------------------------------------------
#
# With the guard back at 4.4 the KPM sources are compiled on 4.14, and three
# of them assume newer kernels. Each is a real port, not a bypass:
#
#   * access_ok() lost its access-type argument in 5.0.
#   * struct task_struct lost `pids[PIDTYPE_PID].pid` in 4.19 in favour of
#     thread_pid. This vendor tree already carries the 4.19 layout on 4.14, so
#     the version test picks the wrong member; the KernelSU Makefile probes the
#     header and defines KSU_TASK_HAS_THREAD_PID, exactly like the other
#     vendor-backport probes it already has.
#   * the KPM bridge calls KernelPatch's supercall through the truncate syscall
#     handler. `__arm64_sys_*` wrappers only exist from 4.17, so on 4.14 the
#     bridge has to reach the same function through sys_call_table
#     (__NR_truncate) or the sys_truncate symbol.

if [[ "$MODE" != check ]]; then
    python3 - "$KSU_DIR/kernel/extension/kpm/kpm.c" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

def once(src, old, new, label):
    if new in src:
        print("[ksu-nova]   " + label + ": already applied")
        return src
    if old not in src:
        sys.exit("[ksu-nova] ERROR: " + label + " anchor missing in " + path
                 + " (upstream changed)")
    print("[ksu-nova]   " + label)
    return src.replace(old, new, 1)

src = once(
    src,
    "    if (!access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))) return -EFAULT;\n",

    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n"
    "    if (!access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))) return -EFAULT;\n"
    "#else\n"
    "    /* access_ok() takes the access type before 5.0. */\n"
    "    if (!access_ok(VERIFY_WRITE, u64_to_user_ptr(cmd.result_code),\n"
    "                   sizeof(result)))\n"
    "        return -EFAULT;\n"
    "#endif\n",
    "ported access_ok() to the pre-5.0 form")

src = once(
    src,
    "        if (!fn) fn = (handler_t)find_kernel_symbol_exact(\"__arm64_sys_truncate.cfi\");\n"
    "        if (!fn) return -EOPNOTSUPP;\n",

    "        if (!fn) fn = (handler_t)find_kernel_symbol_exact(\"__arm64_sys_truncate.cfi\");\n"
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)\n"
    "        /*\n"
    "         * 4.14 has no __arm64_sys_* wrappers. Resolve the truncate\n"
    "         * handler the way this kernel exposes it: through\n"
    "         * sys_call_table (so a hook installed at the table level is\n"
    "         * still reached even if the function body was not patched),\n"
    "         * then through the plain symbol.\n"
    "         */\n"
    "        if (!fn) {\n"
    "            unsigned long *table = (unsigned long *)\n"
    "                find_kernel_symbol_exact(\"sys_call_table\");\n"
    "            if (table && table[__NR_truncate])\n"
    "                fn = (handler_t)table[__NR_truncate];\n"
    "        }\n"
    "        if (!fn) fn = (handler_t)find_kernel_symbol_exact(\"sys_truncate\");\n"
    "        if (!fn) fn = (handler_t)find_kernel_symbol_exact(\"SyS_truncate\");\n"
    "#endif\n"
    "        if (!fn) return -EOPNOTSUPP;\n",
    "added the pre-4.17 truncate-handler lookup")

# __NR_truncate is spelled __NR3264_truncate on arm64 and may not be visible
# here at all; define it once, right before the ARM64 block that uses it.
if "SUKISU_KPM_NR_TRUNCATE_GUARD" not in src:
    anchor = "#ifdef CONFIG_ARM64\n#include <asm/ptrace.h>\n#endif\n"
    if anchor not in src:
        sys.exit("[ksu-nova] ERROR: arm64 include anchor missing in " + path
                 + " (upstream changed)")
    src = src.replace(
        anchor,
        anchor +
        "\n/* SUKISU_KPM_NR_TRUNCATE_GUARD: the syscall number of truncate as\n"
        " * this kernel spells it. arm64 calls it __NR3264_truncate. */\n"
        "#ifndef __NR_truncate\n"
        "#ifdef __NR3264_truncate\n"
        "#define __NR_truncate __NR3264_truncate\n"
        "#else\n"
        "#define __NR_truncate 45\n"
        "#endif\n"
        "#endif\n",
        1)
    print("[ksu-nova]   defined __NR_truncate for arm64")
else:
    print("[ksu-nova]   __NR_truncate guard: already applied")

open(path, "w").write(src)
PY

    python3 - "$KSU_DIR/kernel/extension/kpm/super_access.c" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

old = ("#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 19, 0)\n"
       "DEFINE_MEMBER(task_struct, pids[PIDTYPE_PID].pid)\n"
       "#else\n"
       "DEFINE_MEMBER(task_struct, thread_pid)\n"
       "#endif\n")
new = ("#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 19, 0) && \\\n"
       "    !defined(KSU_TASK_HAS_THREAD_PID)\n"
       "DEFINE_MEMBER(task_struct, pids[PIDTYPE_PID].pid)\n"
       "#else\n"
       "DEFINE_MEMBER(task_struct, thread_pid)\n"
       "#endif\n")

if new in src:
    print("[ksu-nova]   task_struct pid member: already applied")
elif old in src:
    open(path, "w").write(src.replace(old, new, 1))
    print("[ksu-nova]   task_struct pid member honours KSU_TASK_HAS_THREAD_PID")
else:
    sys.exit("[ksu-nova] ERROR: task_struct pid member anchor missing in "
             + path + " (upstream changed)")
PY

    python3 - "$KSU_DIR/kernel/Makefile" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

block = """
# Some 4.x trees carry the 4.19 struct task_struct (thread_pid/pid_links)
# backported, so task_struct::pids is gone even though LINUX_VERSION_CODE still
# says 4.14. Probe the header instead of trusting the version, the same way the
# selinux/seccomp probes above do.
ifeq ($(shell grep -q 'struct pid[[:space:]]*\*thread_pid' $(srctree)/include/linux/sched.h; echo $$?),0)
ccflags-y += -DKSU_TASK_HAS_THREAD_PID
endif
"""

if "KSU_TASK_HAS_THREAD_PID" in src:
    print("[ksu-nova]   KSU_TASK_HAS_THREAD_PID probe: already present")
else:
    anchor = "# Check new vfs_getattr()\n"
    if anchor not in src:
        sys.exit("[ksu-nova] ERROR: vfs_getattr probe anchor missing in "
                 + path + " (upstream changed)")
    open(path, "w").write(src.replace(anchor, block.lstrip("\n") + "\n" + anchor, 1))
    print("[ksu-nova]   added KSU_TASK_HAS_THREAD_PID probe to the clone Makefile")
PY
fi

grep -q 'KSU_CAN_USE_KPM' "$KSU_DIR/kernel/kernel_compat.h" || die "KPM gate vanished"
grep -q 'VERIFY_WRITE' "$KSU_DIR/kernel/extension/kpm/kpm.c" \
    || die "KPM lost its pre-5.0 access_ok() form"
grep -q 'SUKISU_KPM_NR_TRUNCATE_GUARD' "$KSU_DIR/kernel/extension/kpm/kpm.c" \
    || die "KPM lost the arm64 truncate syscall number"
grep -q 'KSU_TASK_HAS_THREAD_PID' "$KSU_DIR/kernel/extension/kpm/super_access.c" \
    || die "super_access.c does not honour KSU_TASK_HAS_THREAD_PID"
grep -q 'KSU_TASK_HAS_THREAD_PID' "$KSU_DIR/kernel/Makefile" \
    || die "the clone Makefile does not define KSU_TASK_HAS_THREAD_PID"

# -- 3.5 KernelPatch's pre-4.17 detection ------------------------------------
#
# The KPM bridge is only half of KPM. The other half is the KernelPatch payload
# injected into the built image, and *it* decides whether to install the channel
# that answers the bridge:
#
#     int sukisu_kpm_supercall_install(void)
#     {
#         if (!has_syscall_wrapper) return -EOPNOTSUPP;          /* 4.14 stops here */
#         addr = kallsyms_lookup_name("__arm64_sys_truncate");   /* 4.17+ name */
#         ...
#     }
#
# has_syscall_wrapper is set by looking for __arm64_sys_openat, and the hook
# target is looked up as __arm64_sys_truncate. Neither symbol exists before
# 4.17, so on this kernel the payload logs
#
#     KP syscall has_wrapper: 0
#     KP sukisu_kpm_supercall_install done: -95
#
# and the manager greys KPM out while everything else works -- measured on the
# device, not guessed.
#
# Two stub symbols fix the detection without touching the payload: nothing in
# this kernel calls them, sys_call_table keeps pointing at sys_truncate and
# sys_openat, and the only caller of __arm64_sys_truncate becomes the KPM
# bridge, which the payload intercepts at the first instruction. If the hook is
# *not* installed the stub answers -ENOSYS, so the bridge reports "unavailable"
# exactly as it does today: the failure mode is the current behaviour, not a
# wrong answer and not a crash.

if [[ "$MODE" != check ]]; then
    cat > arch/arm64/kernel/kp_syswrap.c <<'KPEOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * kp_syswrap.c - the syscall-wrapper symbols KernelPatch looks for.
 *
 * KernelPatch's KPM channel is an inline hook on the truncate syscall wrapper.
 * Its payload decides whether it may install that hook by looking for
 * __arm64_sys_openat, then resolves __arm64_sys_truncate by name. Both symbols
 * arrived with the SYSCALL_DEFINE wrapper generation in 4.17; on this kernel
 * the payload therefore reports "has_wrapper: 0" and installs nothing.
 *
 * These stubs exist so the detection succeeds. Nothing in the kernel calls
 * them: sys_call_table still points at sys_truncate/sys_openat, and the only
 * caller of __arm64_sys_truncate is SukiSU's KPM bridge, which KernelPatch
 * intercepts before the first instruction runs. If the hook is not installed,
 * the stub answers -ENOSYS, which the bridge reports as "KPM unavailable" -
 * the same state as without this file.
 *
 * The padding nops are not decoration: the inline hook relocates the first
 * instructions of its target, and a bare "mov w0, #-38; ret" leaves it two.
 */
#include <linux/linkage.h>
#include <linux/ptrace.h>
#include <linux/errno.h>
#include <linux/compiler.h>
#include <linux/version.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)

asmlinkage long __arm64_sys_truncate(const struct pt_regs *regs);
asmlinkage long __arm64_sys_openat(const struct pt_regs *regs);

#define KP_SYSWRAP_PAD(regs)                                                  \
	asm volatile("nop; nop; nop; nop; nop; nop; nop; nop" ::"r"(regs)     \
		     : "memory")

asmlinkage __visible __used noinline long
__arm64_sys_truncate(const struct pt_regs *regs)
{
	KP_SYSWRAP_PAD(regs);
	return -ENOSYS;
}

asmlinkage __visible __used noinline long
__arm64_sys_openat(const struct pt_regs *regs)
{
	KP_SYSWRAP_PAD(regs);
	return -ENOSYS;
}

/*
 * LTO links this tree as one unit and is free to drop a function nothing calls.
 * Taking the addresses in a used array keeps both names in kallsyms, and the
 * build asserts that they are in System.map, so a toolchain that still manages
 * to remove them fails the build instead of shipping a kernel whose KPM panel
 * is silently dead.
 */
static void *const kp_syswrap_keep[] __used = {
	(void *)__arm64_sys_truncate,
	(void *)__arm64_sys_openat,
};

#endif /* < 4.17 */
KPEOF

    python3 - arch/arm64/kernel/Makefile <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()
line = "obj-$(CONFIG_KPM) += kp_syswrap.o\n"
if line in src:
    print("[ksu-nova]   kp_syswrap.o: already in arch/arm64/kernel/Makefile")
else:
    if not src.endswith("\n"):
        src += "\n"
    src += (
        "\n# KernelPatch's KPM channel needs the __arm64_sys_* names to exist;\n"
        "# see arch/arm64/kernel/kp_syswrap.c. Only built when KPM is enabled.\n" + line
    )
    open(path, "w").write(src)
    print("[ksu-nova]   added kp_syswrap.o to arch/arm64/kernel/Makefile")
PY
fi

[[ -f arch/arm64/kernel/kp_syswrap.c ]] \
    || die "arch/arm64/kernel/kp_syswrap.c was not created"
grep -q 'obj-\$(CONFIG_KPM) += kp_syswrap.o' arch/arm64/kernel/Makefile \
    || die "arch/arm64/kernel/Makefile does not build kp_syswrap.o"

# -- 3.3 CPU identity spoofing on 4.14 ---------------------------------------
#
# ksu_extension_cpu_spoof_io() is compiled out below 5.10, so the manager shows
# CPU identity spoofing as "Unsupported" and the setting cannot be used at all.
# The gate is a version check, not a missing implementation: the writes are
# driven by kallsyms lookups and differ only in *which* vDSO fields exist.
#
# What 4.14 lacks, and what this patch does about it:
#
#   * <vdso/datapage.h> does not exist (arm64 keeps the datapage in
#     asm/vdso_datapage.h), and struct vdso_data has no clock_mode at all -
#     it selects the fast path with ->use_syscall.
#   * struct clocksource has no vdso_clock_mode, and there is no vdso_default.
#   * ARM64_WORKAROUND_1418040 does not exist (it arrived with the Cortex-A76
#     erratum in 4.19), so there is no capability bit to clear - and clearing
#     bit 37 of a bitmap that is shorter than 38 bits would corrupt memory.
#   * elf_hwcap is a single unsigned long and there is no elf_hwcap2, so the
#     upstream write of elf_hwcap_bitmap[1] would clobber whatever follows it.
#
# Everything the spoof actually changes (MIDR in the per-cpu cpu_data, BogoMIPS
# via loops_per_jiffy, ELF AT_HWCAP via elf_hwcap) exists unchanged on 4.14, so
# those writes are kept verbatim.

if [[ "$MODE" != check ]]; then
    python3 - "$KSU_DIR/kernel/kernel_compat.h" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

want = ("/*\n"
        " * CPU identity spoofing is symbol-driven: every write it makes goes\n"
        " * through kallsyms, and the only version-dependent part is which vDSO\n"
        " * fields exist. cpu_spoof.c compiles the >= 4.18 vDSO writes out below\n"
        " * that, so the extension is sound on 4.14 as well; upstream only gates\n"
        " * it at 5.10 because it was never tried on a 4.x datapage.\n"
        " */\n"
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)\n"
        "#define KSU_CAN_USE_CPU_SPOOF\n"
        "#endif\n")
old = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
       "#define KSU_CAN_USE_CPU_SPOOF\n"
       "#endif\n")

if want in src:
    print("[ksu-nova]   cpu_spoof guard already lowered to 4.14")
elif old in src:
    open(path, "w").write(src.replace(old, want, 1))
    print("[ksu-nova]   lowered cpu_spoof guard from 5.10.0 to 4.14.0")
else:
    sys.exit("[ksu-nova] ERROR: cpu_spoof guard anchor missing in " + path
             + " (upstream changed)")
PY

    python3 - "$KSU_DIR/kernel/extension/cpu_spoof.c" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

def once(src, old, new, label):
    if new in src:
        print("[ksu-nova]   " + label + ": already applied")
        return src
    if old not in src:
        sys.exit("[ksu-nova] ERROR: " + label + " anchor missing in " + path
                 + " (upstream changed)")
    print("[ksu-nova]   " + label)
    return src.replace(old, new, 1)

# (a) the datapage header moved to include/vdso/ in 4.18.
src = once(
    src,
    "#include <asm/cpufeature.h>\n"
    "#include <vdso/datapage.h>\n"
    "#include <vdso/clocksource.h>\n",

    "#include <asm/cpufeature.h>\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 18, 0)\n"
    "#include <vdso/datapage.h>\n"
    "#include <vdso/clocksource.h>\n"
    "#else\n"
    "/* Before 4.18 the arm64 datapage is arch-local and has no clock_mode. */\n"
    "#include <asm/vdso_datapage.h>\n"
    "#endif\n",
    "guarded the vDSO datapage include")

# (b) elf_hwcap2 does not exist before 4.20 and elf_hwcap[1] would be a
#     one-element overflow.
src = once(
    src,
    "            elf_hwcap_bitmap[0] = cmd->hwcap;\n"
    "            elf_hwcap_bitmap[1] = cmd->hwcap2;\n",

    "            elf_hwcap_bitmap[0] = cmd->hwcap;\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n"
    "            elf_hwcap_bitmap[1] = cmd->hwcap2;\n"
    "#endif\n",
    "guarded the elf_hwcap2 write")

# (c) everything that only exists from 4.18 on: clock_mode, clocksource->
#     vdso_clock_mode, vdso_default and the A76 erratum capability.
src = once(
    src,
    "                part != QCOM_CPU_PART_KRYO_4XX_GOLD) {\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n",

    "                part != QCOM_CPU_PART_KRYO_4XX_GOLD) {\n"
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 18, 0)\n"
    "                /*\n"
    "                 * 4.14: nothing to undo. The vDSO datapage has no\n"
    "                 * clock_mode, struct clocksource has no\n"
    "                 * vdso_clock_mode, there is no vdso_default, and the\n"
    "                 * 1418040 workaround the upstream code clears does not\n"
    "                 * exist yet - so there is no capability bit to clear and\n"
    "                 * no reason to touch a bitmap whose length this kernel\n"
    "                 * does not know. Skipping keeps `missing` at zero instead\n"
    "                 * of failing the call with -ENXIO over symbols that were\n"
    "                 * never going to be there.\n"
    "                 */\n"
    "#else\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n",
    "guarded the >= 4.18 vDSO / clocksource / hwcap writes")

src = once(
    src,
    "                        pr_warn(\"ksu: set_spoof_cpu failed to resolve 'cpu_hwcaps' / 'system_cpucaps'\\n\");\n"
    "                        ++missing;\n"
    "                    }\n"
    "                }\n"
    "            }\n",

    "                        pr_warn(\"ksu: set_spoof_cpu failed to resolve 'cpu_hwcaps' / 'system_cpucaps'\\n\");\n"
    "                        ++missing;\n"
    "                    }\n"
    "                }\n"
    "#endif /* >= 4.18: vDSO clock mode / clocksource / erratum 1418040 */\n"
    "            }\n",
    "closed the >= 4.18 guard")

open(path, "w").write(src)
PY
fi

# The gate and all three edits must be present in the tree that gets built.
grep -q 'KSU_CAN_USE_CPU_SPOOF' "$KSU_DIR/kernel/kernel_compat.h" \
    || die "cpu_spoof gate vanished"
grep -q 'KERNEL_VERSION(4, 14, 0)' "$KSU_DIR/kernel/kernel_compat.h" \
    || die "cpu_spoof gate is still 5.10-only; the manager will show it Unsupported"
grep -q 'asm/vdso_datapage.h' "$KSU_DIR/kernel/extension/cpu_spoof.c" \
    || die "cpu_spoof.c lost its pre-4.18 datapage include"
grep -q '< KERNEL_VERSION(4, 18, 0)' "$KSU_DIR/kernel/extension/cpu_spoof.c" \
    || die "cpu_spoof.c lost its pre-4.18 guard"
grep -q '>= KERNEL_VERSION(4, 20, 0)' "$KSU_DIR/kernel/extension/cpu_spoof.c" \
    || die "cpu_spoof.c lost its elf_hwcap2 guard"

# -- 3.6 SELinux hiding and AVC log spoofing on 4.14 --------------------------
#
# Two manager toggles read "Kernel does not support this feature" on this
# kernel, for two unrelated reasons:
#
#   * "Hide SELinux modification" exists in SukiSU-Nova only for >= 5.10:
#     kernel/ksu_main.c does not even include feature/selinux_hide.c on 4.14,
#     so the KSU_FEATURE_SELINUX_HIDE handler is never registered and the
#     manager is told the feature does not exist. Upstream's file is written
#     against struct selinux_policy (5.6+) and duplicates the whole policydb,
#     which has no 4.14 counterpart.
#   * "AVC log spoofing" lives only inside the CONFIG_KSU_SUSFS block of
#     kernel/supercall/dispatch.c and is driven over
#     reboot(SUSFS_MAGIC, cmd, ...). SUSFS is off, so nothing answers it.
#
# Both are re-implemented here for 4.14, without SUSFS:
#
#   * AVC spoofing is the same rewrite susfs4ksu performs in avc_dump_query():
#     a denial whose *target* is KernelSU's own domain ("u:r:ksu:s0" for this
#     ref) is logged with a priv_app context instead. The four SUSFS reboot()
#     commands the manager needs -- SHOW_VERSION, SHOW_VARIANT,
#     SHOW_ENABLED_FEATURES and ENABLE_AVC_LOG_SPOOFING -- are answered by the
#     new security/selinux/ksu_hide_compat.c.
#
#   * "Hide SELinux modification" snapshots the *pristine* policy. The init
#     second stage runs before apply_kernelsu_rules() -- the same ordering
#     upstream depends on -- so the bytes read there are the stock policy.
#     With the feature on, /sys/fs/selinux/policy, its inode size and the
#     policyload counter report that pristine policy instead of the live one.
#     This is a deliberate subset of upstream: it hides what a detector reads
#     back (policy dump, policy load counter), not the sidtab-level queries
#     upstream also redirects.
#
# Everything below the kernel side is gated on CONFIG_KSU, so a build without
# KernelSU compiles the untouched SELinux code.

if [[ "$MODE" != check ]]; then

mkdir -p security/selinux
cat > include/linux/ksu_hide_compat.h <<'KSU_HIDE_H'
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * 4.14 glue for two SukiSU-Nova features that upstream only ships for newer
 * kernels ("hide SELinux modification") or only behind CONFIG_KSU_SUSFS
 * ("AVC log spoofing").
 *
 * Implemented in security/selinux/ksu_hide_compat.c, which is built only when
 * CONFIG_KSU is enabled; every call site is wrapped in #ifdef CONFIG_KSU.
 */
#ifndef _LINUX_KSU_HIDE_COMPAT_H
#define _LINUX_KSU_HIDE_COMPAT_H

#include <linux/compiler.h>
#include <linux/types.h>

struct selinux_state;

/* ---- AVC log spoofing --------------------------------------------------- */
bool ksu_avc_log_spoof_matches(u32 tsid);
const char *ksu_avc_spoof_tcontext(void);

/*
 * Handles the SUSFS-compatible reboot() supercall the manager uses for AVC log
 * spoofing. Returns true when it consumed the call, i.e. the syscall must
 * return 0 instead of falling through to the real reboot path.
 */
bool ksu_avc_spoof_reboot(int magic1, int magic2, unsigned int cmd,
			  void __user *argp);

/* ---- hiding KernelSU's SELinux modifications ---------------------------- */
int ksu_selinux_hide_capture(void);
bool ksu_selinux_hide_ready(void);
bool ksu_selinux_hide_active(void);
size_t ksu_selinux_hide_snapshot_len(void);
void ksu_selinux_hide_set_enabled(bool on);
u32 ksu_selinux_hide_mask_policyload(u32 seqno);

/*
 * Override for security_read_policy(): returns 0 with a fresh vmalloc_user()
 * buffer when the pristine snapshot should be served, -EAGAIN otherwise.
 */
int ksu_selinux_hide_read_policy(void **data, size_t *len);

/* Implemented in ss/status.c, the only place struct selinux_ss is visible. */
void ksu_selinux_hide_rewrite_status(struct selinux_state *state,
				     u32 policyload);

#endif /* _LINUX_KSU_HIDE_COMPAT_H */
KSU_HIDE_H

cat > security/selinux/ksu_hide_compat.c <<'KSU_HIDE_C'
// SPDX-License-Identifier: GPL-2.0
/*
 * 4.14 support for two SukiSU-Nova features whose upstream implementations do
 * not exist on this kernel:
 *
 *   "Hide SELinux modification" -- upstream (kernel/feature/selinux_hide.c) is
 *       written against struct selinux_policy, which appeared in 5.6, and
 *       duplicates the policydb. Here the pristine policy is snapshotted at the
 *       init second stage -- the moment where the stock policy is loaded but
 *       apply_kernelsu_rules() has not run yet -- and served back in place of
 *       the live one, together with the pristine policyload counter.
 *
 *   "AVC log spoofing" -- upstream only exists behind CONFIG_KSU_SUSFS. The
 *       rewrite below is the one susfs4ksu performs in avc_dump_query(), and
 *       the SUSFS reboot() supercall the manager drives it with is answered
 *       here so that no SUSFS code is needed.
 */
#include <linux/kernel.h>
#include <linux/types.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>
#include <linux/mutex.h>
#include <linux/cred.h>
#include <linux/audit.h>
#include <linux/sched.h>
#include <linux/security.h>
#include <linux/ksu_hide_compat.h>

#include "security.h"

/* The SUSFS userspace ABI, as susfs4ksu implements it. */
#define KSU_SUSFS_MAGIC			0xFAFAFAFA
#define KSU_SUSFS_SHOW_VERSION		0x555e1
#define KSU_SUSFS_SHOW_ENABLED_FEATURES	0x555e2
#define KSU_SUSFS_SHOW_VARIANT		0x555e3
#define KSU_SUSFS_ENABLE_AVC_LOG_SPOOFING 0x60010

/* KSU_INSTALL_MAGIC1 from SukiSU's uapi/supercall.h; the manager sends it as
 * the first reboot() argument, exactly like the SUSFS tool does. */
#define KSU_SUPERCALL_MAGIC1		0xDEADBEEF

#define KSU_SUSFS_ENABLED_FEATURES_SIZE	8192
#define KSU_SUSFS_MAX_VERSION_BUFSIZE	16
#define KSU_SUSFS_MAX_VARIANT_BUFSIZE	16

/* Reported to the manager so that it offers the SUSFS-driven AVC toggle. This
 * bridge implements AVC log spoofing only; the version is the susfs4ksu one
 * the code below was modelled on. */
#define KSU_SUSFS_VERSION		"v2.4.0"
#define KSU_SUSFS_VARIANT		"NON-GKI"
#define KSU_SUSFS_FEATURES		"CONFIG_KSU_SUSFS_AVC_LOG_SPOOFING\n"

/* Android's priv_app context, and the domain KernelSU switches to
 * (KERNEL_SU_CONTEXT in SukiSU's kernel/selinux/selinux.h). */
#define KSU_AVC_SPOOF_TCONTEXT		"u:r:priv_app:s0:c512,c768"
#define KSU_AVC_SPOOF_TARGET_CONTEXT	"u:r:ksu:s0"

struct ksu_susfs_avc_log_spoofing {
	bool enabled;
	int err;
};

struct ksu_susfs_enabled_features {
	char enabled_features[KSU_SUSFS_ENABLED_FEATURES_SIZE];
	int err;
};

struct ksu_susfs_variant {
	char susfs_variant[KSU_SUSFS_MAX_VARIANT_BUFSIZE];
	int err;
};

struct ksu_susfs_version {
	char susfs_version[KSU_SUSFS_MAX_VERSION_BUFSIZE];
	int err;
};

static DEFINE_MUTEX(ksu_hide_lock);

/* ---- AVC log spoofing --------------------------------------------------- */

static bool ksu_avc_spoof_on;
static bool ksu_avc_spoof_sid_valid;
static u32 ksu_avc_spoof_sid;

bool ksu_avc_log_spoof_matches(u32 tsid)
{
	return READ_ONCE(ksu_avc_spoof_on) && READ_ONCE(ksu_avc_spoof_sid_valid) &&
	       tsid == READ_ONCE(ksu_avc_spoof_sid);
}

const char *ksu_avc_spoof_tcontext(void)
{
	return KSU_AVC_SPOOF_TCONTEXT;
}

static int ksu_avc_spoof_resolve_sid(void)
{
	u32 sid = 0;
	int err;

	err = security_secctx_to_secid(KSU_AVC_SPOOF_TARGET_CONTEXT,
				       strlen(KSU_AVC_SPOOF_TARGET_CONTEXT), &sid);
	if (err || !sid) {
		pr_warn("ksu: avc spoof: cannot resolve %s (%d)\n",
			KSU_AVC_SPOOF_TARGET_CONTEXT, err);
		return -EINVAL;
	}

	WRITE_ONCE(ksu_avc_spoof_sid, sid);
	WRITE_ONCE(ksu_avc_spoof_sid_valid, true);
	pr_info("ksu: avc spoof: masking denials targeting sid %u\n", sid);
	return 0;
}

static void ksu_susfs_show_version(void __user *argp)
{
	struct ksu_susfs_version info;

	memset(&info, 0, sizeof(info));
	if (copy_from_user(&info, argp, sizeof(info))) {
		info.err = -EFAULT;
	} else {
		memcpy(info.susfs_version, KSU_SUSFS_VERSION,
		       sizeof(KSU_SUSFS_VERSION));
		info.err = 0;
	}
	if (copy_to_user(argp, &info, sizeof(info)))
		pr_warn("ksu: SUSFS SHOW_VERSION: copy_to_user failed\n");
}

static void ksu_susfs_show_variant(void __user *argp)
{
	struct ksu_susfs_variant info;

	memset(&info, 0, sizeof(info));
	if (copy_from_user(&info, argp, sizeof(info))) {
		info.err = -EFAULT;
	} else {
		memcpy(info.susfs_variant, KSU_SUSFS_VARIANT,
		       sizeof(KSU_SUSFS_VARIANT));
		info.err = 0;
	}
	if (copy_to_user(argp, &info, sizeof(info)))
		pr_warn("ksu: SUSFS SHOW_VARIANT: copy_to_user failed\n");
}

static void ksu_susfs_show_enabled_features(void __user *argp)
{
	struct ksu_susfs_enabled_features *info;
	int err = 0;

	info = kzalloc(sizeof(*info), GFP_KERNEL);
	if (!info) {
		err = -ENOMEM;
		goto out;
	}

	if (copy_from_user(info, argp, sizeof(*info))) {
		info->err = -EFAULT;
	} else {
		memcpy(info->enabled_features, KSU_SUSFS_FEATURES,
		       sizeof(KSU_SUSFS_FEATURES));
		info->err = 0;
	}
	if (copy_to_user(argp, info, sizeof(*info)))
		err = -EFAULT;
	kfree(info);
out:
	if (err)
		pr_warn("ksu: SUSFS SHOW_ENABLED_FEATURES failed: %d\n", err);
}

static void ksu_susfs_set_avc_log_spoofing(void __user *argp)
{
	struct ksu_susfs_avc_log_spoofing info;

	memset(&info, 0, sizeof(info));
	if (copy_from_user(&info, argp, sizeof(info))) {
		info.err = -EFAULT;
	} else if (info.enabled && !READ_ONCE(ksu_avc_spoof_sid_valid) &&
		   ksu_avc_spoof_resolve_sid()) {
		/* Without the domain's SID there is nothing to mask. */
		info.err = -EINVAL;
	} else {
		WRITE_ONCE(ksu_avc_spoof_on, info.enabled);
		info.err = 0;
		pr_info("ksu: avc spoof: %s\n",
			info.enabled ? "enabled" : "disabled");
	}
	if (copy_to_user(argp, &info, sizeof(info)))
		pr_warn("ksu: SUSFS ENABLE_AVC_LOG_SPOOFING: copy_to_user failed\n");
}

bool ksu_avc_spoof_reboot(int magic1, int magic2, unsigned int cmd,
			  void __user *argp)
{
	/* Both magics are 32-bit values above INT_MAX in unsigned form. */
	if ((unsigned int)magic1 != KSU_SUPERCALL_MAGIC1 ||
	    (unsigned int)magic2 != KSU_SUSFS_MAGIC)
		return false;

	if (current_uid().val != 0) {
		pr_warn("ksu: SUSFS supercall from uid %u, ignoring\n",
			current_uid().val);
		return true;
	}

	switch (cmd) {
	case KSU_SUSFS_SHOW_VERSION:
		ksu_susfs_show_version(argp);
		break;
	case KSU_SUSFS_SHOW_VARIANT:
		ksu_susfs_show_variant(argp);
		break;
	case KSU_SUSFS_SHOW_ENABLED_FEATURES:
		ksu_susfs_show_enabled_features(argp);
		break;
	case KSU_SUSFS_ENABLE_AVC_LOG_SPOOFING:
		ksu_susfs_set_avc_log_spoofing(argp);
		break;
	default:
		pr_info("ksu: unsupported SUSFS command 0x%x\n", cmd);
		return false;
	}

	return true;
}

/* ---- hiding KernelSU's SELinux modifications ---------------------------- */

static void *ksu_policy_snapshot;
static size_t ksu_policy_snapshot_len;
static bool ksu_policy_snapshot_policyload_valid;
static u32 ksu_policy_snapshot_policyload;
static bool ksu_hide_capturing;
static bool ksu_hide_on;

bool ksu_selinux_hide_ready(void)
{
	return READ_ONCE(ksu_policy_snapshot) != NULL;
}

bool ksu_selinux_hide_active(void)
{
	return READ_ONCE(ksu_hide_on) && ksu_selinux_hide_ready();
}

size_t ksu_selinux_hide_snapshot_len(void)
{
	return READ_ONCE(ksu_policy_snapshot_len);
}

/*
 * Snapshot the policy that is live right now. Called from the init second
 * stage, before apply_kernelsu_rules(), and again when the manager enables the
 * feature in case the first call came too early (policy not loaded yet).
 */
int ksu_selinux_hide_capture(void)
{
	struct selinux_state *state = &selinux_state;
	struct page *page;
	void *data = NULL;
	size_t len = 0;
	int ret;

	mutex_lock(&ksu_hide_lock);
	if (READ_ONCE(ksu_policy_snapshot)) {
		ret = 0;
		goto out;
	}
	if (!selinux_initialized(state)) {
		ret = -EAGAIN;
		goto out;
	}

	ksu_hide_capturing = true;
	ret = security_read_policy(state, &data, &len);
	ksu_hide_capturing = false;
	if (ret || !data || !len) {
		if (!ret)
			ret = -EINVAL;
		vfree(data);
		goto out;
	}

	/*
	 * The status page only exists once something mmaps it, and a freshly
	 * allocated one reads policyload == 0. Android loads the policy exactly
	 * once (init), and this runs before apply_kernelsu_rules(), so 1 is the
	 * pristine count when the page has no counter yet.
	 */
	page = selinux_kernel_status_page(state);
	if (page) {
		struct selinux_kernel_status *status = page_address(page);

		ksu_policy_snapshot_policyload = status->policyload ?
						  status->policyload : 1;
		ksu_policy_snapshot_policyload_valid = true;
	}

	ksu_policy_snapshot_len = len;
	smp_wmb();
	WRITE_ONCE(ksu_policy_snapshot, data);

	pr_info("ksu: selinux_hide: pristine policy captured, %zu bytes, policyload %u\n",
		len, ksu_policy_snapshot_policyload);
	ret = 0;
out:
	mutex_unlock(&ksu_hide_lock);
	return ret;
}

int ksu_selinux_hide_read_policy(void **data, size_t *len)
{
	void *copy;

	if (!ksu_selinux_hide_active() || READ_ONCE(ksu_hide_capturing))
		return -EAGAIN;

	copy = vmalloc_user(ksu_selinux_hide_snapshot_len());
	if (!copy)
		return -ENOMEM;
	memcpy(copy, READ_ONCE(ksu_policy_snapshot), ksu_selinux_hide_snapshot_len());

	*data = copy;
	*len = ksu_selinux_hide_snapshot_len();
	return 0;
}

void ksu_selinux_hide_set_enabled(bool on)
{
	mutex_lock(&ksu_hide_lock);
	WRITE_ONCE(ksu_hide_on, on);
	if (on && READ_ONCE(ksu_policy_snapshot_policyload_valid))
		ksu_selinux_hide_rewrite_status(&selinux_state,
						ksu_policy_snapshot_policyload);
	mutex_unlock(&ksu_hide_lock);

	pr_info("ksu: selinux_hide: %s\n", on ? "enabled" : "disabled");
}

u32 ksu_selinux_hide_mask_policyload(u32 seqno)
{
	if (ksu_selinux_hide_active() &&
	    READ_ONCE(ksu_policy_snapshot_policyload_valid))
		return READ_ONCE(ksu_policy_snapshot_policyload);
	return seqno;
}
KSU_HIDE_C

python3 - "security/selinux/Makefile" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

anchor = "selinux-$(CONFIG_SECURITY_NETWORK_XFRM) += xfrm.o\n"
want = ("\n"
        "# KernelSU's 4.14 stand-ins for the >= 5.10 SELinux hiding and for\n"
        "# the SUSFS-only AVC log spoofing.\n"
        "selinux-$(CONFIG_KSU) += ksu_hide_compat.o\n")

if "ksu_hide_compat.o" in src:
    print("[ksu-nova]   selinux Makefile: already applied")
elif anchor not in src:
    sys.exit("[ksu-nova] ERROR: selinux Makefile anchor missing")
else:
    open(path, "w").write(src.replace(anchor, anchor + want, 1))
    print("[ksu-nova]   selinux Makefile: added ksu_hide_compat.o")
PY

python3 - "security/selinux/avc.c" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

def once(src, old, new, label):
    if new in src:
        print("[ksu-nova]   " + label + ": already applied")
        return src
    if old not in src:
        sys.exit("[ksu-nova] ERROR: " + label + " anchor missing in " + path
                 + " (upstream changed)")
    print("[ksu-nova]   " + label)
    return src.replace(old, new, 1)

src = once(
    src,
    '#include "avc.h"\n',
    "#include <linux/ksu_hide_compat.h>\n"
    '#include "avc.h"\n',
    "avc.c: include ksu_hide_compat.h")

src = once(
    src,
    "\trc = security_sid_to_context(state, tsid, &scontext, &scontext_len);\n"
    "\tif (rc)\n"
    "\t\taudit_log_format(ab, \" tsid=%d\", tsid);\n"
    "\telse {\n"
    "\t\taudit_log_format(ab, \" tcontext=%s\", scontext);\n"
    "\t\tkfree(scontext);\n"
    "\t}\n"
    "\n"
    "\tBUG_ON(!tclass || tclass >= ARRAY_SIZE(secclass_map));\n",

    "\trc = security_sid_to_context(state, tsid, &scontext, &scontext_len);\n"
    "#ifdef CONFIG_KSU\n"
    "\t/*\n"
    "\t * AVC log spoofing: when the *target* of a denial is KernelSU's own\n"
    "\t * domain, log a priv_app context instead so that the line does not\n"
    "\t * point at root. This is the rewrite susfs4ksu performs in its\n"
    "\t * avc_dump_query() hook, which only exists with CONFIG_KSU_SUSFS.\n"
    "\t */\n"
    "\tif (ksu_avc_log_spoof_matches(tsid)) {\n"
    "\t\tif (!rc)\n"
    "\t\t\tkfree(scontext);\n"
    "\t\taudit_log_format(ab, \" tcontext=%s\", ksu_avc_spoof_tcontext());\n"
    "\t\tgoto out_tclass;\n"
    "\t}\n"
    "#endif\n"
    "\tif (rc)\n"
    "\t\taudit_log_format(ab, \" tsid=%d\", tsid);\n"
    "\telse {\n"
    "\t\taudit_log_format(ab, \" tcontext=%s\", scontext);\n"
    "\t\tkfree(scontext);\n"
    "\t}\n"
    "\n"
    "#ifdef CONFIG_KSU\n"
    "out_tclass:\n"
    "#endif\n"
    "\tBUG_ON(!tclass || tclass >= ARRAY_SIZE(secclass_map));\n",
    "avc.c: avc_dump_query() AVC log spoofing")

open(path, "w").write(src)
PY

python3 - "security/selinux/ss/services.c" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

def once(src, old, new, label):
    if new in src:
        print("[ksu-nova]   " + label + ": already applied")
        return src
    if old not in src:
        sys.exit("[ksu-nova] ERROR: " + label + " anchor missing in " + path
                 + " (upstream changed)")
    print("[ksu-nova]   " + label)
    return src.replace(old, new, 1)

src = once(
    src,
    "#include <net/netlabel.h>\n",
    "#include <net/netlabel.h>\n"
    "#include <linux/ksu_hide_compat.h>\n",
    "services.c: include ksu_hide_compat.h")

src = once(
    src,
    "int security_read_policy(struct selinux_state *state,\n"
    "\t\t\t void **data, size_t *len)\n"
    "{\n"
    "\tstruct policydb *policydb = &state->ss->policydb;\n"
    "\tint rc;\n"
    "\tstruct policy_file fp;\n"
    "\n",

    "int security_read_policy(struct selinux_state *state,\n"
    "\t\t\t void **data, size_t *len)\n"
    "{\n"
    "\tstruct policydb *policydb = &state->ss->policydb;\n"
    "\tint rc;\n"
    "\tstruct policy_file fp;\n"
    "\n"
    "#ifdef CONFIG_KSU\n"
    "\t/* \"Hide SELinux modification\": serve the pristine policy dump. */\n"
    "\tif (!ksu_selinux_hide_read_policy(data, len))\n"
    "\t\treturn 0;\n"
    "#endif\n"
    "\n",
    "services.c: security_read_policy() pristine dump")

src = once(
    src,
    "size_t security_policydb_len(struct selinux_state *state)\n"
    "{\n"
    "\tstruct policydb *p = &state->ss->policydb;\n"
    "\tsize_t len;\n"
    "\n",

    "size_t security_policydb_len(struct selinux_state *state)\n"
    "{\n"
    "\tstruct policydb *p = &state->ss->policydb;\n"
    "\tsize_t len;\n"
    "\n"
    "#ifdef CONFIG_KSU\n"
    "\t/* Keep the selinuxfs inode size in step with the snapshot. */\n"
    "\tif (ksu_selinux_hide_active())\n"
    "\t\treturn ksu_selinux_hide_snapshot_len();\n"
    "#endif\n"
    "\n",
    "services.c: security_policydb_len() snapshot size")

src = once(
    src,
    "\t\tavc_ss_reset(state->avc, seqno);\n"
    "\t\tselnl_notify_policyload(seqno);\n"
    "\t\tselinux_status_update_policyload(state, seqno);\n",

    "\t\tavc_ss_reset(state->avc, seqno);\n"
    "#ifdef CONFIG_KSU\n"
    "\t\t/* Report the pristine load count, not KernelSU's reload. */\n"
    "\t\tseqno = ksu_selinux_hide_mask_policyload(seqno);\n"
    "#endif\n"
    "\t\tselnl_notify_policyload(seqno);\n"
    "\t\tselinux_status_update_policyload(state, seqno);\n",
    "services.c: policyload masking")

open(path, "w").write(src)
PY

if grep -q 'ksu_selinux_hide_rewrite_status' security/selinux/ss/status.c; then
    log "  status.c: ksu_selinux_hide_rewrite_status() already present"
else
cat >> security/selinux/ss/status.c <<'KSU_STATUS_C'

#ifdef CONFIG_KSU
/*
 * "Hide SELinux modification": rewrite the load counter the status page
 * reports, so that KernelSU's policy load does not show up on
 * /sys/fs/selinux/status. struct selinux_ss is only visible here.
 */
void ksu_selinux_hide_rewrite_status(struct selinux_state *state, u32 policyload)
{
	struct selinux_kernel_status *status;

	mutex_lock(&state->ss->status_lock);
	if (state->ss->status_page) {
		status = page_address(state->ss->status_page);

		status->sequence++;
		smp_wmb();
		status->policyload = policyload;
		smp_wmb();
		status->sequence++;
	}
	mutex_unlock(&state->ss->status_lock);
}
#endif
KSU_STATUS_C
fi

python3 - "kernel/reboot.c" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

def once(src, old, new, label):
    if new in src:
        print("[ksu-nova]   " + label + ": already applied")
        return src
    if old not in src:
        sys.exit("[ksu-nova] ERROR: " + label + " anchor missing in " + path
                 + " (upstream changed)")
    print("[ksu-nova]   " + label)
    return src.replace(old, new, 1)

# The include is independent of section 4 below, which adds the KSU extern.
src = once(
    src,
    "#include <linux/uaccess.h>\n",
    "#include <linux/uaccess.h>\n"
    "#include <linux/kernel.h>\n"
    "#include <linux/ksu_hide_compat.h>\n",
    "reboot.c: include ksu_hide_compat.h")

# ...and the SUSFS supercall is consumed at the top of the syscall, before the
# CAP_SYS_BOOT check and before section 4's ksu_handle_sys_reboot() call.
src = once(
    src,
    "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n"
    "\t\tvoid __user *, arg)\n"
    "{\n"
    "\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);\n"
    "\tchar buffer[256];\n"
    "\tint ret = 0;\n",

    "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n"
    "\t\tvoid __user *, arg)\n"
    "{\n"
    "\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);\n"
    "\tchar buffer[256];\n"
    "\tint ret = 0;\n"
    "#ifdef CONFIG_KSU\n"
    "\t/*\n"
    "\t * The manager drives AVC log spoofing over the SUSFS reboot()\n"
    "\t * supercall. When this returns true the call was ours, so do not\n"
    "\t * fall through to the real reboot path (whose magic check would\n"
    "\t * fail with -EINVAL and make the manager report a failure).\n"
    "\t */\n"
    "\tif (system_state == SYSTEM_RUNNING &&\n"
    "\t    ksu_avc_spoof_reboot(magic1, magic2, cmd, arg))\n"
    "\t\treturn 0;\n"
    "#endif\n",
    "reboot.c: SUSFS supercall for AVC log spoofing")

open(path, "w").write(src)
PY

# ---- the SukiSU-Nova side: the 4.14 feature implementation --------------------

cat > "$KSU_DIR/kernel/feature/selinux_hide_414.c" <<'KSU_SELINUX_414'
// SPDX-License-Identifier: GPL-2.0
/*
 * "Hide SELinux modification" for kernels older than 5.10.
 *
 * Upstream's kernel/feature/selinux_hide.c is built around struct
 * selinux_policy (5.6+) and duplicates the whole policydb, which has no 4.14
 * counterpart. Here the pristine policy is snapshotted at the init second
 * stage -- before apply_kernelsu_rules() adds KernelSU's rules -- and the
 * policy dump and load counter are served from that snapshot while the feature
 * is enabled. The heavy lifting lives in the kernel, in
 * security/selinux/ksu_hide_compat.c; this file only owns the KSU feature id.
 */
#include "selinux_hide.h"
#include <linux/ksu_hide_compat.h>

static bool ksu_selinux_hide_enabled;
static bool ksu_selinux_hide_running;
static DEFINE_MUTEX(selinux_hide_mutex);

static int selinux_hide_feature_get(u64 *value)
{
    *value = ksu_selinux_hide_enabled ? 1 : 0;
    return 0;
}

static int selinux_hide_feature_set(u64 value)
{
    bool enable = value != 0;
    int ret = 0;

    pr_info("selinux_hide: set to %d\n", enable);

    mutex_lock(&selinux_hide_mutex);
    ksu_selinux_hide_enabled = enable;

    if (enable) {
        /*
         * The snapshot is taken at the init second stage, before
         * apply_kernelsu_rules() touches the policy. Capturing here instead
         * would snapshot an already-modified policy, so a missing snapshot
         * is reported the way upstream reports it: save the setting and
         * reboot.
         */
        if (!ksu_selinux_hide_ready()) {
            pr_err("selinux_hide: no pristine sepolicy snapshot, "
                   "save the feature and reboot to retry\n");
            ksu_selinux_hide_enabled = false;
            ret = -EAGAIN;
        } else {
            ksu_selinux_hide_set_enabled(true);
            ksu_selinux_hide_running = true;
        }
    } else {
        ksu_selinux_hide_set_enabled(false);
        ksu_selinux_hide_running = false;
    }

    pr_info("selinux_hide: enabled %d, running %d\n",
            ksu_selinux_hide_enabled, ksu_selinux_hide_running);
    mutex_unlock(&selinux_hide_mutex);
    return ret;
}

static const struct ksu_feature_handler selinux_hide_handler = {
    .feature_id = KSU_FEATURE_SELINUX_HIDE,
    .name = "selinux_hide",
    .get_handler = selinux_hide_feature_get,
    .set_handler = selinux_hide_feature_set,
};

void ksu_selinux_hide_handle_second_stage(void)
{
    if (ksu_selinux_hide_capture())
        pr_warn("selinux_hide: could not capture the pristine policy yet\n");
    else
        pr_info("selinux_hide: pristine policy captured\n");
}

void ksu_selinux_hide_handle_post_fs_data(void)
{
    /*
     * Nothing to do. The snapshot has to come from the second stage: by the
     * time post-fs-data runs, apply_kernelsu_rules() has already rewritten the
     * policy, so capturing here would snapshot the modified one.
     */
    pr_info("selinux_hide: %s\n",
            ksu_selinux_hide_enabled ? "active" : "inactive");
}

void ksu_selinux_hide_drop_backup_if_unused(void)
{
    /*
     * The snapshot is a few hundred kilobytes and is kept for the lifetime of
     * the kernel: freeing it could race a concurrent /sys/fs/selinux/policy
     * read, and the feature can be toggled on at any later point.
     */
    if (!ksu_selinux_hide_enabled)
        pr_info("selinux_hide: feature off, snapshot kept\n");
}

void __init ksu_selinux_hide_init(void)
{
    if (ksu_register_feature_handler(&selinux_hide_handler))
        pr_err("Failed to register selinux_hide feature handler\n");
    else
        pr_info("selinux_hide: feature handler registered (4.14 backport)\n");
}

void __exit ksu_selinux_hide_exit(void)
{
    ksu_selinux_hide_set_enabled(false);
    ksu_unregister_feature_handler(KSU_FEATURE_SELINUX_HIDE);
}
KSU_SELINUX_414

python3 - "$KSU_DIR/kernel" <<'PY'
import re
import sys

KSU = sys.argv[1]

def edit(path, old, new, label):
    src = open(path).read()
    if new in src:
        print("[ksu-nova]   " + label + ": already applied")
        return
    if old not in src:
        sys.exit("[ksu-nova] ERROR: " + label + " anchor missing in " + path
                 + " (upstream changed)")
    open(path, "w").write(src.replace(old, new, 1))
    print("[ksu-nova]   " + label)

main = KSU + "/ksu_main.c"

# 1. Include the 4.14 implementation instead of skipping the feature entirely.
edit(
    main,
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
    '#include "feature/selinux_hide.c"\n'
    "#endif\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
    '#include "feature/selinux_hide.c"\n'
    "#else\n"
    "/* 4.14: pristine-policy snapshot + policyload masking. */\n"
    '#include "feature/selinux_hide_414.c"\n'
    "#endif\n",
    "ksu_main.c: 4.14 selinux_hide implementation")

# 2. Register the feature handler on 4.14 as well.
edit(
    main,
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
    "    ksu_selinux_hide_init();\n"
    "#endif\n",
    "    ksu_selinux_hide_init();\n",
    "ksu_main.c: ksu_selinux_hide_init() unguarded")

# 3. The second-stage / post-fs-data / boot-completed calls are the ones that
#    decide *when* the snapshot is taken, so they must run on 4.14 too.
ksud = KSU + "/runtime/ksud.c"
src = open(ksud).read()
calls = [
    "ksu_selinux_hide_handle_second_stage()",
    "ksu_selinux_hide_handle_post_fs_data()",
    "ksu_selinux_hide_drop_backup_if_unused()",
]
for call in calls:
    pattern = re.compile(
        r"#if LINUX_VERSION_CODE >= KERNEL_VERSION\(5, 10, 0\)\n"
        r"([ \t]*" + re.escape(call) + r";\n)"
        r"#endif\n")
    if re.search(r"^[ \t]*" + re.escape(call) + r";$", src, re.M):
        print("[ksu-nova]   ksud.c: " + call + " already unguarded")
        continue
    src, n = pattern.subn(r"\1", src)
    if not n:
        sys.exit("[ksu-nova] ERROR: " + call + " guard missing in " + ksud
                 + " (upstream changed)")
    print("[ksu-nova]   ksud.c: " + call + " unguarded (%d site(s))" % n)
open(ksud, "w").write(src)
PY

fi  # MODE != check

# ---- verification, both in --check mode and after applying --------------------

[[ -f include/linux/ksu_hide_compat.h ]] || die "ksu_hide_compat.h missing"
[[ -f security/selinux/ksu_hide_compat.c ]] || die "ksu_hide_compat.c missing"
grep -q 'ksu_hide_compat.o' security/selinux/Makefile || die "selinux Makefile not patched"
grep -q 'ksu_avc_log_spoof_matches(tsid)' security/selinux/avc.c || die "avc.c not patched"
grep -q 'ksu_selinux_hide_read_policy' security/selinux/ss/services.c || die "services.c not patched"
grep -q 'ksu_selinux_hide_rewrite_status' security/selinux/ss/status.c || die "status.c not patched"
grep -q 'ksu_avc_spoof_reboot' kernel/reboot.c || die "reboot.c not patched"
grep -q 'selinux_hide_414.c' "$KSU_DIR/kernel/ksu_main.c" \
    || die "SukiSU still skips selinux_hide.c on 4.14 (5.10-only)"
[[ -f "$KSU_DIR/kernel/feature/selinux_hide_414.c" ]] || die "selinux_hide_414.c missing"
grep -q 'ksu_selinux_hide_handle_second_stage();' "$KSU_DIR/kernel/runtime/ksud.c" \
    || die "second-stage snapshot hook missing"
ok "SELinux hiding + AVC log spoofing wired for 4.14"

# ------------------------------------------------------------- 4. KSU hooks ---
#
# SukiSU-Nova's `builtin` ref is source-integrated: the kernel has to call its
# entry points itself. The signatures below are the ones its headers declare
# for a 4.14 kernel with CONFIG_KSU_SUSFS off (kernel/feature/sucompat.h).
#
# A hook is only inserted when the clone actually *defines* the symbol outside
# a CONFIG_KSU_SUSFS block. ksu_handle_setresuid() is the case that matters:
# it exists only in the SUSFS build (it drives SUSFS's zygote handling), so
# inserting the call unconditionally links a kernel with an undefined symbol
# -- which is exactly what happened before this check existed.
#
# Every anchor is the full function signature, not just the opening brace, and
# the insertion is re-checked by offset afterwards. A brace-shaped anchor is
# how the setresuid hook once landed in setregid(): both bodies open with the
# same declarations, and the first match wins.
#
# NOT hooked: ksu_handle_vfs_read (ksu_vfs_read_hook) -- the read-side hook is
# only needed by the legacy syscall-su path this ref does not use.

if [[ "$MODE" != check ]]; then
    python3 - "$KSU_DIR/kernel" <<'PY'
import os
import re
import sys

KSU = sys.argv[1]

# (file, extern block, declaration anchor, insert-after anchor, call block,
#  symbol, label)
HOOKS = [
    (
        "fs/exec.c",
        "#ifdef CONFIG_KSU\n"
        "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
        "\t\t\t       void *argv, void *envp, int *flags);\n"
        "#endif\n\n",
        "static int do_execveat_common(int fd, struct filename *filename,",
        "static int do_execveat_common(int fd, struct filename *filename,\n"
        "\t\t\t      struct user_arg_ptr argv,\n"
        "\t\t\t      struct user_arg_ptr envp,\n"
        "\t\t\t      int flags)\n"
        "{\n",
        "#ifdef CONFIG_KSU\n"
        "\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
        "#endif\n",
        "ksu_handle_execveat",
        "fs/exec.c do_execveat_common -> ksu_handle_execveat()",
    ),
    (
        "kernel/reboot.c",
        "#ifdef CONFIG_KSU\n"
        "extern int ksu_handle_sys_reboot(int magic1, int magic2,\n"
        "\t\t\t\t unsigned int cmd, void __user **arg);\n"
        "#endif\n\n",
        "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,",
        "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n"
        "\t\tvoid __user *, arg)\n"
        "{\n"
        "\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);\n"
        "\tchar buffer[256];\n"
        "\tint ret = 0;\n",
        "#ifdef CONFIG_KSU\n"
        "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
        "#endif\n",
        "ksu_handle_sys_reboot",
        "kernel/reboot.c reboot -> ksu_handle_sys_reboot()",
    ),
    (
        "kernel/sys.c",
        "#ifdef CONFIG_KSU\n"
        "extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n"
        "#endif\n\n",
        "SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)",
        "SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)\n"
        "{\n"
        "\tstruct user_namespace *ns = current_user_ns();\n"
        "\tconst struct cred *old;\n"
        "\tstruct cred *new;\n"
        "\tint retval;\n"
        "\tkuid_t kruid, keuid, ksuid;\n",
        "#ifdef CONFIG_KSU\n"
        "\tksu_handle_setresuid(ruid, euid, suid);\n"
        "#endif\n",
        "ksu_handle_setresuid",
        "kernel/sys.c setresuid -> ksu_handle_setresuid()",
    ),
    (
        "drivers/input/input.c",
        "#ifdef CONFIG_KSU\n"
        "extern int ksu_handle_input_handle_event(unsigned int *type,\n"
        "\t\t\t\t\t unsigned int *code, int *value);\n"
        "#endif\n\n",
        "static void input_handle_event(struct input_dev *dev,",
        "static void input_handle_event(struct input_dev *dev,\n"
        "\t\t\t       unsigned int type, unsigned int code, int value)\n"
        "{\n"
        "\tint disposition = input_get_disposition(dev, type, code, &value);\n",
        "#ifdef CONFIG_KSU\n"
        "\tksu_handle_input_handle_event(&type, &code, &value);\n"
        "#endif\n",
        "ksu_handle_input_handle_event",
        "drivers/input/input.c input_handle_event -> ksu_handle_input_handle_event()",
    ),
    (
        "fs/open.c",
        "#ifdef CONFIG_KSU\n"
        "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n"
        "\t\t\t\t int *mode, int *flags);\n"
        "#endif\n\n",
        "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)",
        "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n"
        "{\n"
        "\tconst struct cred *old_cred;\n"
        "\tstruct cred *override_cred;\n"
        "\tstruct path path;\n"
        "\tstruct inode *inode;\n"
        "\tstruct vfsmount *mnt;\n"
        "\tint res;\n"
        "\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n",
        "#ifdef CONFIG_KSU\n"
        "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
        "#endif\n",
        "ksu_handle_faccessat",
        "fs/open.c faccessat -> ksu_handle_faccessat()",
    ),
    (
        "fs/stat.c",
        "#ifdef CONFIG_KSU\n"
        "extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n"
        "#endif\n\n",
        "int vfs_statx(int dfd, const char __user *filename, int flags,",
        "int vfs_statx(int dfd, const char __user *filename, int flags,\n"
        "\t      struct kstat *stat, u32 request_mask)\n"
        "{\n"
        "\tstruct path path;\n"
        "\tint error = -EINVAL;\n"
        "\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n",
        "#ifdef CONFIG_KSU\n"
        "\tksu_handle_stat(&dfd, &filename, &flags);\n"
        "#endif\n",
        "ksu_handle_stat",
        "fs/stat.c vfs_statx -> ksu_handle_stat()",
    ),
]


def symbol_available(sym):
    """Is sym defined in a translation unit the SUSFS-free build compiles?

    Walks the clone's .c files with a tiny conditional tracker: a definition
    inside `#ifdef CONFIG_KSU_SUSFS` (or an `#if defined(CONFIG_KSU_SUSFS...)`)
    is not built here, so calling it would leave an undefined symbol at link
    time. Crude on purpose -- it only has to understand the guards KernelSU
    actually uses.
    """
    defn = re.compile(r'^\s*(?:[A-Za-z_][\w \t\*]*[\s\*])?%s\s*\(' % re.escape(sym))
    susfs_re = re.compile(r'CONFIG_KSU_SUSFS')

    for root, _dirs, files in os.walk(KSU):
        for name in files:
            if not name.endswith('.c'):
                continue
            path = os.path.join(root, name)
            dead = []          # stack of "this branch is not compiled"
            skip_branch = None  # conditional we are inside, for #else
            try:
                handle = open(path, errors='ignore')
            except OSError:
                continue
            with handle:
                for line in handle:
                    stripped = line.lstrip()
                    if stripped.startswith('#'):
                        directive = stripped[1:].strip()
                        word = directive.split('(')[0].split()[0] if directive else ''
                        if word in ('ifdef', 'ifndef', 'if'):
                            if word == 'if':
                                negated = '!defined(CONFIG_KSU_SUSFS' in directive
                                hits = susfs_re.search(directive) is not None
                                skip_branch = hits and not negated
                            elif word == 'ifdef':
                                skip_branch = 'CONFIG_KSU_SUSFS' in directive
                            else:                        # ifndef
                                skip_branch = 'CONFIG_KSU_SUSFS' not in directive
                            dead.append(bool(skip_branch))
                        elif word == 'else' and dead:
                            dead[-1] = not dead[-1]
                        elif word == 'elif' and dead:
                            dead[-1] = True
                        elif word == 'endif' and dead:
                            dead.pop()
                        continue
                    if any(dead):
                        continue
                    if defn.match(line):
                        return True
    return False


skipped = []
failed = False
for path, extern, decl_anchor, after_anchor, call, sym, label in HOOKS:
    try:
        src = open(path).read()
    except FileNotFoundError:
        print("[ksu-nova] ERROR: %s not found" % path)
        failed = True
        continue

    if call in src:
        print("[ksu-nova]   ok: %s (already patched)" % label)
        continue

    if not symbol_available(sym):
        print("[ksu-nova]   skip: %s -- %s is not defined in this "
              "configuration" % (label, sym))
        skipped.append(sym)
        continue

    bad = False
    for what, anchor in (("declaration", decl_anchor),
                         ("local declarations", after_anchor)):
        count = src.count(anchor)
        if count != 1:
            print("[ksu-nova] ERROR: %s %s anchor matches %d times in %s "
                  "(expected exactly 1)" % (path, what, count, path))
            failed = bad = True
    if bad:
        continue

    src = src.replace(decl_anchor, extern + decl_anchor, 1)
    decl_at = src.index(decl_anchor)

    # Insert after the last local declaration, keeping the blank line that
    # follows it where there is one.
    at = src.index(after_anchor) + len(after_anchor)
    if src[at:at + 1] == "\n":
        at += 1
    src = src[:at] + call + src[at:]

    # The call must sit inside the function we aimed at.
    call_at = src.index(call)
    if not (decl_at < call_at <= decl_at + 2000):
        print("[ksu-nova] ERROR: %s hook landed outside its function" % path)
        failed = True
        continue

    open(path, "w").write(src)
    print("[ksu-nova]   patched %s" % label)

if skipped:
    print("[ksu-nova]   note: skipped hooks for %s (not built without "
          "CONFIG_KSU_SUSFS)" % ", ".join(skipped))
if failed:
    sys.exit("[ksu-nova] ERROR: hook patch incomplete, see above")
PY
fi

# su itself depends on the execve hook; that one is mandatory.
grep -q 'ksu_handle_execveat' fs/exec.c || die "execve hook missing in fs/exec.c"

# Whatever a file does call must be defined: this is the check that would have
# caught the undefined ksu_handle_setresuid at link time instead of 15 minutes
# into a CI build.
for f in fs/exec.c kernel/reboot.c kernel/sys.c drivers/input/input.c \
         fs/open.c fs/stat.c; do
    for sym in $(sed -nE 's/^[[:space:]]+(ksu_handle_[a-z_]+)\(.*/\1/p' "$f"); do
        grep -rqs "^[A-Za-z_].*[[:space:]*]$sym(" "$KSU_DIR/kernel" \
            || die "$f calls $sym but the clone does not define it"
    done
done

# setresuid must be in setresuid(), not in the neighbouring setregid(), which
# opens with the same declarations. Only relevant when that hook exists.
inside_setresuid() {
    awk 'BEGIN{f=0;found=0}
         /^SYSCALL_DEFINE/ { if (f) exit; if (index($0, "(setresuid,")) f=1; next }
         f && index($0, "ksu_handle_setresuid(") { found=1 }
         END { exit !found }' kernel/sys.c
}
inside_setregid() {
    awk 'BEGIN{f=0;found=0}
         /^SYSCALL_DEFINE/ { if (f) exit; if (index($0, "(setregid,")) f=1; next }
         f && index($0, "ksu_handle_setresuid(") { found=1 }
         END { exit !found }' kernel/sys.c
}
if grep -q 'ksu_handle_setresuid' kernel/sys.c; then
    inside_setresuid || die "ksu_handle_setresuid() is not inside setresuid()"
    if inside_setregid; then
        die "ksu_handle_setresuid() landed in setregid()"
    fi
fi
ok "manual hook call sites in place ($(grep -l 'ksu_handle' fs/exec.c kernel/reboot.c kernel/sys.c drivers/input/input.c fs/open.c fs/stat.c | wc -l) files)"

# -------------------------------------------------------------- 5. defconfig ---

if [[ "$MODE" != check ]]; then
    python3 - "$DEFCONFIG" "$KSU_DIR/kernel/Kconfig" <<'PY'
import re
import sys

defconfig, kconfig = sys.argv[1], sys.argv[2]
kconf_text = open(kconfig).read()


def has_config(sym):
    return re.search(r'^[ \t]*config[ \t]+%s\b' % sym, kconf_text, re.M) is not None


# Everything SukiSU-Nova builds is unconditional except two Kconfig switches.
# The runtime features (su compat, kernel umount, sulog, selinux hide, shell su
# adb only, mount hide) are compiled in by the unity build in
# drivers/kernelsu/ksu_main.c and toggled from the manager, so they need no
# defconfig symbol.
wanted = ["CONFIG_KSU=y"]

if has_config("KSU_FEATURE_ADBROOT"):
    wanted.append("CONFIG_KSU_FEATURE_ADBROOT=y")

# KALLSYMS_ALL is what the manager reads to resolve symbols; without it the
# module list and the ksud paths degrade.
wanted += ["CONFIG_KALLSYMS=y", "CONFIG_KALLSYMS_ALL=y"]

# KPM is on. It is the one feature that loads third-party code into the kernel,
# so its Kconfig help warns about stability, and it only works when the image
# is post-processed by KernelPatch's patch_linux (the workflow does that). The
# 4.14 ports it needs are applied in section 3.4.
wanted += ["CONFIG_KPM=y"]

# SukiSU-Nova declares `CONFIG_KSU_SUSFS` default y, depending only on KSU and
# THREAD_INFO_IN_TASK. Leaving it unset selects it, and then its fs/mm/security
# hooks reference susfs_* symbols this kernel does not have -- a link failure at
# best. It has to be turned off explicitly, and that switch is also what keeps
# the faccessat/stat handlers on their 4.14 signatures.
if has_config("KSU_SUSFS"):
    wanted.append("# CONFIG_KSU_SUSFS is not set")

text = open(defconfig).read()
names = {re.match(r'^(?:# )?(CONFIG_[A-Z0-9_]+)', w).group(1) for w in wanted}

# Rebuild the block instead of merging into it: strip every existing line for
# these symbols and the marker we append, then write the canonical block back.
# An earlier version dropped the matching lines and only re-added the ones that
# had changed, which silently deleted CONFIG_KSU=y from the file.
out = []
for line in text.splitlines():
    m = re.match(r'^(?:# )?(CONFIG_[A-Z0-9_]+)(?: is not set|=[^\n]*)$', line)
    if m and m.group(1) in names:
        continue
    out.append(line)
while out and out[-1].strip() == "":
    out.pop()
while out and out[-1].startswith("# --- SukiSU-Nova"):
    out.pop()
    while out and out[-1].strip() == "":
        out.pop()

new_text = "\n".join(out + ["", "# --- SukiSU-Nova (kernel-level root) ---"] + wanted) + "\n"

if new_text != text:
    open(defconfig, "w").write(new_text)
    print("[ksu-nova]   defconfig: SukiSU-Nova block written (%d symbol(s))" % len(wanted))
else:
    print("[ksu-nova]   defconfig already complete")
PY
fi

for sym in CONFIG_KSU=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y; do
    grep -qx "$sym" "$DEFCONFIG" || die "defconfig missing $sym"
done
if grep -q '^config KSU_FEATURE_ADBROOT' "$KSU_DIR/kernel/Kconfig"; then
    grep -qx 'CONFIG_KSU_FEATURE_ADBROOT=y' "$DEFCONFIG" \
        || die "defconfig missing CONFIG_KSU_FEATURE_ADBROOT=y"
fi
grep -qx 'CONFIG_KPM=y' "$DEFCONFIG" || die "defconfig must set CONFIG_KPM=y"
if grep -qE '^CONFIG_KSU_SUSFS' "$DEFCONFIG"; then
    die "stale CONFIG_KSU_SUSFS* symbol in defconfig"
fi
if grep -q '^config KSU_SUSFS' "$KSU_DIR/kernel/Kconfig"; then
    grep -qx '# CONFIG_KSU_SUSFS is not set' "$DEFCONFIG" \
        || die "defconfig must switch CONFIG_KSU_SUSFS off (upstream default is y)"
fi
ok "defconfig: CONFIG_KSU=y, ADB root on, KPM on, no SUSFS symbols"

# ------------------------------------------------------------- 6. checklist ---

if [[ "$MODE" == check ]]; then
    log "check-only mode: nothing was changed"
fi

cat <<EOF

[ksu-nova] integration complete
[ksu-nova]   SukiSU-Nova : ${HEAD_SHA:-unknown}
[ksu-nova]   defconfig   : $DEFCONFIG
[ksu-nova]   features    : su compat, kernel umount, sulog, adb root,
[ksu-nova]                 shell su adb only, mount hide, cpu identity spoof,
[ksu-nova]                 KPM (CONFIG_KPM=y + the __arm64_sys_* shim;
[ksu-nova]                 the built Image must still be post-processed by
[ksu-nova]                 KernelPatch's kptools),
[ksu-nova]                 hide SELinux modification (pristine-policy
[ksu-nova]                 snapshot; 4.14 edition of SukiSU's >= 5.10 file),
[ksu-nova]                 AVC log spoofing (native, driven over the SUSFS
[ksu-nova]                 reboot() supercall; no SUSFS code involved)
[ksu-nova]   not included: SUSFS itself (the whole root-hiding layer)
[ksu-nova]   next        : scripts/build.sh --clang-dir <clang>/bin
[ksu-nova]   note        : CONFIG_KSU must still be =y in out/.config after
[ksu-nova]                 'make olddefconfig'; the workflow asserts that,
[ksu-nova]                 because an option whose dependency is unmet is
[ksu-nova]                 dropped silently.
EOF
