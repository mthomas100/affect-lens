//
//  main.swift
//  affect-replay
//
//  Runs the app's real emotion engine (the same Swift files the visionOS app
//  compiles) on macOS, with no camera:
//
//    affect-replay run <video> [options]   video frames → per-frame readings JSON
//    affect-replay synth [--out file]      the classifier and smoother on synthetic AU input
//    affect-replay selftest                the app's DEBUG self-test suite (debug builds)
//
//  `run` decodes the video with AVFoundation, samples it at the app's analysis cadence
//  (15 Hz by default), and feeds each frame to `EmotionEngine.ingestOffline`, which is
//  the live `ingest` path minus the wall-clock throttle. Vision and Core ML are pinned
//  to the CPU unless --any-device is given.
//

import AVFoundation
import CoreML
import Foundation

let usage = """
usage:
  affect-replay run <video> [--out readings.json] [--fps 15] [--model FERPlus.mlpackage]
                    [--calib-seconds 1.0 | --calib-clip neutral.mp4 | --calib-auto | --calib-default]
                    [--label happiness] [--any-device]
  affect-replay synth [--out synthetic.json]
  affect-replay selftest

run options:
  --fps N            analysis rate in frames per second (the app runs at ~15)
  --model PATH       FER+ appearance expert (.mlpackage/.mlmodel/.mlmodelc); without it the
                     engine runs geometry-only, its documented fallback
  --calib-seconds S  build the neutral baseline from the first S seconds of the clip (default 1.0)
  --calib-clip PATH  build the neutral baseline from a separate neutral clip instead
  --calib-auto       let the engine auto-calibrate exactly as the app does (first 36 good frames)
  --calib-default    skip calibration and measure against the engine's built-in average neutral face
  --label EMOTION    the prompted emotion, copied into the output for scoring
  --any-device       allow Vision/Core ML on the GPU and Neural Engine (default: CPU only)
"""

// MARK: - Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

// MARK: - Video decoding

/// Decodes a video into BGRA pixel buffers sampled at `fps`, with presentation times.
func sampledFrames(of url: URL, fps: Double) async throws -> [(t: Double, buffer: CVPixelBuffer)] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw NSError(domain: "affect-replay", code: 1, userInfo: [NSLocalizedDescriptionKey: "no video track in \(url.path)"])
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "affect-replay", code: 2) }

    var frames: [(Double, CVPixelBuffer)] = []
    var nextSample = 0.0
    while let sample = output.copyNextSampleBuffer() {
        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard t + 1e-6 >= nextSample, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        frames.append((t, buffer))
        nextSample += 1.0 / fps
        while nextSample <= t { nextSample += 1.0 / fps }
    }
    return frames
}

// MARK: - Calibration

/// The engine measures every expression against the wearer's own neutral face. The app
/// collects that baseline live; offline we take the median metrics over a stretch of
/// neutral frames and store it where `EmotionEngine` loads it at init.
func calibrate(from frames: [(t: Double, buffer: CVPixelBuffer)], analyzer: FaceAnalyzer) async -> Int {
    var samples: [FacialMetrics] = []
    for frame in frames {
        if let e = await analyzer.analyze(frame.buffer).extraction, e.landmarkConfidence >= 0.4 {
            samples.append(e.metrics)
        }
    }
    if let median = FacialMetrics.median(of: samples) {
        NeutralBaseline(metrics: median, isCalibrated: true).save()
    }
    return samples.count
}

let baselineKey = "EmotionEngine.NeutralBaseline.v1"

// MARK: - JSON helpers

func probs(_ d: EmotionDistribution?) -> [String: Double]? {
    guard let d else { return nil }
    return Dictionary(uniqueKeysWithValues: Emotion.allCases.map { ($0.rawValue, round4(d[$0])) })
}
func round4(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }

func writeJSON(_ object: Any, to path: String?) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    if let path {
        try data.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write("wrote \(path)\n".data(using: .utf8)!)
    } else {
        FileHandle.standardOutput.write(data)
    }
}

// MARK: - Commands

func runVideo() async throws {
    guard let path = args.first, !path.hasPrefix("--") else { print(usage); exit(2) }
    let url = URL(fileURLWithPath: path)
    let fps = Double(option("--fps") ?? "15") ?? 15
    let cpuOnly = !flag("--any-device")
    let analyzer = FaceAnalyzer(cpuOnly: cpuOnly)

    var scorer: CoreMLEmotionScorer?
    if let modelPath = option("--model") {
        scorer = CoreMLEmotionScorer(modelURL: URL(fileURLWithPath: modelPath),
                                     computeUnits: cpuOnly ? .cpuOnly : .all)
        if scorer == nil { FileHandle.standardError.write("could not load model at \(modelPath)\n".data(using: .utf8)!); exit(1) }
    }

    let frames = try await sampledFrames(of: url, fps: fps)
    UserDefaults.standard.removeObject(forKey: baselineKey)
    defer { UserDefaults.standard.removeObject(forKey: baselineKey) }

    var calibration: [String: Any] = [:]
    if let clip = option("--calib-clip") {
        let neutral = try await sampledFrames(of: URL(fileURLWithPath: clip), fps: fps)
        let n = await calibrate(from: neutral, analyzer: analyzer)
        calibration = ["mode": "clip", "clip": URL(fileURLWithPath: clip).lastPathComponent, "frames": n]
    } else if flag("--calib-default") {
        NeutralBaseline(metrics: .defaultNeutral, isCalibrated: true).save()
        calibration = ["mode": "default"]
    } else if !flag("--calib-auto") {
        let seconds = Double(option("--calib-seconds") ?? "1.0") ?? 1.0
        let n = await calibrate(from: frames.filter { $0.t < seconds }, analyzer: analyzer)
        calibration = ["mode": "first-seconds", "seconds": seconds, "frames": n]
    } else {
        calibration = ["mode": "auto"]
    }

    let engine = EmotionEngine(analyzer: analyzer, appearanceScorer: scorer)
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var rows: [[String: Any]] = []
    for frame in frames {
        let analysis = await engine.ingestOffline(frame.buffer, at: start.addingTimeInterval(frame.t))
        let r = engine.reading
        var row: [String: Any] = [
            "t": round4(frame.t),
            "faceDetected": r.faceDetected,
            "dominant": r.dominant.rawValue,
            "confidence": round4(r.confidence),
            "intensity": round4(r.intensity),
            "valence": round4(r.valence),
            "arousal": round4(r.arousal),
            "quality": round4(r.quality),
            "distribution": probs(r.distribution)!,
            "aus": Dictionary(uniqueKeysWithValues: engine.auVector.map { ($0.key.rawValue, round4($0.value)) }),
        ]
        if let g = probs(engine.debugGeometryDistribution) { row["geometry"] = g }
        if let m = probs(engine.debugMLDistribution) { row["ferplus"] = m }
        if let yaw = analysis.yaw { row["yaw"] = round4(yaw) }
        if let pitch = analysis.pitch { row["pitch"] = round4(pitch) }
        if let o = engine.overlay, r.faceDetected {
            // Normalized, top-left origin: the same space FaceLandmarkOverlay draws in.
            row["overlay"] = [
                "faceRect": [o.faceRect.minX, o.faceRect.minY, o.faceRect.width, o.faceRect.height].map(round4),
                "points": o.points.map { [round4($0.x), round4($0.y)] },
            ]
        }
        rows.append(row)
    }

    var out: [String: Any] = [
        "source": url.lastPathComponent,
        "fps": fps,
        "frames": rows,
        "calibration": calibration,
        "appearanceModel": scorer != nil,
        "computeDevice": cpuOnly ? "cpu" : "any",
        "engine": "AffectLens EmotionEngine (FACS/EMFACS geometry" + (scorer != nil ? " + FER+ log-linear fusion, w=0.35)" : " only)"),
    ]
    if let label = option("--label") { out["label"] = label }
    try writeJSON(out, to: option("--out"))
}

/// The classifier and the temporal smoother on synthetic Action Unit input: the same
/// prototypes the self-tests assert, swept and logged so they can be charted.
func runSynthetic() throws {
    let prototypes: [(Emotion, AUVector)] = [
        (.neutral, [:]),
        (.happiness, [.au12: 0.8, .au6: 0.5]),
        (.sadness, [.au15: 0.6, .au1: 0.4, .au4: 0.3]),
        (.surprise, [.au1: 0.6, .au2: 0.7, .au5: 0.7, .au26: 0.6]),
        (.fear, [.au1: 0.5, .au2: 0.5, .au4: 0.5, .au5: 0.6, .au20: 0.6, .au26: 0.3]),
        (.anger, [.au4: 0.7, .au7: 0.5, .au23: 0.6]),
        (.disgust, [.au9: 0.7, .au15: 0.3, .au7: 0.2]),
        (.contempt, [.auUnilateral: 0.7, .au23: 0.2]),
    ]

    // 1. Prototype matrix: each EMFACS prototype → the classifier's distribution.
    let matrix = prototypes.map { (e, au) -> [String: Any] in
        ["prototype": e.rawValue,
         "aus": Dictionary(uniqueKeysWithValues: au.map { ($0.key.rawValue, $0.value) }),
         "distribution": probs(EmotionClassifier.classify(au))!]
    }

    // 2. Intensity sweep: scale each prototype 0 → 1; probability and raw evidence.
    var sweep: [[String: Any]] = []
    for (e, au) in prototypes where e != .neutral {
        for step in 0...20 {
            let k = Double(step) / 20
            let scaled = au.mapValues { $0 * k }
            sweep.append(["emotion": e.rawValue, "scale": k,
                          "probability": round4(EmotionClassifier.classify(scaled)[e]),
                          "evidence": round4(EmotionClassifier.scores(for: scaled)[e] ?? 0),
                          "energy": round4(EmotionClassifier.expressionEnergy(for: scaled))])
        }
    }

    // 3. Hysteresis: a noisy happy ↔ surprise flicker, 15 Hz for 6 s, through the smoother.
    var rng = SplitMix64(seed: 7)
    var smoother = TemporalSmoother()
    var trace: [[String: Any]] = []
    for i in 0..<90 {
        let t = Double(i) / 15
        let phase: Emotion = t < 2 ? .neutral : (t < 4 ? .happiness : .surprise)
        var au = prototypes.first { $0.0 == phase }!.1
        // Per-frame jitter, plus a 1-in-4 frame that flips to the other expression.
        au = au.mapValues { max(0, $0 + rng.gaussian() * 0.12) }
        if phase != .neutral, rng.uniform() < 0.25 {
            au = prototypes.first { $0.0 == (phase == .happiness ? .surprise : .happiness) }!.1
        }
        let frame = EmotionClassifier.classify(au)
        let (smoothed, stable) = smoother.update(with: frame)
        trace.append(["t": round4(t), "truth": phase.rawValue,
                      "rawDominant": frame.dominant.emotion.rawValue,
                      "stableDominant": stable.rawValue,
                      "raw": probs(frame)!, "smoothed": probs(smoothed)!])
    }

    try writeJSON(["prototypes": matrix, "intensitySweep": sweep, "hysteresis": trace,
                   "note": "Synthetic Action Unit input through the real EmotionClassifier and TemporalSmoother; no face, no camera."],
                  to: option("--out"))
}

/// Deterministic noise for the synthetic trace.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

switch command {
case "run":
    try await runVideo()
case "synth":
    try runSynthetic()
case "selftest":
    #if DEBUG
    EmotionSelfTests.runAll()
    #else
    print("selftest needs a debug build: swift run affect-replay selftest")
    exit(2)
    #endif
default:
    print(usage)
    exit(2)
}
