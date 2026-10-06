#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["matplotlib>=3.8", "numpy>=1.26"]
# ///
"""README charts from the engine's own output files.

    tools/charts.py synthetic synthetic.json docs/media/          # from `affect-replay synth`
    tools/charts.py confusion results.json docs/media/            # from tools/score_clips.py

Every chart says in its caption which file and command it came from.
"""

import json
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ORDER = ["neutral", "happiness", "sadness", "surprise", "fear", "anger", "disgust", "contempt"]
NAMES = {"neutral": "Neutral", "happiness": "Happy", "sadness": "Sad", "surprise": "Surprised",
         "fear": "Afraid", "anger": "Angry", "disgust": "Disgusted", "contempt": "Contempt"}

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
GRID = "#e4e3df"
BLUE = "#2a78d6"     # reference palette slot 1
ORANGE = "#eb6834"   # reference palette slot 2

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "text.color": INK, "font.size": 10, "axes.spines.top": False, "axes.spines.right": False,
    "axes.titleweight": "bold", "axes.titlesize": 11,
})


def heatmap(ax, m, rows, cols, fmt="{:.0%}", cmap="Blues"):
    ax.imshow(m, cmap=cmap, vmin=0, vmax=max(1e-9, m.max()), aspect="auto")
    ax.set_xticks(range(len(cols)), [NAMES[c] for c in cols], rotation=35, ha="right")
    ax.set_yticks(range(len(rows)), [NAMES[r] for r in rows])
    for i in range(len(rows)):
        for j in range(len(cols)):
            v = m[i, j]
            if v >= 0.005:
                ax.text(j, i, fmt.format(v), ha="center", va="center", fontsize=8.5,
                        color="white" if v > 0.55 * m.max() else INK)
    for s in ax.spines.values():
        s.set_visible(False)
    ax.tick_params(length=0)


def caption(fig, text):
    fig.text(0.01, 0.01, text, fontsize=8, color=INK2, ha="left", va="bottom")


def synthetic(src, out):
    d = json.loads(Path(src).read_text())

    # 1. EMFACS prototypes through the classifier.
    m = np.array([[p["distribution"][c] for c in ORDER] for p in d["prototypes"]])
    rows = [p["prototype"] for p in d["prototypes"]]
    fig, ax = plt.subplots(figsize=(7.2, 4.6))
    heatmap(ax, m, rows, ORDER)
    ax.set_ylabel("synthetic Action Unit prototype")
    ax.set_xlabel("classifier probability")
    ax.set_title("Each EMFACS prototype lands on its own class", loc="left")
    caption(fig, f"Source: {Path(src).name} (affect-replay synth): synthetic AU vectors through EmotionClassifier, no face involved.")
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    fig.savefig(out / "prototype-matrix.png", dpi=160)
    plt.close(fig)

    # 2. Hysteresis: raw per-frame label vs the smoother's stable label.
    tr = d["hysteresis"]
    t = np.array([r["t"] for r in tr])
    idx = {e: i for i, e in enumerate(ORDER)}
    raw = np.array([idx[r["rawDominant"]] for r in tr])
    stable = np.array([idx[r["stableDominant"]] for r in tr])
    truth = np.array([idx[r["truth"]] for r in tr])
    flips_raw = int((np.diff(raw) != 0).sum())
    flips_stable = int((np.diff(stable) != 0).sum())
    fig, ax = plt.subplots(figsize=(7.2, 3.4))
    ax.step(t, truth, where="post", color=GRID, lw=6, label="simulated expression", zorder=1)
    ax.scatter(t, raw, s=14, color=INK2, label=f"per-frame label ({flips_raw} changes)", zorder=2)
    ax.step(t, stable, where="post", color=BLUE, lw=2, label=f"stable label after EMA + hysteresis ({flips_stable} changes)", zorder=3)
    used = sorted(set(raw) | set(stable) | set(truth))
    ax.set_yticks(used, [NAMES[ORDER[i]] for i in used])
    ax.set_xlabel("seconds (15 Hz)")
    ax.grid(axis="x", color=GRID, lw=0.6)
    ax.legend(loc="upper left", frameon=False, fontsize=8.5)
    ax.set_title("Temporal smoothing turns a flickering per-frame label into a stable one", loc="left")
    caption(fig, f"Source: {Path(src).name}: a noisy neutral → happy → surprised sequence (1 frame in 4 flips class) through TemporalSmoother.")
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    fig.savefig(out / "hysteresis.png", dpi=160)
    plt.close(fig)

    # 3. Intensity vs confidence: scale each prototype from rest to full.
    sw = d["intensitySweep"]
    emos = [e for e in ORDER if e != "neutral"]
    fig, axes = plt.subplots(1, len(emos), figsize=(11, 2.6), sharey=True)
    for ax, e in zip(axes, emos):
        pts = [r for r in sw if r["emotion"] == e]
        k = [r["scale"] for r in pts]
        ax.plot(k, [r["probability"] for r in pts], color=BLUE, lw=2, label="class probability (confidence)")
        ax.plot(k, [min(1, r["evidence"]) for r in pts], color=ORANGE, lw=2, label="raw evidence (intensity)")
        ax.set_title(NAMES[e], loc="left", fontsize=10)
        ax.set_xticks([0, 0.5, 1])
        ax.set_ylim(0, 1.02)
        ax.grid(color=GRID, lw=0.6)
    axes[0].set_ylabel("0 … 1")
    fig.supxlabel("prototype strength (0 = neutral face, 1 = full prototype)", fontsize=9, color=INK2, y=0.1)
    h, l = axes[0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper right", ncol=2, frameon=False, fontsize=8.5)
    fig.suptitle("Intensity grades the evidence; confidence is a softmax that lags on faint expressions", x=0.01, ha="left", fontweight="bold", fontsize=11)
    caption(fig, f"Source: {Path(src).name}: each prototype scaled from rest to full strength; intensity rises from the first movement, confidence only once the class wins.")
    fig.tight_layout(rect=(0, 0.06, 1, 0.92))
    fig.savefig(out / "intensity-vs-confidence.png", dpi=160)
    plt.close(fig)


def confusion(src, out):
    d = json.loads(Path(src).read_text())
    for key, title in (("fused", "geometry + FER+"), ("geometry", "geometry only")):
        if key not in d:
            continue
        m = np.array(d[key]["matrix"], dtype=float)   # rows prompted, cols detected (frame shares)
        acc = d[key]["clipAccuracy"]
        n = d[key]["clips"]
        fig, ax = plt.subplots(figsize=(7.2, 5.0))
        heatmap(ax, m, ORDER, ORDER)
        ax.set_ylabel("prompted emotion (AI actor)")
        ax.set_xlabel("engine's stable label (share of scored frames)")
        ax.set_title(f"Prompted vs detected, {title}: {acc[0]} of {n} clips correct", loc="left")
        caption(fig, f"Source: {Path(src).name} (tools/score_clips.py over affect-replay readings, {d['date']}); "
                     f"frames from {d['window']} of each clip. AI-generated footage (LTX-2.5).")
        fig.tight_layout(rect=(0, 0.04, 1, 1))
        fig.savefig(out / f"confusion-{key}.png", dpi=160)
        plt.close(fig)


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("synthetic", "confusion"):
        sys.exit(__doc__)
    out = Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    {"synthetic": synthetic, "confusion": confusion}[sys.argv[1]](sys.argv[2], out)
