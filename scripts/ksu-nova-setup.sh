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
#   kind of thing that turns a working root into an unstable device. The only
#   files this script touches outside drivers/ are the four hook call sites.
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
# Two upstream conditionals are wrong for 4.14. Both are guarded so that this
# step fails loudly when upstream rewrites the surrounding code.

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

want = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
        "#define KSU_CAN_USE_KPM\n"
        "#endif\n")
old = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 4, 0)\n"
       "#define KSU_CAN_USE_KPM\n"
       "#endif\n")

if want in src:
    print("[ksu-nova]   KPM guard already >= 5.10")
elif old in src:
    # KPM needs 5.10+ interfaces (task_struct::pids, set_memory.h, ...). The
    # 4.4 guard drags them into 4.14 and fails to compile, so raise it. KPM
    # stays off; this only makes the dead code actually dead.
    open(path, "w").write(src.replace(old, want, 1))
    print("[ksu-nova]   raised KPM guard from 4.4.0 to 5.10.0")
else:
    sys.exit("[ksu-nova] ERROR: KPM guard anchor missing in " + path
             + " (upstream changed)")
PY
fi

grep -q 'KSU_CAN_USE_KPM' "$KSU_DIR/kernel/kernel_compat.h" || die "KPM guard vanished"

# ------------------------------------------------------------- 4. KSU hooks ---
#
# SukiSU-Nova's `builtin` ref is source-integrated: the kernel has to call its
# entry points itself. The signatures below are the ones its headers declare
# for a 4.14 kernel (kernel/feature/sucompat.h, kernel/hook/*.h).
#
# Every anchor is the full function signature, not just the opening brace, and
# the insertion is re-checked by offset afterwards. A brace-shaped anchor is
# how the setresuid hook once landed in setregid(): both bodies open with the
# same three lines, and the first match wins.
#
# faccessat and vfs_statx are hooked too: they are what makes an app's
# stat()/access() of /system/bin/su resolve to the su wrapper. Their signatures
# only line up because CONFIG_KSU_SUSFS is off -- with SUSFS enabled the same
# handlers take a `struct filename **`, which 4.14's `const char __user *` is
# not, and passing it compiles (separate TU) and corrupts memory at runtime.
# The defconfig assertion below keeps SUSFS off for exactly this reason.
#
# NOT hooked: ksu_handle_vfs_read (ksu_vfs_read_hook) -- the read-side hook is
# only needed by the legacy syscall-su path this ref does not use.

if [[ "$MODE" != check ]]; then
    python3 - <<'PY'
import sys

# (file, extern block, declaration anchor, insert-after anchor, call block, label)
#
# The call is inserted *after* the local declarations, not right after the
# opening brace: the kernel builds with -Wdeclaration-after-statement, and a
# statement before the declarations is the one thing here that a stricter
# downstream -Werror would reject.
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
        "fs/stat.c vfs_statx -> ksu_handle_stat()",
    ),
]

failed = False
for path, extern, decl_anchor, after_anchor, call, label in HOOKS:
    try:
        src = open(path).read()
    except FileNotFoundError:
        print("[ksu-nova] ERROR: %s not found" % path)
        failed = True
        continue

    if call in src:
        print("[ksu-nova]   ok: %s (already patched)" % label)
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
        at += 1            # anchor ended on "{\n" / a declaration line
    src = src[:at] + call + src[at:]

    # The call must sit inside the function we aimed at: after its signature
    # and before the next function starts.
    call_at = src.index(call)
    if not (decl_at < call_at <= decl_at + 2000):
        print("[ksu-nova] ERROR: %s hook landed outside its function" % path)
        failed = True
        continue

    open(path, "w").write(src)
    print("[ksu-nova]   patched %s" % label)

if failed:
    sys.exit("[ksu-nova] ERROR: hook patch incomplete, see above")
PY
fi

# Confirm the entry points this kernel calls actually exist in the clone, so a
# rebase of SukiSU-Nova cannot leave us calling a function with a new signature.
for sym in ksu_handle_execveat ksu_handle_sys_reboot ksu_handle_setresuid \
           ksu_handle_input_handle_event ksu_handle_faccessat ksu_handle_stat; do
    grep -rqs "$sym" "$KSU_DIR/kernel" || die "$sym not found in $KSU_DIR/kernel"
done
for f in fs/exec.c kernel/reboot.c kernel/sys.c drivers/input/input.c \
         fs/open.c fs/stat.c; do
    grep -q 'ksu_handle' "$f" || die "hook missing in $f"
done
# setresuid must be in setresuid(), not in the neighbouring setregid(), which
# opens with the same three lines. Scan the function body between syscall
# definitions instead of a fixed number of lines: the call sits after the local
# declarations, so its distance from the signature is not fixed.
inside_setresuid() {
    awk '/^SYSCALL_DEFINE3\(setresuid,/{f=1;next} /^SYSCALL_DEFINE/{f=0}
         f && /ksu_handle_setresuid\(/{found=1} END{exit !found}' kernel/sys.c
}
inside_setregid() {
    awk '/^SYSCALL_DEFINE2\(setregid,/{f=1;next} /^SYSCALL_DEFINE/{f=0}
         f && /ksu_handle_setresuid\(/{found=1} END{exit !found}' kernel/sys.c
}
inside_setresuid || die "ksu_handle_setresuid() is not inside setresuid()"
if inside_setregid; then
    die "ksu_handle_setresuid() landed in setregid()"
fi
ok "manual hook call sites in place (exec, faccessat, stat, reboot, setresuid, input)"

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

# KPM is deliberately off: its own Kconfig help says it "may affect system
# stability", it needs 5.10+ interfaces, and loading arbitrary LKMs is the one
# KernelSU feature with a real bootloop footprint. Setting it to n explicitly
# also documents that the choice was made on purpose.
wanted += ["# CONFIG_KPM is not set"]

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
grep -qx '# CONFIG_KPM is not set' "$DEFCONFIG" || die "defconfig must keep KPM off"
if grep -qE '^CONFIG_KSU_SUSFS' "$DEFCONFIG"; then
    die "stale CONFIG_KSU_SUSFS* symbol in defconfig"
fi
if grep -q '^config KSU_SUSFS' "$KSU_DIR/kernel/Kconfig"; then
    grep -qx '# CONFIG_KSU_SUSFS is not set' "$DEFCONFIG" \
        || die "defconfig must switch CONFIG_KSU_SUSFS off (upstream default is y)"
fi
ok "defconfig: CONFIG_KSU=y, ADB root on, KPM off, no SUSFS symbols"

# ------------------------------------------------------------- 6. checklist ---

if [[ "$MODE" == check ]]; then
    log "check-only mode: nothing was changed"
fi

cat <<EOF

[ksu-nova] integration complete
[ksu-nova]   SukiSU-Nova : ${HEAD_SHA:-unknown}
[ksu-nova]   defconfig   : $DEFCONFIG
[ksu-nova]   features    : su compat, kernel umount, sulog, adb root,
[ksu-nova]                 selinux hide, shell su adb only, mount hide
[ksu-nova]                 (manager-toggled; compiled in unconditionally)
[ksu-nova]   not included: SUSFS, KPM
[ksu-nova]   next        : scripts/build.sh --clang-dir <clang>/bin
[ksu-nova]   note        : CONFIG_KSU must still be =y in out/.config after
[ksu-nova]                 'make olddefconfig'; the workflow asserts that,
[ksu-nova]                 because an option whose dependency is unmet is
[ksu-nova]                 dropped silently.
EOF
