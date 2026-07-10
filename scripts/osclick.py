#!/usr/bin/env python3
"""Layer-2 actuation: DOM bounding box -> real OS cursor click via cliclick.

Perception stays in the DOM (Playwright reads the element's bbox and window
metrics); only the input event is OS-level, so sites that reject synthetic
events see a genuine click. macOS screen coordinates are points, which match
CSS pixels at default page zoom — keep page zoom at 100%.

Usage:
  python3 osclick.py '{"bbox": {"x":100,"y":200,"width":50,"height":20},
                       "win": {"screenX":10,"screenY":40,
                                "outerHeight":900,"innerHeight":800},
                       "action": "c"}'

Get `win` in the page via:
  ({screenX: window.screenX, screenY: window.screenY,
    outerHeight: window.outerHeight, innerHeight: window.innerHeight})

Coordinates assume the browser window is on the main display; negative
screenX/screenY from a secondary display will misroute cliclick.
"""
import json
import subprocess
import sys


def dom_to_screen(bbox, win):
    """Return integer screen coords of the bbox center.

    The browser chrome (tab strip, toolbars) sits between the window origin
    and the viewport; its height is outerHeight - innerHeight.
    """
    chrome_height = win["outerHeight"] - win["innerHeight"]
    x = win["screenX"] + bbox["x"] + bbox["width"] / 2
    y = win["screenY"] + chrome_height + bbox["y"] + bbox["height"] / 2
    return round(x), round(y)


def actuate(x, y, action="c"):
    subprocess.run(["cliclick", f"{action}:{x},{y}"], check=True)


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    data = json.loads(sys.argv[1])
    x, y = dom_to_screen(data["bbox"], data["win"])
    actuate(x, y, data.get("action", "c"))
    print(json.dumps({"action": data.get("action", "c"), "screen": [x, y]}))


if __name__ == "__main__":
    main()
