#!/usr/bin/env bash
# Stop whatever is serving on the port, then start serve.sh with the env you
# pass. Intended for A/B runs:
#
#   bash scripts/restart.sh
#   WORK_AGENT_SPEC=off  bash scripts/restart.sh
#   WORK_AGENT_KV=q8_0   bash scripts/restart.sh
#
# No -e: the whole stop sequence should run even when a step finds nothing.
set -uo pipefail

PORT="${WORK_AGENT_PORT:-8080}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Detection is lsof, NOT bash's /dev/tcp -- deliberately different from the
# guard in setup/02-model.sh, which does use /dev/tcp.
#
# The difference is what each script faces. 02-model.sh decides whether to
# refuse startup against a presumed-healthy server, where /dev/tcp's advantage
# (no dependency, sees other users' listeners) is worth having. This script
# exists to recover a WEDGED server -- and a listener that has stopped
# accepting fills its backlog, after which connect() blocks forever with no
# timeout and no `timeout` binary on macOS to bound it. Probing the port is
# the one thing you must not do here.
#
# lsof reads kernel state and cannot block on the peer.
holders() {
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -ti ":$PORT" -sTCP:LISTEN 2>/dev/null
}

any_alive() { local p; for p in $1; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }

if ! command -v lsof >/dev/null 2>&1; then
  echo "WARNING: lsof not found — cannot identify or stop an existing server." >&2
  echo "         Starting anyway; if the port is taken, llama-server will say so." >&2
else
  PIDS=$(holders | tr '\n' ' ')

  if [ -z "${PIDS// /}" ]; then
    echo "==> Nothing listening on :$PORT"
  else
    # A second llama-server is the usual reason `kill <pid>` "doesn't work":
    # you killed one and lsof still shows the other. Informational only -- we
    # signal the port holders, never everything named llama-server, which
    # would take out a server on an unrelated port. -x matches the process
    # name exactly; -f would also match any command line containing it.
    ALL=$(pgrep -x llama-server 2>/dev/null | tr '\n' ' ')
    [ -n "${ALL// /}" ] && echo "==> llama-server pids on this machine: $ALL"

    echo "==> Stopping on :$PORT — pids: $PIDS"
    # shellcheck disable=SC2086
    kill $PIDS 2>/dev/null

    # Wait on the processes, not the port. SIGTERM is not instant: ~20 GB has
    # to be unmapped and a Metal context torn down, and the process can sit in
    # a GPU wait. `kill -0` cannot block.
    for _ in $(seq 1 30); do
      any_alive "$PIDS" || break
      sleep 1
    done

    if any_alive "$PIDS"; then
      echo "==> Still up after 30s — SIGKILL"
      # shellcheck disable=SC2086
      kill -9 $PIDS 2>/dev/null
      for _ in $(seq 1 15); do
        any_alive "$PIDS" || break
        sleep 1
      done
    fi

    if any_alive "$PIDS"; then
      echo "ERROR: pids $PIDS survived SIGKILL — stuck in a kernel wait." >&2
      echo "       Reboot, or use WORK_AGENT_PORT to pick a free port." >&2
      exit 1
    fi

    # Re-read rather than probe: catches something else having taken the port.
    STILL=$(holders | tr '\n' ' ')
    if [ -n "${STILL// /}" ]; then
      echo "ERROR: :$PORT is still held, now by pids: $STILL" >&2
      lsof -i ":$PORT" -sTCP:LISTEN >&2
      exit 1
    fi
    echo "==> Port free"
  fi
fi

echo
exec "$DIR/serve.sh"
