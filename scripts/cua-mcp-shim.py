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
import time

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


# Where a stdio MCP server's stderr ends up is the CLIENT's choice: inherited
# to a terminal, captured to a log, or discarded. The Hermes desktop app shows
# none of it. So log to a file as well -- a diagnostic you cannot read is not
# a diagnostic, and this session lost hours to exactly that.
LOGFILE = os.environ.get(
    "CUA_SHIM_LOG", os.path.expanduser("~/.hermes/cua-shim.log")
)


def log(msg):
    if QUIET:
        return
    line = f"[cua-shim] {msg}"
    # stderr never carries protocol: stdout is the transport and must stay clean.
    print(line, file=sys.stderr, flush=True)
    if not LOGFILE:
        return
    try:
        os.makedirs(os.path.dirname(LOGFILE), exist_ok=True)
        with open(LOGFILE, "a") as fh:
            fh.write(f"{_stamp()} {line}\n")
    except OSError:
        pass  # logging must never take the proxy down with it


def _stamp():
    from datetime import datetime
    return datetime.now().strftime("%H:%M:%S")


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


def filter_tools(msg):
    """Trim the advertised tool list, and always report its cost.

    Tool schemas are injected into EVERY request, so the full surface is a
    fixed per-turn tax. Measured on the work M4 2026-08-05: a bare
    list_windows call -- four lines of output -- rode on a 29,140-token
    prompt. That floor is paid whether or not a tool is used.

    Filtering is opt-in (CUA_SHIM_TOOLS) because dropping a tool the agent
    needs breaks it silently. The per-tool cost report is always printed so
    the allowlist can be chosen from measurements rather than guesses.
    """
    result = msg.get("result")
    if not isinstance(result, dict):
        return msg
    tools = result.get("tools")
    if not isinstance(tools, list):
        return msg

    # ~4 chars/token is close enough to rank tools by cost.
    def cost(t):
        return len(json.dumps(t)) // 4

    total = sum(cost(t) for t in tools)
    log(f"tools/list: {len(tools)} tools, ~{total} tokens of schema per request")
    for t in sorted(tools, key=cost, reverse=True)[:10]:
        log(f"    ~{cost(t):5d} tok  {t.get('name','?')}")
    if len(tools) > 10:
        log(f"    ... {len(tools)-10} more; set CUA_SHIM_TOOLS to filter")

    keep = os.environ.get("CUA_SHIM_TOOLS")
    if not keep:
        return msg

    wanted = {n.strip() for n in keep.split(",") if n.strip()}
    kept = [t for t in tools if t.get("name") in wanted]
    missing = wanted - {t.get("name") for t in tools}
    if missing:
        # Loud: a typo here silently removes a capability.
        log(f"WARNING: requested tools not advertised: {sorted(missing)}")
    if not kept:
        log("WARNING: filter matched nothing — passing the full list through")
        return msg

    result["tools"] = kept
    log(f"filtered to {len(kept)} tools, ~{sum(cost(t) for t in kept)} tokens "
        f"(saved ~{total - sum(cost(t) for t in kept)})")
    return msg


def pump_out(child):
    """Driver -> client. Verbatim except for tools/list, which is measured and
    optionally trimmed."""
    for line in child.stdout:
        try:
            msg = json.loads(line)
        except (ValueError, TypeError):
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
            continue
        if isinstance(msg, dict) and isinstance(msg.get("result"), dict) \
                and "tools" in msg["result"]:
            msg = filter_tools(msg)
            line = (json.dumps(msg, separators=(",", ":")) + "\n").encode("utf-8")
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()


def pump_err(child):
    """Driver stderr -> our log.

    Without this the driver's own error output goes to the shim's inherited
    stderr, which the MCP host routes wherever it likes -- usually nowhere
    visible. A driver crash then presents as "the MCP server died" with no
    reason attached, and the shim gets blamed for it because the shim is the
    process the host spawned.
    """
    for line in child.stderr:
        text = line.decode("utf-8", "replace").rstrip()
        if text:
            log(f"driver: {text}")


def main():
    argv = [DRIVER, "mcp"] + sys.argv[1:]
    try:
        child = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError:
        print(f"[cua-shim] cannot exec {DRIVER}", file=sys.stderr)
        return 127

    log(
        f"proxying {' '.join(argv)} "
        f"(max_elements<={MAX_ELEMENTS}, max_depth<={MAX_DEPTH}, "
        f"screenshots={'allowed' if ALLOW_SHOT else 'forced off'})"
    )

    threading.Thread(target=pump_out, args=(child,), daemon=True).start()
    threading.Thread(target=pump_err, args=(child,), daemon=True).start()

    # The call the driver was last handling -- set only AFTER a successful
    # write. Tracking the last request *read* instead would blame whichever
    # request happened to arrive next, which is the one thing a crash report
    # must not do.
    last_sent = None
    try:
        for raw in sys.stdin.buffer:
            text = raw.decode("utf-8", "replace")
            name = None
            try:
                m = json.loads(text)
                if isinstance(m, dict) and m.get("method") == "tools/call":
                    name = (m.get("params") or {}).get("name")
            except (ValueError, TypeError):
                pass

            if child.poll() is not None:
                log(f"driver already dead (code {child.returncode}) when "
                    f"'{name}' arrived; it died handling '{last_sent}'")
                break

            out = rewrite(text)
            try:
                child.stdin.write(out.encode("utf-8") if isinstance(out, str) else out)
                child.stdin.flush()
            except (BrokenPipeError, OSError):
                log(f"driver closed its input while '{last_sent}' was in "
                    f"flight; could not deliver '{name}'")
                break
            if name:
                last_sent = name
    finally:
        try:
            child.stdin.close()
        except Exception:
            pass

    rc = child.wait()
    # Give the stderr pump a moment to flush the driver's parting words.
    time.sleep(0.2)
    if rc != 0:
        log(f"driver exited with code {rc} (driver was handling: {last_sent}). "
            f"The shim forwards non-window tools verbatim, so a crash here is "
            f"the driver's, not the clamp's -- reproduce it without the shim: "
            f"cua-driver call {last_sent or '<tool>'} ...")
    else:
        log(f"driver exited cleanly (driver was handling: {last_sent})")
    return rc


if __name__ == "__main__":
    sys.exit(main())
