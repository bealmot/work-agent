#!/usr/bin/env bash
# Describe an image with the local vision model. Prints text to stdout.
#
#   scripts/describe-image.sh <file-or-url> ["what to ask about it"]
#
# THE POINT: the image bytes go from disk to the VLM directly. They never pass
# through the agent's context. A 500 KB screenshot is ~700 KB of base64 -- put
# that in a transcript and the session is over, and on this model it cannot be
# pruned back out (context is append-only; see config/llama-server.md).
#
# So the agent's flow is:
#   1. get content_url from the Zendesk API
#   2. get the file onto disk  (see skills/zendesk-api, "Attachments")
#   3. run this script with the path
#   4. append ONLY the returned description
set -euo pipefail

SRC="${1:-}"
PROMPT="${2:-Describe this image. If it shows an error message, dialog, log or terminal output, transcribe the text exactly. Be concise and factual; do not speculate about causes.}"
VLM_PORT="${WORK_AGENT_VLM_PORT:-8081}"
API="http://localhost:$VLM_PORT"
MAX_CHARS="${WORK_AGENT_VLM_MAX_CHARS:-2000}"

[ -n "$SRC" ] || { echo "usage: $0 <file-or-url> [prompt]" >&2; exit 2; }

# Fail fast and legibly if the vision server is not up. Without this the curl
# below returns empty and the caller cannot tell "no server" from "no answer" --
# a distinction this project has paid for repeatedly.
if ! curl -s -o /dev/null "$API/health" 2>/dev/null; then
  echo "ERROR: no vision server on $API — start scripts/serve-vlm.sh" >&2
  exit 1
fi

TMP=""
cleanup() { [ -n "$TMP" ] && rm -f "$TMP"; }
trap cleanup EXIT

case "$SRC" in
  http://*|https://*)
    # Zendesk attachment content_url MAY be directly fetchable, or may need the
    # session. If this returns HTML or 401, fetch it inside the authenticated
    # browser instead and pass a path -- do NOT start attaching cookies to an
    # external client: headless/bot-shaped requests trip Cloudflare on this
    # tenant (skills/browser-ops).
    TMP="$(mktemp -t cua-img).bin"
    if ! curl -sfL --max-time 30 "$SRC" -o "$TMP"; then
      echo "ERROR: could not fetch $SRC directly." >&2
      echo "       Download it in the authenticated browser and pass the path." >&2
      exit 1
    fi
    FILE="$TMP"
    ;;
  *)
    FILE="$SRC"
    [ -f "$FILE" ] || { echo "ERROR: no such file: $FILE" >&2; exit 1; }
    ;;
esac

python3 - "$FILE" "$PROMPT" "$API" "$MAX_CHARS" <<'PY'
import base64, json, mimetypes, sys, urllib.request, urllib.error

path, prompt, api, max_chars = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

mime = mimetypes.guess_type(path)[0] or ""
if not mime.startswith("image/"):
    # Sniff: content_url downloads often arrive without a usable extension.
    with open(path, "rb") as fh:
        head = fh.read(12)
    if head[:8] == b"\x89PNG\r\n\x1a\n":      mime = "image/png"
    elif head[:2] == b"\xff\xd8":              mime = "image/jpeg"
    elif head[:6] in (b"GIF87a", b"GIF89a"):   mime = "image/gif"
    elif head[:4] == b"RIFF" and head[8:12] == b"WEBP": mime = "image/webp"
    else:
        print(f"ERROR: {path} does not look like an image "
              f"(first bytes: {head[:8]!r}). If this is a PDF or text "
              f"attachment, read it as text instead.", file=sys.stderr)
        sys.exit(1)

with open(path, "rb") as fh:
    b64 = base64.b64encode(fh.read()).decode()

body = json.dumps({
    "model": "vlm",
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": prompt},
        {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
    ]}],
    "max_tokens": 700,
    "temperature": 0.2,
}).encode()

req = urllib.request.Request(f"{api}/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        data = json.load(r)
except urllib.error.HTTPError as e:
    print(f"ERROR: vision server returned {e.code}: "
          f"{e.read()[:300].decode('utf-8','replace')}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"ERROR: vision server call failed: {e}", file=sys.stderr)
    sys.exit(1)

try:
    text = data["choices"][0]["message"]["content"].strip()
except (KeyError, IndexError):
    print(f"ERROR: unexpected response shape: {json.dumps(data)[:300]}",
          file=sys.stderr)
    sys.exit(1)

if not text:
    # Empty is a channel failure until proven otherwise. Most likely cause:
    # this server has no projector loaded, so the image was silently dropped.
    print("ERROR: vision server returned an empty description. Check that "
          "serve-vlm.sh loaded an mmproj — without one it cannot see the "
          "image and will not say so.", file=sys.stderr)
    sys.exit(1)

# Bound what reaches the caller. This output is destined for an append-only
# context, so an oversized description is permanent for the session.
if len(text) > max_chars:
    text = text[:max_chars] + f"\n[truncated at {max_chars} chars]"
print(text)
PY
