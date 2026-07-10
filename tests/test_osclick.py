import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from osclick import dom_to_screen


def test_center_of_bbox_offset_by_window_and_chrome():
    # Window at (10, 40); browser chrome (toolbars) = outer 900 - inner 800 = 100px.
    bbox = {"x": 100, "y": 200, "width": 50, "height": 20}
    win = {"screenX": 10, "screenY": 40, "outerHeight": 900, "innerHeight": 800}
    # x: 10 + 100 + 25 = 135 ; y: 40 + 100 + 200 + 10 = 350
    assert dom_to_screen(bbox, win) == (135, 350)


def test_rounds_to_integer_pixels():
    bbox = {"x": 0.4, "y": 0.4, "width": 1, "height": 1}
    win = {"screenX": 0, "screenY": 0, "outerHeight": 100, "innerHeight": 100}
    assert dom_to_screen(bbox, win) == (1, 1)  # 0.4 + 0.5 = 0.9 -> 1
