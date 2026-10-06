#!/usr/bin/env python3
"""Score `affect-replay run` readings against the emotion each clip was prompted with.

    tools/score_clips.py --fused DIR --geometry DIR [--from 2.5] -o results.json

Each DIR holds one <emotion>.json per clip (from `affect-replay run --label <emotion>`).
The prompt is the ground truth: the clips open on a neutral face and change expression
in their first seconds, so only frames from --from seconds on are scored. A clip's
prediction is the engine's most frequent stable label over those frames; the matrix rows
hold the share of scored frames per detected label. Stdlib only.
"""

import argparse
import collections
import datetime
import json
from pathlib import Path

ORDER = ["neutral", "happiness", "sadness", "surprise", "fear", "anger", "disgust", "contempt"]


def score(folder, t_from):
    per_clip, matrix, correct = {}, [], 0
    for label in ORDER:
        path = Path(folder) / f"{label}.json"
        if not path.exists():
            matrix.append([0.0] * len(ORDER))
            continue
        data = json.loads(path.read_text())
        frames = [f for f in data["frames"] if f["t"] >= t_from and f["faceDetected"]]
        counts = collections.Counter(f["dominant"] for f in frames)
        n = max(1, len(frames))
        matrix.append([round(counts[e] / n, 4) for e in ORDER])
        predicted = counts.most_common(1)[0][0] if counts else "no face"
        correct += predicted == label
        mean_p = sum(f["distribution"][label] for f in frames) / n
        per_clip[label] = {"predicted": predicted, "scoredFrames": len(frames),
                           "frameShareCorrect": round(counts[label] / n, 4),
                           "meanProbabilityOfPrompted": round(mean_p, 4),
                           "meanIntensity": round(sum(f["intensity"] for f in frames) / n, 4),
                           "faceFrames": sum(f["faceDetected"] for f in data["frames"]),
                           "frames": len(data["frames"]),
                           "calibration": data.get("calibration")}
    clips = len(per_clip)
    return {"matrix": matrix, "clipAccuracy": [correct, clips], "clips": clips, "perClip": per_clip,
            "frameAccuracy": round(sum(matrix[i][i] for i in range(len(ORDER))) / max(1, clips), 4)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--fused", help="readings with the FER+ expert")
    ap.add_argument("--geometry", help="readings from the geometry-only engine")
    ap.add_argument("--from", dest="t_from", type=float, default=2.5)
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    out = {"labels": ORDER, "window": f"t >= {a.t_from} s", "date": datetime.date.today().isoformat(),
           "groundTruth": "the emotion named in each clip's prompt"}
    if a.fused:
        out["fused"] = score(a.fused, a.t_from)
    if a.geometry:
        out["geometry"] = score(a.geometry, a.t_from)
    Path(a.out).write_text(json.dumps(out, indent=2) + "\n")
    for key in ("fused", "geometry"):
        if key in out:
            r = out[key]
            print(f"{key}: {r['clipAccuracy'][0]}/{r['clips']} clips, mean frame accuracy {r['frameAccuracy']:.0%}")
            for label, c in r["perClip"].items():
                print(f"  {label:10s} -> {c['predicted']:10s} ({c['frameShareCorrect']:.0%} of frames, p={c['meanProbabilityOfPrompted']:.2f})")


if __name__ == "__main__":
    main()
