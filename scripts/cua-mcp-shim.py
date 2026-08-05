#!/usr/bin/env python3
"""MCP stdio proxy that enforces bounded window reads.

Sits between Hermes and `cua-driver mcp`, forwarding JSON-RPC verbatim except
for window-read calls, whose arguments are clamped before they reach the
driver.

Why this exists
---------------
Asking the model to pass limits does not work. Measured on the work M4
2026-08-05, with the parameters documented in browser-ops AND the cua-driver
skill pack loaded, a single Zendesk turn still produced a ~56,800-token
prompt: ~140 s before the first token and 87% of a 65,536 context consumed in
one exchange. A bounded read of the same page is ~2,000 tokens and ~4 s.

Guidance the model may ignore is not a limit. This makes it one.

Configuration (env):
  CUA_SHIM_MAX_ELEMENTS   default 300   (driver default is 2000)
  CUA_SHIM_MAX_DEPTH      default 10    (driver default is 25)
  CUA_SHIM_ALLOW_SCREENSHOT  set to 1 to permit include_screenshot=true
  CUA_SHIM_CMD            default "cua-driver"
  CUA_SHIM_QUIET          set to 1 to silence clamp logging
"""
import json
import os
import subprocess
import sys
import threading

MAX_ELEMENTS = int(os.environ.get("CUA_SHIM_MAX_ELEMENTS", "300"))
MAX_DEPTH = int(os.environ.get("CUA_SHIM_MAX_DEPTH", "10"))
ALLOW_SHOT = os.environ.get("CUA_SHIM_ALLOW_SCREENSHOT") == "1"
QUIET = os.environ.get("CUA_SHIM_QUIET") == "1"


def find_driver():
    """Locate cua-driver without relying on PATH.

    GUI-launched macOS apps (Hermes desktop) do NOT inherit the shell's PATH,
    so a bare "cua-driver" resolves fine from a terminal and not at all from
    the app -- and the MCP server then fails to spawn with no visible error.
    Upstream hits the same class of bug: hermes-agent#69138.
    """
    explicit = os.environ.get("CUA_SHIM_CMD")
    if explicit:
        return explicit
    from shutil import which
    found = which("cua-driver")
    if found:
        return found
    home = os.path.expanduser("~")
    for cand in (
        f"{home}/.local/bin/cua-driver",
        "/usr/local/bin/cua-driver",
        "/opt/homebrew/bin/cua-driver",
        f"{home}/.cua/bin/cua-driver",
        "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
    ):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return "cua-driver"  # let exec fail loudly rather than guess further


DRIVER = find_driver()

# Tools whose results are unbounded page dumps. Names are matched loosely so a
# driver rename does not silently disable the clamp.
WINDOW_READS = ("get_window_state", "get_browser_state")


def log(msg):
    if not QUIET:
        # stderr only: stdout is the JSON-RPC transport and must stay clean.
        print(f"[cua-shim] {msg}", file=sys.stderr, flush=True)


def clamp(args):
    """Bound one tool call's arguments. Returns a list of changes made."""
    changed = []

    cur = args.get("max_elements")
    if not isinstance(cur, int) or cur > MAX_ELEMENTS:
        args["max_elements"] = MAX_ELEMENTS
        changed.append(f"max_elements {cur!r}->{MAX_ELEMENTS}")

    cur = args.get("max_depth")
    if not isinstance(cur, int) or cur > MAX_DEPTH:
        args["max_depth"] = MAX_DEPTH
        changed.append(f"max_depth {cur!r}->{MAX_DEPTH}")

    if not ALLOW_SHOT and args.get("include_screenshot") is not False:
        # Defaults to TRUE upstream, so absence is not neutral.
        args["include_screenshot"] = False
        changed.append("include_screenshot->false")

    return changed


def rewrite(line):
    """Rewrite one client->driver message. Anything unparseable passes through
    untouched: this proxy must never be the reason a request breaks."""
    try:
        msg = json.loads(line)
    except (ValueError, TypeError):
        return line
    if not isinstance(msg, dict) or msg.get("method") != "tools/call":
        return line

    params = msg.get("params")
    if not isinstance(params, dict):
        return line
    name = params.get("name", "")
    if not any(w in name for w in WINDOW_READS):
        return line

    args = params.get("arguments")
    if args is None:
        args = params["arguments"] = {}
    if not isinstance(args, dict):
        return line

    changes = clamp(args)
    if changes:
        log(f"{name}: " + ", ".join(changes))
    return json.dumps(msg, separators=(",", ":")) + "\n"


def pump_out(child):
    """Driver -> client, verbatim."""
    for line in child.stdout:
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()


def main():
    argv = [DRIVER, "mcp"] + sys.argv[1:]
    try:
        child = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE
        )
    except FileNotFoundError:
        print(f"[cua-shim] cannot exec {DRIVER}", file=sys.stderr)
        return 127

    log(
        f"proxying {' '.join(argv)} "
        f"(max_elements<={MAX_ELEMENTS}, max_depth<={MAX_DEPTH}, "
        f"screenshots={'allowed' if ALLOW_SHOT else 'forced off'})"
    )

    t = threading.Thread(target=pump_out, args=(child,), daemon=True)
    t.start()

    try:
        for raw in sys.stdin.buffer:
            out = rewrite(raw.decode("utf-8", "replace"))
            child.stdin.write(out.encode("utf-8") if isinstance(out, str) else out)
            child.stdin.flush()
    except BrokenPipeError:
        pass
    finally:
        try:
            child.stdin.close()
        except Exception:
            pass
    return child.wait()


if __name__ == "__main__":
    sys.exit(main())
