#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10", "numpy>=1.26"]
# ///
"""Side-by-side demo video: the clip with the engine's landmark overlay on the left, a
dashboard of the engine's readings on the right (class probabilities, intensity, the
valence/arousal pad with its trail, the strongest Action Units).

    tools/render_demo.py readings.json clip.mp4 out.mp4 [--caption "AI-generated actor"]
    tools/render_demo.py a.json a.mp4 b.json b.mp4 ... --out montage.mp4 [--from 2]   # clips in sequence

readings.json comes from `affect-replay run`. Every frame drawn is a frame the engine
analyzed (at its 15 Hz cadence), so the output runs at the readings' rate. Needs ffmpeg.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ORDER = ["neutral", "happiness", "sadness", "surprise", "fear", "anger", "disgust", "contempt"]
NAMES = {"neutral": "Neutral", "happiness": "Happy", "sadness": "Sad", "surprise": "Surprised",
         "fear": "Afraid", "anger": "Angry", "disgust": "Disgusted", "contempt": "Contempt"}
# The app's Emotion.color values, as the system colors render in dark mode.
COLORS = {"neutral": (191, 191, 191), "happiness": (255, 214, 10), "sadness": (10, 132, 255),
          "surprise": (255, 159, 10), "fear": (191, 90, 242), "anger": (255, 69, 58),
          "disgust": (48, 209, 88), "contempt": (64, 200, 224)}
AU_NAMES = {"au1": "AU1 inner brow raise", "au2": "AU2 outer brow raise", "au4": "AU4 brow lower",
            "au5": "AU5 upper lid raise", "au6": "AU6 cheek raise", "au7": "AU7 lid tighten",
            "au9": "AU9 nose wrinkle", "au12": "AU12 lip corner pull", "au15": "AU15 lip corner depress",
            "au20": "AU20 lip stretch", "au23": "AU23 lip tighten", "au25": "AU25 lips part",
            "au26": "AU26 jaw drop", "auUnilateral": "AU12/14 one-sided"}

BG = (18, 18, 22)
PANEL = (32, 32, 38)
TEXT = (235, 235, 240)
MUTED = (150, 150, 160)
H = 512           # output height; the clip is scaled to it
DASH_W = 520      # dashboard width


def font(size, bold=False):
    for path in (["/System/Library/Fonts/SFNS.ttf"] if not bold else []) + [
            "/System/Library/Fonts/HelveticaNeue.ttc", "/System/Library/Fonts/Helvetica.ttc"]:
        try:
            return ImageFont.truetype(path, size, index=1 if bold and path.endswith(".ttc") else 0)
        except OSError:
            continue
    return ImageFont.load_default()


F_SMALL, F_BODY, F_BIG = font(13), font(16), font(30, bold=True)


def video_frames(path, times, height):
    """Decode the frames nearest to `times` (seconds), scaled to `height`."""
    probe = json.loads(subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,r_frame_rate", "-of", "json", str(path)],
        capture_output=True, text=True, check=True).stdout)["streams"][0]
    w0, h0 = probe["width"], probe["height"]
    num, den = map(int, probe["r_frame_rate"].split("/"))
    fps = num / den
    w = int(round(w0 * height / h0 / 2) * 2)
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-vf", f"scale={w}:{height}",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True, check=True).stdout
    frames = np.frombuffer(raw, np.uint8).reshape(-1, height, w, 3)
    return [frames[min(len(frames) - 1, int(round(t * fps)))] for t in times], w


def draw_overlay(img, row):
    o = row.get("overlay")
    if not o:
        return
    d = ImageDraw.Draw(img, "RGBA")
    W, Hh = img.size
    x, y, w, h = o["faceRect"]
    d.rounded_rectangle([x * W, y * Hh, (x + w) * W, (y + h) * Hh], radius=10,
                        outline=(255, 255, 255, 140), width=2)
    col = COLORS[row["dominant"]]
    for px, py in o["points"]:
        cx, cy = px * W, py * Hh
        d.ellipse([cx - 2, cy - 2, cx + 2, cy + 2], fill=col + (230,))


def draw_dashboard(row, trail, prompt, caption):
    img = Image.new("RGB", (DASH_W, H), BG)
    d = ImageDraw.Draw(img)
    pad = 18
    # Header: the engine's stable dominant emotion, its confidence and graded intensity.
    dom = row["dominant"] if row["faceDetected"] else None
    title = NAMES[dom] if dom else "No face"
    d.text((pad, 14), title, font=F_BIG, fill=COLORS.get(dom, MUTED))
    sub = (f"confidence {row['confidence']:.0%}   intensity {row['intensity']:.0%}"
           if dom else "waiting for a face")
    d.text((pad, 52), sub, font=F_BODY, fill=MUTED)
    if prompt:
        d.text((DASH_W - pad, 20), f"prompted: {NAMES.get(prompt, prompt)}", font=F_BODY,
               fill=TEXT, anchor="ra")
    d.text((DASH_W - pad, 42), f"t = {row['t']:.1f} s", font=F_SMALL, fill=MUTED, anchor="ra")

    # Class probability bars (the fused, smoothed distribution).
    top, bar_h, gap = 86, 17, 7
    label_w, bar_x0, bar_x1 = 84, pad + 84, 300
    for i, e in enumerate(ORDER):
        y = top + i * (bar_h + gap)
        p = row["distribution"][e]
        d.text((pad, y + bar_h / 2), NAMES[e], font=F_SMALL, fill=TEXT if e == dom else MUTED, anchor="lm")
        d.rounded_rectangle([bar_x0, y, bar_x1, y + bar_h], radius=4, fill=PANEL)
        if p > 0.005:
            d.rounded_rectangle([bar_x0, y, bar_x0 + max(8, (bar_x1 - bar_x0) * p), y + bar_h],
                                radius=4, fill=COLORS[e])
        d.text((bar_x1 + 6, y + bar_h / 2), f"{p:.0%}", font=F_SMALL, fill=MUTED, anchor="lm")

    # Valence / arousal pad with a fading trail.
    px0, py0, side = 352, 86, 150
    d.rounded_rectangle([px0, py0, px0 + side, py0 + side], radius=8, fill=PANEL)
    cx, cy = px0 + side / 2, py0 + side / 2
    d.line([px0 + 6, cy, px0 + side - 6, cy], fill=(70, 70, 80))
    d.line([cx, py0 + 6, cx, py0 + side - 6], fill=(70, 70, 80))
    d.text((cx, py0 + side + 4), "valence →", font=F_SMALL, fill=MUTED, anchor="ma")
    d.text((px0 + 8, py0 + 6), "arousal ↑", font=F_SMALL, fill=MUTED)

    def pad_xy(v, a):
        return cx + v * (side / 2 - 8), cy - a * (side / 2 - 8)
    for k, (v, a) in enumerate(trail):
        x, y = pad_xy(v, a)
        r = 1.5 + 2.5 * (k + 1) / len(trail)
        shade = int(60 + 140 * (k + 1) / len(trail))
        d.ellipse([x - r, y - r, x + r, y + r], fill=(shade, shade, shade))
    if dom:
        x, y = pad_xy(row["valence"], row["arousal"])
        d.ellipse([x - 6, y - 6, x + 6, y + 6], fill=COLORS[dom], outline=(255, 255, 255))

    # Intensity meter (how hard the face is emoting; separate from confidence).
    my = top + 8 * (bar_h + gap) + 14
    d.text((pad, my), "intensity", font=F_SMALL, fill=MUTED)
    d.rounded_rectangle([bar_x0, my, DASH_W - pad, my + 12], radius=6, fill=PANEL)
    if dom and row["intensity"] > 0.005:
        d.rounded_rectangle([bar_x0, my, bar_x0 + max(10, (DASH_W - pad - bar_x0) * row["intensity"]), my + 12],
                            radius=6, fill=COLORS[dom])

    # Strongest Action Units this frame (deltas from the calibrated neutral face).
    ay = my + 28
    d.text((pad, ay), "strongest FACS action units", font=F_SMALL, fill=MUTED)
    aus = sorted(row.get("aus", {}).items(), key=lambda kv: -kv[1])[:4]
    for j, (au, v) in enumerate(aus):
        y = ay + 20 + j * 19
        d.text((pad, y), AU_NAMES.get(au, au), font=F_SMALL, fill=TEXT)
        x1 = DASH_W - pad - 40
        d.rounded_rectangle([230, y + 2, x1, y + 12], radius=5, fill=PANEL)
        if v > 0.005:
            d.rounded_rectangle([230, y + 2, 230 + (x1 - 230) * min(1, v), y + 12], radius=5,
                                fill=(200, 200, 210))
        d.text((DASH_W - pad, y + 7), f"{v:.2f}", font=F_SMALL, fill=MUTED, anchor="rm")

    if caption:
        d.text((pad, H - 14), caption, font=F_SMALL, fill=MUTED, anchor="ls")
    return img


def render(pairs, out, caption, fps, t_from=0.0):
    enc = None
    for readings_path, clip in pairs:
        data = json.loads(Path(readings_path).read_text())
        rows = [r for r in data["frames"] if r["t"] >= t_from]
        prompt = data.get("label")
        frames, w = video_frames(clip, [r["t"] for r in rows], H)
        if enc is None:
            size = (w + DASH_W, H)
            enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                                    "-s", f"{size[0]}x{size[1]}", "-r", str(fps), "-i", "-",
                                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20",
                                    "-map_metadata", "-1", str(out)], stdin=subprocess.PIPE)
        trail = []
        for row, frame in zip(rows, frames):
            left = Image.fromarray(frame.copy())
            draw_overlay(left, row)
            if row["faceDetected"]:
                trail = (trail + [(row["valence"], row["arousal"])])[-24:]
            canvas = Image.new("RGB", (w + DASH_W, H), BG)
            canvas.paste(left, (0, 0))
            canvas.paste(draw_dashboard(row, trail, prompt, caption), (w, 0))
            enc.stdin.write(canvas.tobytes())
    enc.stdin.close()
    enc.wait()
    print(f"wrote {out}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("items", nargs="+", help="readings.json clip.mp4 [readings.json clip.mp4 ...] [out.mp4]")
    ap.add_argument("--out")
    ap.add_argument("--caption", default="AI-generated actor (LTX-2.5) · readings from the real engine")
    ap.add_argument("--fps", type=float, default=15)
    ap.add_argument("--from", dest="t_from", type=float, default=0.0,
                    help="skip each clip's frames before this many seconds (for montages)")
    a = ap.parse_args()
    items = list(a.items)
    out = a.out or items.pop()
    if len(items) % 2:
        ap.error("give readings.json / clip.mp4 pairs")
    render(list(zip(items[::2], items[1::2])), out, a.caption, a.fps, a.t_from)


if __name__ == "__main__":
    main()
