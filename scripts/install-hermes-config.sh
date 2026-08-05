#!/usr/bin/env bash
# Render config/cli-config.yaml into ~/.hermes/cli-config.yaml, substituting
# absolute paths. Idempotent; backs up any existing config first.
#
# Substitutes __HOME__ so no config value depends on tilde expansion, and
# backs up any existing config instead of clobbering it. Hand-editing paths on
# a machine with no clipboard is how typos get in, so it is generated.
set -euo pipefail

# Resolve the repo from this script's own location. Do NOT assume ~/work-agent:
# the clone can live anywhere (it was at ~/Projects/work-agent on the work M4),
# and a wrong path here makes the MCP server fail to spawn -- which Hermes
# reports by silently having no tools, not by erroring.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/config/cli-config.yaml"
DEST_DIR="$HOME/.hermes"
DEST="$DEST_DIR/cli-config.yaml"

[ -f "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }

mkdir -p "$DEST_DIR"

if [ -f "$DEST" ]; then
  # Never silently clobber: a Hermes config may hold hand-tuned settings, and
  # on this machine it is not reconstructible from anywhere else.
  BACKUP="$DEST.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$DEST" "$BACKUP"
  echo "==> Existing config backed up to $BACKUP"
  echo "    Merge anything you had customised — this writes a fresh file."
fi

# Absolute interpreter path: a GUI-launched Hermes does not inherit the shell
# PATH, so a bare "python3" in the config spawns fine from a terminal and not
# at all from the desktop app -- silently, leaving Hermes with no cua tools.
PYBIN="$(command -v python3 || true)"
[ -n "$PYBIN" ] || { echo "ERROR: python3 not found on PATH" >&2; exit 1; }

sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" -e "s|__PYTHON__|$PYBIN|g" \
    "$SRC" > "$DEST"

if grep -qE "__HOME__|__PYTHON__|__REPO__" "$DEST"; then
  echo "ERROR: placeholder substitution failed — $DEST still has placeholders" >&2
  exit 1
fi

# Verify every path the config names actually exists. A missing MCP command is
# the worst failure mode here: Hermes starts fine and simply has no tools.
MISSING=0
for p in "$REPO/scripts/cua-mcp-shim.py" "$REPO/skills" "$PYBIN"; do
  [ -e "$p" ] || { echo "ERROR: config references a missing path: $p" >&2; MISSING=1; }
done
[ "$MISSING" -eq 0 ] || exit 1

echo "==> Repo:        $REPO"
echo "==> Interpreter: $PYBIN"

# MCP servers live in ~/.hermes/config.yaml, NOT in cli-config.yaml. An
# mcp_servers block in the wrong file is ignored without comment -- the cua
# server looked configured for hours while never spawning, presenting as
# "the tools just don't support these parameters".
#
# `hermes mcp add` writes the correct file and merges, so it is used instead
# of hand-editing YAML we would be guessing at.
SHIM="$REPO/scripts/cua-mcp-shim.py"
MANUAL="hermes mcp add cua --command $PYBIN --args $SHIM"
echo "==> Registering the cua MCP server"
if ! command -v hermes >/dev/null 2>&1; then
  echo "    WARNING: hermes not on PATH. Register manually:" >&2
  echo "      $MANUAL" >&2
else
  # `hermes mcp add` prompts "Server 'cua' already exists. Overwrite? [y/N]"
  # when re-registering. Capturing stdout swallows that prompt, so it never
  # reaches the terminal, gets no answer, defaults to No -- and still exits 0.
  # Answer it on stdin instead of hoping.
  #
  # Overwriting is the intent: `hermes computer-use install` registers a `cua`
  # server pointing straight at the driver, which bypasses the shim entirely.
  OUT="$(printf 'y\n' | hermes mcp add cua --command "$PYBIN" --args "$SHIM" 2>&1)"
  RC=$?
  [ -n "$OUT" ] && printf '    %s\n' "$OUT"

  # Exit code alone is not enough -- a cancelled overwrite still exits 0.
  if [ "$RC" -ne 0 ] || printf '%s' "$OUT" | grep -qi "cancel"; then
    echo >&2
    echo "    WARNING: the cua server was NOT pointed at the shim." >&2
    echo "    An existing entry (likely from 'hermes computer-use install')" >&2
    echo "    takes precedence and bypasses it. Fix with:" >&2
    echo "      hermes mcp remove cua   # then:" >&2
    echo "      $MANUAL" >&2
  else
    echo "    registered -> $SHIM"
  fi
fi
echo
echo "    Verify with:  hermes mcp test cua"
echo "    Shim log:     ~/.hermes/cua-shim.log"

# cua-driver ships its own version-matched skill pack, but Hermes is NOT in
# the driver's auto-detect list (Claude Code, Codex, OpenClaw, OpenCode), so
# nothing links it in for us. Ask the driver where the pack actually lives
# rather than hardcoding a path, and append it to skills.external_dirs.
# Guard with command -v: under `set -e` a failing command substitution aborts
# the script, so an absent cua-driver would kill it here -- silently, and
# AFTER the config was already written, so it looks like a failed run.
PACK=""
if command -v cua-driver >/dev/null 2>&1; then
  PACK="$(cua-driver skills path 2>/dev/null | tr -d '\r' | head -1 || true)"
fi
if [ -n "$PACK" ] && [ -d "$PACK" ]; then
  if grep -qF "$PACK" "$DEST"; then
    echo "==> cua skill pack already listed: $PACK"
  else
    # Insert under external_dirs, matching its existing list indentation.
    python3 - "$DEST" "$PACK" <<'PY'
import sys, re
dest, pack = sys.argv[1], sys.argv[2]
lines = open(dest).read().splitlines(True)
out, added = [], False
for i, l in enumerate(lines):
    out.append(l)
    if not added and re.match(r'^\s*external_dirs:\s*$', l):
        # find the indent used by the first list item that follows
        indent = "    - "
        for nxt in lines[i+1:]:
            m = re.match(r'^(\s*-\s)', nxt)
            if m:
                indent = m.group(1); break
            if nxt.strip() and not nxt.lstrip().startswith('#'):
                break
        out.append(f"{indent}{pack}\n")
        added = True
open(dest, 'w').write("".join(out))
sys.exit(0 if added else 1)
PY
    [ $? -eq 0 ] || echo "WARNING: could not find external_dirs to append to." >&2
    echo "==> Added cua skill pack to external_dirs: $PACK"
  fi
else
  echo "==> NOTE: cua-driver skill pack not found." >&2
  echo "    Install it with: cua-driver skills install" >&2
  echo "    then re-run this script to wire it into Hermes." >&2
fi

echo "==> Wrote $DEST"
