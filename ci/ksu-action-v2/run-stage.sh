#!/usr/bin/env bash
# Run one KernelSU_Action_V2 stage and keep its complete output.
#
# The action's own job log is enough when you are looking at the run in a
# browser. It is not enough when the log endpoint is unreachable, and a failure
# four steps deep is exactly when you want the text. Every stage is therefore
# also written to $LOG_DIR/<stage>.log and uploaded even when the run fails.
#
# Usage: run-stage.sh <stage> [args...]      (from the action's repo root)

set -uo pipefail

stage=${1:?usage: run-stage.sh <stage> [args...]}
shift

logdir=${LOG_DIR:-${PWD}/../logs}
mkdir -p "$logdir"
log="${logdir}/${stage}.log"

{
	printf '=== stage: %s %s\n' "$stage" "$*"
	printf '=== started: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$log"

bash "scripts/${stage}.sh" "$@" 2>&1 | tee -a "$log"
rc=${PIPESTATUS[0]}

printf '=== finished: %s (rc=%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" | tee -a "$log"

if [ "$rc" -ne 0 ]; then
	# GitHub annotations survive even when the log cannot be downloaded, and
	# they are the only channel that does: the job log endpoint is unreachable
	# from some clients, and the artefact zip is served from blob storage.
	#
	# Matched error lines first; if the stage failed without anything that
	# looks like an error (make's "$(error ...)" text, for example, is a bare
	# sentence ending in "Stop."), fall back to the tail, which is where make
	# prints it.
	matched=$(grep -nE 'error:|\bx\]|undefined reference|No rule to make|\*{3}|Stop\.|Error [0-9]+$' "$log" | head -20)
	if [ -n "$matched" ]; then
		printf '%s\n' "$matched" |
			while IFS= read -r line; do
				echo "::error::${stage}: ${line//%/}"
			done
	else
		tail -n 15 "$log" |
			while IFS= read -r line; do
				[ -n "$line" ] || continue
				echo "::error::${stage} (tail): ${line//%/}"
			done
	fi
fi

exit "$rc"
