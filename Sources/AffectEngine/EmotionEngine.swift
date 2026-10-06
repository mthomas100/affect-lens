//
//  EmotionEngine.swift
//  AffectLens
//
//  The emotion-recognition orchestrator. Per frame:
//    camera frame → Vision landmarks → roll/scale-invariant metrics
//    → calibrated FACS Action Units → EMFACS emotion scores
//    (× optional Core ML appearance expert, log-linear fusion)
//    → temporal smoothing with hysteresis → published EmotionReading.
//
//  Accuracy pillars: per-user neutral-baseline calibration (auto on first
//  face, re-runnable), pose/confidence quality gating, and slow baseline
//  drift correction while the face is verifiably neutral.
//

import Foundation
import CoreVideo
import CoreGraphics
import SwiftUI

#if os(visionOS) || os(macOS)

/// A snapshot of the AU4 head-pitch correction for the debug HUD (US-A0).
nonisolated struct PitchCorrectionDebug: Sendable {
    /// Raw `VNFaceObservation.pitch` in radians (sign per `PitchCorrection.downSign`).
    var pitch: Double
    var au4Raw: Double
    var au4Corrected: Double
}

@MainActor
@Observable
final class EmotionEngine {

    enum CalibrationPhase: Equatable {
        case idle
        case collecting(progress: Double)
    }

    // MARK: - Published outputs

    private(set) var reading: EmotionReading = .empty
    private(set) var auVector: AUVector = [:]
    private(set) var overlay: FaceOverlayData?
    private(set) var processedFPS: Double = 0
    /// Live AU4 pitch-correction telemetry for the debug HUD (US-A0). Nil until a
    /// face with a pitch reading is seen.
    private(set) var pitchDebug: PitchCorrectionDebug?
    private(set) var history: [EmotionSample] = []
    private(set) var calibrationPhase: CalibrationPhase = .idle
    private(set) var isCalibrated: Bool
    /// True when a bundled Core ML appearance model is fused with the FACS expert.
    let appearanceModelActive: Bool

    // MARK: - Tunables

    /// Analysis cadence cap (~15 Hz); camera frames beyond this are dropped.
    var minProcessInterval: TimeInterval = 1.0 / 15.0
    /// Thermal-governor gate (US-D13b, PRD v2 §8.1): whether the FER+ Core ML expert
    /// scores this frame. DEFAULT `true` ⇒ the scoring call is byte-identical to before;
    /// the governor flips it `false` at `.serious`/`.critical` to shed the expensive
    /// Vision→CoreML inference (the fusion of the last cached distribution stays cheap).
    /// `@ObservationIgnored` — a scheduler knob, never observed UI state.
    @ObservationIgnored var mlScoringEnabled = true
    private let calibrationTarget = 36
    private let mlFusionWeight = 0.35
    private let mlEveryNFrames = 3
    private let historyCap = 720

    // MARK: - Internals

    private let analyzer: FaceAnalyzer
    private var smoother = TemporalSmoother()
    private var baseline: NeutralBaseline
    private var calibrationSamples: [FacialMetrics] = []
    private var autoCalibrationAttempted = false
    private var busy = false
    private var lastProcessTime: CFAbsoluteTime = 0
    private let mlScorer: CoreMLEmotionScorer?
    private var mlBusy = false
    private var latestMLDistribution: EmotionDistribution?
    private var frameCounter = 0
    private var neutralHoldStart: Date?
    private var fpsTimestamps: [CFAbsoluteTime] = []
    /// EMA-smoothed raw evidence scores (geometric expert) — the intensity signal.
    private var smoothedIntensities: [Emotion: Double] = [:]
    /// EMA-smoothed overall expression energy (intensity stand-in for neutral).
    private var smoothedEnergy: Double = 0
    private let intensityAlpha = 0.35

    convenience init() {
        self.init(analyzer: FaceAnalyzer(), appearanceScorer: CoreMLEmotionScorer())
    }

    /// Injection point for the macOS `affect-replay` tool, which loads the FER+ model
    /// from a path instead of the app bundle and can pin Vision and Core ML to the CPU.
    init(analyzer: FaceAnalyzer, appearanceScorer: CoreMLEmotionScorer?) {
        let saved = NeutralBaseline.loadSaved()
        baseline = saved ?? .default
        isCalibrated = saved?.isCalibrated ?? false
        self.analyzer = analyzer
        mlScorer = appearanceScorer
        appearanceModelActive = appearanceScorer != nil
    }

    // MARK: - Analysis fan-out (US-B5a)

    /// Optional per-analysis tap for downstream windowed channels (eyes/blink,
    /// windowed head-pose). Mirrors the `CameraFeed.onFrame` idiom —
    /// ONE hook the hub wires to fan out to its registered consumers. The hub owns
    /// the multiplexing; the engine stays a pure face lens (PRD v2 §5.2 forbids
    /// growing `EmotionEngine` into the hub), so it offers only this single tap.
    ///
    /// Fires on the MainActor exactly once per processed analysis — INCLUDING
    /// no-face frames (absence is a signal blink/attention analyzers need) — AFTER
    /// `apply(_:pixelBuffer:)` has fully updated the engine's published state, so a
    /// consumer that reads `reading` / `overlay` / `auVector` observes a consistent
    /// engine. `nil` ⇒ exactly today's behavior: a single nil-check, no allocation,
    /// no timing change.
    @ObservationIgnored
    var onAnalysis: (@MainActor (FrameAnalysis) -> Void)?

    // MARK: - Dimensional fusion hook (US-C8)

    /// The dimensional-combine seam (PRD v2 §7.2 seam b, §5.1 L2 dimensional track).
    /// A later fusion construct (installed by the hub) MAY rewrite the per-frame
    /// valence/arousal pair — blending in non-face channels' arousal, widening under
    /// conflict, etc. The second parameter is `facePresent` so a construct can behave
    /// differently on the no-face branch. Routed through `combineVA` at BOTH V/A sites
    /// in `apply`, so they cannot diverge (the seam-b law). `nil` (today) ⇒ identity ⇒
    /// byte-identical output; non-face data enters ONLY here, never the categorical
    /// pool (seam-a veto). `@MainActor` like `onAnalysis`; the hub sets it in later items.
    @ObservationIgnored
    var vaTransform: (@MainActor (ValenceArousal, Bool) -> ValenceArousal)?

    // MARK: - Debug accessors (US-lab — additive, read-only, NO behavior change)

    /// The per-frame GEOMETRY distribution (`EmotionClassifier.classify(au)`) as computed
    /// this frame, BEFORE the optional ML fusion and BEFORE temporal smoothing. This is the
    /// categorical-pool A/B RE-FUSION input the golden-trace recorder captures (US-lab,
    /// §6.8): with it + `debugMLDistribution`, `TraceReplayer.replaySeries` can re-run the
    /// log-opinion pool under a different weight strategy on the SAME recorded evidence.
    /// Nil on no-face frames (no geometry was classified). Written every frame in `apply`;
    /// `@ObservationIgnored` so it never churns SwiftUI observation, and read-only to callers
    /// — reading it changes nothing about the live pipeline.
    @ObservationIgnored private(set) var debugGeometryDistribution: EmotionDistribution?

    /// The FER+ appearance distribution as of the current frame — the exact value the live
    /// categorical fusion used this frame (or nil when the expert has produced none yet / is
    /// disabled). A read-only view of the engine's cached `latestMLDistribution` for the
    /// trace recorder (US-lab). `@ObservationIgnored`; no behavior change.
    @ObservationIgnored var debugMLDistribution: EmotionDistribution? { latestMLDistribution }

    // MARK: - Input

    /// Feed a camera frame. Cheap to call at full camera rate; the engine
    /// throttles and drops frames internally.
    func ingest(_ pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard !busy, now - lastProcessTime >= minProcessInterval else { return }
        busy = true
        lastProcessTime = now

        Task { [weak self] in
            guard let self else { return }
            let analysis = await self.analyzer.analyze(pixelBuffer)
            self.apply(analysis, pixelBuffer: pixelBuffer)
            // Fan-out tap (US-B5a): fire AFTER `apply` has fully updated the
            // engine's published state, for EVERY analysis — including no-face
            // frames (apply's early-return path still ran to completion). nil ⇒ no-op.
            self.onAnalysis?(analysis)
            self.busy = false
        }
    }

    /// Deterministic offline variant of `ingest` for the macOS `affect-replay` tool:
    /// no wall-clock throttle (the caller picks the frames), the frame's own timestamp,
    /// and the FER+ expert awaited inline on its every-Nth-frame cadence instead of
    /// fire-and-forget, so a video replays to the same readings on every run. The FER+
    /// result still lands one frame late, exactly as the live path's async scoring does.
    @discardableResult
    func ingestOffline(_ pixelBuffer: CVPixelBuffer, at date: Date) async -> FrameAnalysis {
        let analysis = await analyzer.analyze(pixelBuffer)
        apply(analysis, pixelBuffer: pixelBuffer, now: date, scheduleML: false)
        if mlScoringEnabled, let mlScorer, let extraction = analysis.extraction,
           extraction.landmarkConfidence >= 0.25, frameCounter % mlEveryNFrames == 0 {
            let rect = visionRect(fromUIRect: extraction.overlay.faceRect)
            latestMLDistribution = await mlScorer.score(pixelBuffer: pixelBuffer, faceRect: rect)
        }
        onAnalysis?(analysis)
        return analysis
    }

    /// Restart neutral-baseline calibration (user should hold a relaxed face).
    func startCalibration() {
        calibrationSamples = []
        calibrationPhase = .collecting(progress: 0)
    }

    func clearHistory() {
        history = []
    }

    // MARK: - Pipeline

    private func apply(_ analysis: FrameAnalysis, pixelBuffer: CVPixelBuffer,
                       now: Date = Date(), scheduleML: Bool = true) {
        tickFPS()

        guard let extraction = analysis.extraction, extraction.landmarkConfidence >= 0.25 else {
            overlay = nil
            auVector = [:]
            pitchDebug = nil
            debugGeometryDistribution = nil   // no geometry classified on a no-face frame (US-lab)
            smoother.decayTowardRest()
            for (k, v) in smoothedIntensities { smoothedIntensities[k] = v * 0.85 }
            smoothedEnergy *= 0.85
            let dist = smoother.smoothed
            let rawVA = dist.valenceArousal
            let va = combineVA(rawVA, facePresent: false)
            reading = EmotionReading(
                date: now,
                distribution: dist,
                dominant: smoother.stableDominant,
                confidence: dist[smoother.stableDominant],
                intensity: 0,
                intensities: smoothedIntensities,
                valence: va.valence,
                arousal: va.arousal,
                faceDetected: false,
                quality: 0
            )
            return
        }

        // Quality = landmark confidence × head-pose penalty (frontal is best).
        let yawPenalty: Double
        if let yaw = extraction.yaw {
            yawPenalty = max(0, cos(min(abs(yaw), .pi / 2) * 1.2))
        } else {
            yawPenalty = 1
        }
        let quality = min(1, extraction.landmarkConfidence) * yawPenalty

        // First good face with no saved baseline → calibrate automatically.
        if !isCalibrated, !autoCalibrationAttempted, calibrationPhase == .idle {
            autoCalibrationAttempted = true
            startCalibration()
        }

        // Calibration collection.
        if case .collecting = calibrationPhase {
            if extraction.landmarkConfidence >= 0.4 {
                calibrationSamples.append(extraction.metrics)
            }
            let progress = Double(calibrationSamples.count) / Double(calibrationTarget)
            if calibrationSamples.count >= calibrationTarget,
               let median = FacialMetrics.median(of: calibrationSamples) {
                baseline = NeutralBaseline(metrics: median, isCalibrated: true)
                baseline.save()
                isCalibrated = true
                calibrationPhase = .idle
                calibrationSamples = []
            } else {
                calibrationPhase = .collecting(progress: min(1, progress))
            }
        }

        // Geometry expert: metrics → AUs → EMFACS distribution. Thread the head
        // pitch in so AU4 is discounted when the head tilts down (US-A0); the
        // tunable is read from UserDefaults HERE, keeping AUComputer pure math.
        let pc = pitchCorrection
        let au = AUComputer.compute(
            metrics: extraction.metrics,
            baseline: baseline.metrics,
            pitch: extraction.pitch,
            pitchCorrection: pc
        )
        updatePitchDebug(pitch: extraction.pitch, correctedAU4: au[.au4] ?? 0, config: pc)
        var frameDistribution = EmotionClassifier.classify(au)
        // Capture the PRE-fusion geometry posterior for the golden-trace recorder (US-lab).
        // Additive: this is a plain store of a value already computed — no behavior change.
        debugGeometryDistribution = frameDistribution

        // Intensity signal: raw pre-softmax evidence scores. Deliberately
        // geometric-only — intensity measures how far the face is from rest,
        // which the appearance expert cannot grade.
        let rawScores = EmotionClassifier.scores(for: au)
        for e in Emotion.allCases {
            let prev = smoothedIntensities[e] ?? 0
            smoothedIntensities[e] = prev * (1 - intensityAlpha) + (rawScores[e] ?? 0) * intensityAlpha
        }
        smoothedEnergy = smoothedEnergy * (1 - intensityAlpha)
            + EmotionClassifier.expressionEnergy(for: au) * intensityAlpha

        // Appearance expert (optional): score every Nth frame asynchronously,
        // fuse the most recent result log-linearly.
        frameCounter += 1
        if scheduleML, mlScoringEnabled, let mlScorer, frameCounter % mlEveryNFrames == 0, !mlBusy {
            mlBusy = true
            let visionRect = visionRect(fromUIRect: extraction.overlay.faceRect)
            Task { [weak self] in
                let dist = await mlScorer.score(pixelBuffer: pixelBuffer, faceRect: visionRect)
                guard let self else { return }
                self.latestMLDistribution = dist
                self.mlBusy = false
            }
        }
        if let mlDist = latestMLDistribution {
            // Categorical track (PRD v2 §5.1 L2a / seam a). Read the two fusion
            // tunables ONCE per frame (mirrors `pitchCorrection`), keeping the math in
            // pure `DynamicFaceWeight`. Defaults are NEUTRAL, so this stays byte-identical
            // to `frameDistribution.fused(with: mlDist, weight: mlFusionWeight)`:
            //   • T defaults to 1 ⇒ temperature GUARDED OFF (no p^(1/1) renormalize);
            //   • dynamic weighting defaults OFF ⇒ the constant 0.35 `mlFusionWeight`,
            //     and the entropy / weight math is never even evaluated.
            // Seam-a veto: every reliability input is FACE-derived (geometry energy,
            // geometry entropy, the FER+ expert's own peak probability).
            let temperature = fusionTemperature
            let dynamicWeighting = fusionDynamicWeighting
            let mlTuned = temperature != 1 ? DynamicFaceWeight.temperatured(mlDist, T: temperature) : mlDist
            let weight: Double
            if dynamicWeighting {
                weight = DynamicFaceWeight.mlWeight(
                    base: mlFusionWeight,
                    faceIntensity: smoothedEnergy,
                    faceAmbiguity: frameDistribution.normalizedEntropy,
                    mlConfidence: mlTuned.dominant.probability
                )
            } else {
                weight = mlFusionWeight
            }
            frameDistribution = frameDistribution.fused(with: mlTuned, weight: weight)
        }

        let (smoothedDist, stableDominant) = smoother.update(with: frameDistribution)

        // Slow baseline drift correction: after 2 s of confident neutrality,
        // gently track the current metrics to absorb session drift.
        if stableDominant == .neutral, smoothedDist[.neutral] > 0.55, quality > 0.5 {
            if let start = neutralHoldStart {
                if now.timeIntervalSince(start) > 2 {
                    baseline.metrics = baseline.metrics.lerp(toward: extraction.metrics, alpha: 0.02)
                }
            } else {
                neutralHoldStart = now
            }
        } else {
            neutralHoldStart = nil
        }

        let rawVA = smoothedDist.valenceArousal
        let va = combineVA(rawVA, facePresent: true)
        // For expressive emotions intensity = their evidence strength; for
        // neutral it degrades to overall expression energy (≈0 at rest).
        let intensity = stableDominant == .neutral
            ? smoothedEnergy
            : (smoothedIntensities[stableDominant] ?? 0)
        reading = EmotionReading(
            date: now,
            distribution: smoothedDist,
            dominant: stableDominant,
            confidence: smoothedDist[stableDominant],
            intensity: min(1, intensity),
            intensities: smoothedIntensities,
            valence: va.valence,
            arousal: va.arousal,
            faceDetected: true,
            quality: quality
        )
        auVector = au
        overlay = extraction.overlay

        history.append(EmotionSample(date: now, emotion: stableDominant, confidence: smoothedDist[stableDominant]))
        if history.count > historyCap {
            history.removeFirst(history.count - historyCap)
        }
    }

    // MARK: - Helpers

    /// AU4 pitch-correction params, read fresh each frame from `UserDefaults`
    /// (keys `au4.pitchCorrection.slope` / `au4.pitchCorrection.deadband`) so the
    /// debug HUD slider tunes it live. Kept HERE, not in `AUComputer`, so the AU
    /// math stays pure and deterministic for self-tests. Absent keys fall back to
    /// the shipped defaults (an unset key must NOT read as 0 and disable it).
    private var pitchCorrection: PitchCorrection {
        let d = UserDefaults.standard
        var pc = PitchCorrection.default
        if d.object(forKey: "au4.pitchCorrection.slope") != nil {
            pc.slope = d.double(forKey: "au4.pitchCorrection.slope")
        }
        if d.object(forKey: "au4.pitchCorrection.deadband") != nil {
            pc.deadband = d.double(forKey: "au4.pitchCorrection.deadband")
        }
        return pc
    }

    /// FER+ temperature-scaling factor (Guo 2017, US-C8), read fresh each frame from
    /// `UserDefaults` key `ferplus.temperature` so a debug slider can tune it live.
    /// DEFAULT 1.0 (identity) — an absent OR non-positive value reads as 1.0, so the
    /// shipped path never applies temperature (byte-identical). `> 1` flattens FER+,
    /// `< 1` sharpens it, before it enters the categorical pool.
    private var fusionTemperature: Double {
        let d = UserDefaults.standard
        guard d.object(forKey: "ferplus.temperature") != nil else { return 1.0 }
        let t = d.double(forKey: "ferplus.temperature")
        return t > 0 ? t : 1.0
    }

    /// Whether the categorical pool uses Aviezer DYNAMIC weighting of the FER+
    /// contribution instead of the fixed `mlFusionWeight` (US-C8). Read fresh each
    /// frame from `UserDefaults` key `fusion.dynamicWeighting.enabled`. DEFAULT false
    /// (absent ⇒ false via `bool(forKey:)`) ⇒ the constant 0.35 weight (byte-identical).
    private var fusionDynamicWeighting: Bool {
        UserDefaults.standard.bool(forKey: "fusion.dynamicWeighting.enabled")
    }

    /// The dimensional-combine seam (PRD v2 §7.2 seam b), factored so BOTH V/A sites
    /// in `apply` route through ONE rule and can't diverge (the seam-b law): apply
    /// `vaTransform` if a construct installed one, else pass the raw pair through
    /// UNCHANGED. `nil ⇒ identity ⇒ byte-identical`; nil today.
    func combineVA(_ raw: ValenceArousal, facePresent: Bool) -> ValenceArousal {
        vaTransform?(raw, facePresent) ?? raw
    }

    /// Reconstructs AU4-raw from the corrected value and the single-source removal
    /// fraction (no second AU pass) for the debug HUD. The clamp keeps the removal
    /// ≤ 0.6, so the divisor is ≥ 0.4 and the division is always safe.
    private func updatePitchDebug(pitch: Double?, correctedAU4: Double, config: PitchCorrection) {
        guard let pitch else { pitchDebug = nil; return }
        let removal = AUComputer.au4PitchRemovalFraction(pitch: pitch, config: config)
        let raw = removal < 1 ? correctedAU4 / (1 - removal) : correctedAU4
        pitchDebug = PitchCorrectionDebug(pitch: pitch, au4Raw: raw, au4Corrected: correctedAU4)
    }

    private func tickFPS() {
        let now = CFAbsoluteTimeGetCurrent()
        fpsTimestamps.append(now)
        fpsTimestamps.removeAll { now - $0 > 2 }
        processedFPS = Double(fpsTimestamps.count) / 2
    }

    /// Convert a top-left-origin UI rect back into Vision's bottom-left space.
    private func visionRect(fromUIRect r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.minY - r.height, width: r.width, height: r.height)
    }
}
#endif
