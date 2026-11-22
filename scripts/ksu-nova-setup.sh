#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ksu-nova-setup.sh -- reproducible SukiSU-Nova + SUSFS integration for the
# miatoll 4.14.357 tree.
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
#   kprobes. Its own Kconfig declares CONFIG_KSU and the CONFIG_KSU_SUSFS_*
#   menu, but it does not carry the SUSFS kernel side (fs/susfs.c and the fs/
#   hook hunks), so that comes from patches/susfs/susfs-4.14-v2.4.0.patch.
#
# WHY THESE EXACT SOURCES (the short version of docs/KSU-SUSFS.md)
#   * SUSFS v2.4.0 is the API generation SukiSU-Nova calls. The official
#     susfs4ksu branch for 4.14 (kernel-4.14) is frozen at v1.5.5: it is
#     missing susfs_add_sus_map(), susfs_set_priority_uid_filter(),
#     susfs_get_enabled_features() and friends, so SukiSU-Nova would link
#     against 11 symbols that do not exist. The vendored patch is the v2.4.0
#     port for 4.14, rebased onto this tree so it applies with zero fuzz.
#   * The patch is committed rather than fetched. Upstream 4.14 branches are
#     either too old (v1.5.5) or written for another kernel (the v2.4.0 port
#     exists for 3.10 and 4.9); pinning it here is what makes the result both
#     reproducible and reviewable.
#   * SukiSU-Nova is pinned by commit SHA, not by branch. `builtin` moves.
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
SUSFS_PATCH="${SUSFS_PATCH:-patches/susfs/susfs-4.14-v2.4.0.patch}"

MODE=apply
for arg in "$@"; do
    case "$arg" in
        --check)   MODE=check ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
    esac
done

log()  { printf '[ksu-nova] %s\n' "$*"; }
ok()   { printf '[ksu-nova]   ok: %s\n' "$*"; }
warn() { printf '[ksu-nova]   warn: %s\n' "$*" >&2; }
die()  { printf '[ksu-nova] ERROR: %s\n' "$*" >&2; exit 1; }

# Fail loudly instead of silently skipping half the integration. Every step
# below depends on an exact anchor in an upstream file; when upstream changes,
# this is what tells you, rather than a "successful" build with a feature
# quietly compiled out.
need_anchor() {
    local file=$1 anchor=$2
    grep -qF -- "$anchor" "$file" \
        || die "anchor not found in ${file}:
---8<---
${anchor}
--->8---
Upstream changed its source layout. Update this script instead of shipping a
kernel where the hook/SUSFS hunk was silently not applied."
}

run_python() {
    if [[ "$MODE" == check ]]; then
        python3 "$@" --check-only
    else
        python3 "$@"
    fi
}

cd "$KERNEL_DIR"

# --------------------------------------------------------------- 0. sanity ---

KVER="$(sed -n -e 's/^VERSION = //p' -e 's/^PATCHLEVEL = //p' Makefile | paste -sd. -)"
[[ "$KVER" == "4.14" ]] || die "this integration targets Linux 4.14, found $KVER"
[[ -f "$DEFCONFIG" ]] || die "defconfig not found: $DEFCONFIG"
[[ -f "$SUSFS_PATCH" ]] || die "vendored SUSFS patch missing: $SUSFS_PATCH"
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
    # Validate the ref *before* using it. Every KernelSU setup.sh ends its
    # checkout with `git checkout "$1" || echo "checkout default branch"`, so a
    # typo or a stale branch name does not fail -- it silently leaves you on
    # the default branch, and you ship a kernel with none of what you asked
    # for. (SukiSU's own docs long recommended a `susfs-main` ref that never
    # existed.) The checks below turn that into a hard error.
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
        HEAD_SHA="${HEAD_SHA:-}"
    fi

    if [[ ! -d "$KSU_DIR/kernel" ]]; then
        log "fetching SukiSU-Nova ($KSU_REF)"
        rm -rf "$KSU_DIR"
        mkdir -p "$KSU_DIR"
        git -C "$KSU_DIR" init -q .
        git -C "$KSU_DIR" remote add origin "$KSU_REPO"
        # --depth 1 on a SHA: GitHub allows fetching an arbitrary reachable
        # commit, so a pinned build stays a one-commit download instead of the
        # full history.
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
# wiring goes into tracked files, so it is re-applied whenever it is missing
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
    python3 - "KernelSU/kernel/kernel_includes.h" <<'PY'
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

    python3 - "KernelSU/kernel/kernel_compat.h" <<'PY'
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
    # 4.4 guard drags them into 4.14 and fails to compile, so raise it.
    open(path, "w").write(src.replace(old, want, 1))
    print("[ksu-nova]   raised KPM guard from 4.4.0 to 5.10.0")
else:
    sys.exit("[ksu-nova] ERROR: KPM guard anchor missing in " + path
             + " (upstream changed)")
PY
fi

grep -q 'KSU_CAN_USE_KPM' KernelSU/kernel/kernel_compat.h || die "KPM guard vanished"

# ------------------------------------------------------------- 4. KSU hooks ---
#
# SukiSU-Nova's `builtin` ref is source-integrated: the kernel has to call its
# entry points itself. The signatures below are the ones its headers declare
# for a 4.14 kernel with CONFIG_KSU_SUSFS=y (kernel/feature/sucompat.h).
#
# NOT hooked, deliberately:
#   * SYSCALL_DEFINE3(faccessat) / vfs_statx  -- in the SUSFS build those
#     handlers take `struct filename **`, but 4.14 only has a
#     `const char __user *` at that point. Passing the wrong pointer type
#     compiles (separate TU) and corrupts memory at runtime. `su` itself is
#     handled by the execve hook, which is present; the faccessat/stat hooks
#     only implement the legacy in-kernel "syscall su" path.
#   * ksu_handle_devpts / ksu_handle_vfs_read -- not used by this ref.

if [[ "$MODE" != check ]]; then
    python3 - <<'PY'
import sys

HOOKS = [
    # (file, extern block, call site anchor, call, label)
    (
        "fs/exec.c",
        "#ifdef CONFIG_KSU\n"
        "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
        "\t\t\t       void *argv, void *envp, int *flags);\n"
        "#endif\n\n",
        "static int do_execveat_common(int fd, struct filename *filename,",
        "{\n"
        "\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);",
        "{\n"
        "#ifdef CONFIG_KSU\n"
        "\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
        "#endif\n"
        "\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);",
        "fs/exec.c do_execveat_common -> ksu_handle_execveat()",
    ),
    (
        "kernel/reboot.c",
        "#ifdef CONFIG_KSU\n"
        "extern int ksu_handle_sys_reboot(int magic1, int magic2,\n"
        "\t\t\t\t unsigned int cmd, void __user **arg);\n"
        "#endif\n\n",
        "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,",
        "{\n\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);",
        "{\n"
        "#ifdef CONFIG_KSU\n"
        "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
        "#endif\n"
        "\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);",
        "kernel/reboot.c reboot -> ksu_handle_sys_reboot()",
    ),
    (
        "kernel/sys.c",
        "#ifdef CONFIG_KSU\n"
        "extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n"
        "#endif\n\n",
        "SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)",
        "{\n\tstruct user_namespace *ns = current_user_ns();",
        "{\n"
        "#ifdef CONFIG_KSU\n"
        "\tksu_handle_setresuid(ruid, euid, suid);\n"
        "#endif\n"
        "\tstruct user_namespace *ns = current_user_ns();",
        "kernel/sys.c setresuid -> ksu_handle_setresuid()",
    ),
    (
        "drivers/input/input.c",
        "#ifdef CONFIG_KSU\n"
        "extern int ksu_handle_input_handle_event(unsigned int *type,\n"
        "\t\t\t\t\t unsigned int *code, int *value);\n"
        "#endif\n\n",
        "static void input_handle_event(struct input_dev *dev,",
        "{\n\tint disposition = input_get_disposition(dev, type, code, &value);",
        "{\n"
        "#ifdef CONFIG_KSU\n"
        "\tksu_handle_input_handle_event(&type, &code, &value);\n"
        "#endif\n"
        "\tint disposition = input_get_disposition(dev, type, code, &value);",
        "drivers/input/input.c input_handle_event -> ksu_handle_input_handle_event()",
    ),
]

failed = False
for path, extern, decl_anchor, body_anchor, body, label in HOOKS:
    try:
        src = open(path).read()
    except FileNotFoundError:
        sys.exit("[ksu-nova] ERROR: %s not found" % path)

    if "ksu_handle" in src:
        print("[ksu-nova]   ok: %s (already patched)" % label)
        continue

    if decl_anchor not in src:
        print("[ksu-nova] ERROR: decl anchor missing in %s" % path)
        failed = True
        continue
    if body_anchor not in src:
        print("[ksu-nova] ERROR: call-site anchor missing in %s" % path)
        failed = True
        continue

    src = src.replace(decl_anchor, extern + decl_anchor, 1)
    src = src.replace(body_anchor, body, 1)
    open(path, "w").write(src)
    print("[ksu-nova]   patched %s" % label)

if failed:
    sys.exit("[ksu-nova] ERROR: hook patch incomplete, see above")
PY
fi

# Confirm the entry points this kernel calls actually exist in the clone, so a
# rebase of SukiSU-Nova cannot leave us calling a function with a new signature.
for sym in ksu_handle_execveat ksu_handle_sys_reboot ksu_handle_setresuid \
           ksu_handle_input_handle_event; do
    grep -rqs "$sym" "$KSU_DIR/kernel" || die "$sym not found in $KSU_DIR/kernel"
done
for f in fs/exec.c kernel/reboot.c kernel/sys.c drivers/input/input.c; do
    grep -q 'ksu_handle' "$f" || die "hook missing in $f"
done
ok "manual hook call sites in place (exec, faccessat skipped, reboot, setresuid, input)"

# ----------------------------------------------------------------- 5. SUSFS ---
#
# SukiSU-Nova only ships the KernelSU *side* of SUSFS (Kconfig menu, supercall
# handlers, the /proc/susfs interface). The kernel side -- fs/susfs.c, the
# susfs_def.h bookkeeping, and the hunks in fs/, mm/ and security/ -- is this
# patch.

SUSFS_MARKER="fs/susfs.c"
if [[ -f "$SUSFS_MARKER" ]] && grep -q 'susfs' fs/Makefile; then
    ok "SUSFS kernel side already present"
elif [[ "$MODE" == check ]]; then
    die "SUSFS kernel side missing; run without --check"
else
    log "applying $(basename "$SUSFS_PATCH")"
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git apply --check "$SUSFS_PATCH" \
            || die "vendored SUSFS patch does not apply -- the tree was modified"
        git apply "$SUSFS_PATCH"
    else
        patch -p1 --forward --fuzz=0 < "$SUSFS_PATCH" \
            || die "vendored SUSFS patch does not apply -- the tree was modified"
    fi
fi

[[ -f fs/susfs.c ]] || die "fs/susfs.c missing after patch"
[[ -f include/linux/susfs.h ]] || die "include/linux/susfs.h missing after patch"
[[ -f include/linux/susfs_def.h ]] || die "include/linux/susfs_def.h missing after patch"
grep -q 'susfs' fs/Makefile || die "fs/Makefile not wired for susfs.o"
ok "SUSFS $(sed -nE 's/.*SUSFS_VERSION[[:space:]]+"([^"]+)".*/\1/p' include/linux/susfs.h | head -n1) kernel side applied"

# -------------------------------------------------------------- 6. defconfig ---
#
# The SUSFS option set is discovered from the Kconfig that is actually
# installed instead of being hardcoded: an option that does not exist is
# silently dropped from a defconfig, so a stale hardcoded list ships a kernel
# that looks patched and hides nothing.

if [[ "$MODE" != check ]]; then
    python3 - "$DEFCONFIG" "$KSU_DIR/kernel/Kconfig" <<'PY'
import re
import sys

defconfig, kconfig = sys.argv[1], sys.argv[2]
kconf_text = open(kconfig).read()

susfs_syms = sorted(set(re.findall(r'^[ \t]*config[ \t]+(KSU_SUSFS[A-Z_0-9]*)',
                                  kconf_text, re.M)))
if not susfs_syms:
    sys.exit("[ksu-nova] ERROR: no KSU_SUSFS* symbols in %s -- the SUSFS menu "
             "disappeared from SukiSU-Nova" % kconfig)

wanted = ["CONFIG_KSU=y"]
if re.search(r'^[ \t]*config[ \t]+KSU_FEATURE_ADBROOT', kconf_text, re.M):
    wanted.append("CONFIG_KSU_FEATURE_ADBROOT=y")
# KALLSYMS_ALL is what the manager reads to resolve symbols; without it the
# module list and su --ksud paths degrade.
wanted += ["CONFIG_KALLSYMS=y", "CONFIG_KALLSYMS_ALL=y"]
wanted += ["CONFIG_%s=y" % s for s in susfs_syms]

# The SUSFS menu depends on THREAD_INFO_IN_TASK. arm64 selects it, but assert
# it in the defconfig as well: on trees where it is optional, a missing symbol
# silently turns CONFIG_KSU_SUSFS off.
if re.search(r'depends on[^\n]*THREAD_INFO_IN_TASK', kconf_text):
    wanted.append("CONFIG_THREAD_INFO_IN_TASK=y")

text = open(defconfig).read()
lines = text.splitlines()
names = {w.split("=")[0] for w in wanted}

# Remember what the defconfig says today, then rewrite only what differs, so
# re-running the script is a no-op and git stays clean.
present, out = {}, []
for line in lines:
    m = re.match(r'^(?:# )?(CONFIG_[A-Z0-9_]+)(?: is not set|=[^\n]*)$', line)
    if m and m.group(1) in names:
        present[m.group(1)] = line
        continue          # stale value; re-added below if still wanted
    out.append(line)

changed = [w for w in wanted if present.get(w.split("=")[0]) != w]

if changed:
    out.append("")
    out.append("# --- SukiSU-Nova + SUSFS (kernel-level root) ---")
    out.extend(changed)
    open(defconfig, "w").write("\n".join(out) + "\n")
    print("[ksu-nova]   defconfig: %d symbol(s) added/updated" % len(changed))
else:
    print("[ksu-nova]   defconfig already complete (%d SUSFS options)" % len(susfs_syms))
PY
fi

for sym in CONFIG_KSU=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y; do
    grep -qx "$sym" "$DEFCONFIG" || die "defconfig missing $sym"
done
SUSFS_COUNT="$(grep -cE '^CONFIG_KSU_SUSFS[A-Z_0-9]*=y$' "$DEFCONFIG")"
((SUSFS_COUNT > 0)) || die "defconfig has no CONFIG_KSU_SUSFS*=y options"
ok "defconfig: CONFIG_KSU=y, $SUSFS_COUNT SUSFS options enabled"

# ------------------------------------------------------------- 7. checklist ---

if [[ "$MODE" == check ]]; then
    log "check-only mode: nothing was changed"
fi

cat <<EOF

[ksu-nova] integration complete
[ksu-nova]   SukiSU-Nova : ${HEAD_SHA:-unknown}
[ksu-nova]   SUSFS patch : $(basename "$SUSFS_PATCH") ($(sed -nE 's/.*SUSFS_VERSION[[:space:]]+"([^"]+)".*/\1/p' include/linux/susfs.h | head -n1))
[ksu-nova]   defconfig   : $DEFCONFIG
[ksu-nova]   next        : scripts/build.sh --clang-dir <clang>/bin
[ksu-nova]   note        : CONFIG_KSU / CONFIG_KSU_SUSFS must still be =y in
[ksu-nova]                 out/.config after 'make olddefconfig'; the workflow
[ksu-nova]                 asserts that, because an option whose dependency is
[ksu-nova]                 unmet is dropped silently.
EOF
