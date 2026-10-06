//
//  TraceReplayer.swift
//  AffectLens
//
//  Deterministic replay of a golden trace (US-E15, PRD v2 §5.7). Pure and
//  `nonisolated`: it pushes a recorded trace back through FRESH DOWNSTREAM state —
//  a blink detector fed the eye-openness stream and valence/arousal change-point
//  detectors fed the face readings — reproducing the derived signals the live app
//  would have produced from the SAME trace. Later items extend the per-tick output
//  (fusion, narrator) without changing this seam.
//
//  DETERMINISM LAW: `TraceReplayer` reads NO `Date()` and NO randomness — every
//  timestamp comes from the trace. Given the same trace it returns a byte-identical
//  `ReplayResult`, so `EmotionSelfTests.goldenTraceReplay()` can compare two replays
//  with `==` and compare against embedded golden expectations exactly. This turns
//  the harness from unit-math checks into a full-pipeline regression (and the
//  parameter-study substrate the PRD calls for — sweep detector params on a trace).
//
//  FIDELITY: the two lanes mirror the live wiring exactly —
//   • blink lane   ↔ `EyeChannel.ingest`   (ingest on face+eyes, else `markAbsent`);
//   • V/A lane     ↔ `AffectHub.ingestStateShift` (observe both CPDs ONLY on a
//                     detected face; a shift = either axis firing on that frame).
//  Both use the SHIPPING detector defaults, so a green replay reflects shipping math.
//

#if os(visionOS) || os(macOS)

import Foundation

nonisolated enum TraceReplayer {

    /// The downstream signals derived at one replayed tick. Codable + Equatable so a
    /// whole `ReplayResult` compares exactly. Extensible: later items append fields
    /// (fused axes, congruence, narrated flags) without disturbing existing goldens.
    struct TickOutput: Codable, Equatable, Sendable {
        var index: Int
        var facePresent: Bool
        var faceDetected: Bool
        /// A blink was counted on this frame's reopen.
        var blink: Bool
        /// A prolonged (AU43/PERCLOS) closure is in progress as of this frame.
        var prolongedClosure: Bool
        /// Rolling blinks/min as of this frame.
        var blinksPerMinute: Double
        /// The valence change-point detector fired on this frame.
        var valenceFired: Bool
        /// The arousal change-point detector fired on this frame.
        var arousalFired: Bool
    }

    /// The whole-trace replay result. `Codable` so a golden can be persisted and
    /// diffed; `Equatable` so determinism is a one-line assertion.
    struct ReplayResult: Codable, Equatable, Sendable {
        var tickCount: Int
        /// Total blinks counted across the trace.
        var blinkCount: Int
        /// Rolling blinks/min, one value per tick.
        var blinksPerMinute: [Double]
        /// Tick indices where a state-shift fired (either axis) — the `AffectHub`
        /// `.stateShift` emit points.
        var stateShiftTicks: [Int]
        /// Tick indices where the valence axis specifically fired.
        var valenceShiftTicks: [Int]
        /// Tick indices where the arousal axis specifically fired.
        var arousalShiftTicks: [Int]
        /// Per-tick derived signals (extensible; see `TickOutput`).
        var perTick: [TickOutput]
    }

    /// Replay a decoded trace through fresh downstream state. Pure.
    static func replay(_ trace: Trace) -> ReplayResult {
        // Fresh state, using the SAME defaults the live app constructs:
        //  `BlinkDetector()`  ↔ `EyeChannel.detector`
        //  `ChangePointDetector()` ×2 ↔ `AffectHub.valenceCPD` / `.arousalCPD`
        var blink = BlinkDetector()
        var valenceCPD = ChangePointDetector()
        var arousalCPD = ChangePointDetector()

        var blinkCount = 0
        var bpmSeries: [Double] = []
        var stateShiftTicks: [Int] = []
        var valenceShiftTicks: [Int] = []
        var arousalShiftTicks: [Int] = []
        var perTick: [TickOutput] = []
        bpmSeries.reserveCapacity(trace.ticks.count)
        perTick.reserveCapacity(trace.ticks.count)

        for (i, tick) in trace.ticks.enumerated() {
            // --- Blink lane (mirrors EyeChannel.ingest) ---
            var didBlink = false
            if tick.facePresent, let l = tick.eyeOpenLeft, let r = tick.eyeOpenRight {
                let openness = (l + r) / 2
                if blink.ingest(openness: openness, date: tick.t) == .blink {
                    blinkCount += 1
                    didBlink = true
                }
            } else {
                // No face, or face-but-no-usable-eye-geometry → suspend detection.
                blink.markAbsent(at: tick.t)
            }
            let bpm = blink.blinksPerMinute
            bpmSeries.append(bpm)

            // --- Valence/arousal change-point lane (mirrors AffectHub.ingestStateShift) ---
            // The CPDs advance ONLY on a detected face — a face gap is not an affect
            // change, so no-face frames must not perturb the run-length posterior.
            var vFired = false
            var aFired = false
            let faceDetected = tick.faceReading.faceDetected
            if faceDetected {
                vFired = valenceCPD.observe(tick.faceReading.valence, at: tick.faceReading.date)
                aFired = arousalCPD.observe(tick.faceReading.arousal, at: tick.faceReading.date)
                if vFired { valenceShiftTicks.append(i) }
                if aFired { arousalShiftTicks.append(i) }
                if vFired || aFired { stateShiftTicks.append(i) }
            }

            perTick.append(TickOutput(
                index: i,
                facePresent: tick.facePresent,
                faceDetected: faceDetected,
                blink: didBlink,
                prolongedClosure: blink.prolongedClosure,
                blinksPerMinute: bpm,
                valenceFired: vFired,
                arousalFired: aFired
            ))
        }

        return ReplayResult(
            tickCount: trace.ticks.count,
            blinkCount: blinkCount,
            blinksPerMinute: bpmSeries,
            stateShiftTicks: stateShiftTicks,
            valenceShiftTicks: valenceShiftTicks,
            arousalShiftTicks: arousalShiftTicks,
            perTick: perTick
        )
    }

    /// Decode JSONL bytes and replay.
    static func replay(jsonl data: Data) throws -> ReplayResult {
        replay(try Trace(jsonl: data))
    }

    /// Load a trace file and replay.
    static func replay(contentsOf url: URL) throws -> ReplayResult {
        replay(try Trace(contentsOf: url))
    }

    // MARK: - Replay-parameter study (US-lab, PRD v2 §5.7 point 2 / §6.8)
    //
    // The SAME recorded trace, pushed through the SAME downstream lanes as `replay`,
    // but under a `ReplayConfig` that rewires a few meaningful knobs — the "replay =
    // parameter study" idiom (§5.7 point 2: sweep hysteresis margins / congruence
    // windows / proxy scales on the very file that IS the CI fixture). `replay(...)`
    // above is UNTOUCHED and stays the byte-exact regression path (the goldens can't
    // move); `replaySeries` is the additive, richer per-tick output the Lab A/B panel
    // diffs. Same DETERMINISM LAW: NO `Date()`, NO randomness — every timestamp comes
    // from the trace, so two runs of the same (trace, config) are `==`.

    /// The categorical-pool RE-FUSION weight strategy for a replay (US-lab). `.fixed`
    /// is a constant FER+ weight in the log-opinion pool (shipping 0.35, dynamic
    /// weighting OFF); `.dynamic` applies the Aviezer `DynamicFaceWeight.mlWeight`
    /// (US-C8) to the SAME recorded geometry+FER+ evidence, so the Lab A/B panel can
    /// diff the two on one replay.
    nonisolated enum MLWeightStrategy: Sendable, Equatable {
        case fixed(Double)
        case dynamic
    }

    /// The knobs a replay-parameter study can sweep (US-lab, §5.7 point 2 / §8.1 US-A0).
    /// `.default` == the SHIPPING values, so `replaySeries(trace:config:.default)`
    /// reproduces the live downstream math. Deliberately a FEW meaningful knobs (per the
    /// spec): the congruence enter/exit band + the agreeing bar; the F1/F7 construct
    /// enter thresholds; the face-arousal proxy scale; and the categorical re-fusion
    /// weight strategy.
    nonisolated struct ReplayConfig: Sendable, Equatable {
        /// `CongruenceEngine.divergenceEnter` (shipping 0.0): synchrony must drop to ≤
        /// this to BEGIN a divergence.
        var congruenceEnter: Double
        /// `CongruenceEngine.divergenceExit` (shipping 0.4): synchrony must recover to ≥
        /// this to RE-ARM (the hysteresis band [enter, exit]).
        var congruenceExit: Double
        /// `CongruenceEngine.agreeingThreshold` (shipping 0.6): sign-consensus bar for the
        /// `.agreeing` named state.
        var congruenceAgreeing: Double
        /// F1 Composure ACTIVATION enter threshold (its `ConstructHysteresis.enter`,
        /// shipping 0.45); F1's shipped exit + dwells are kept.
        var f1Enter: Double
        /// F7 Frustration ACTIVATION enter threshold (0.45). GENUINELY replayed on a
        /// trace whose ticks carry an `interactionReading` (recorded whenever the
        /// interaction lens was on); on an older / face+eyes-only trace
        /// F7 never fuses and this knob is inert (honest).
        var f7Enter: Double
        /// Face-arousal signed-delta PROXY SCALE for the congruence vote
        /// (`AffectHub.faceArousalDeltaScale`, shipping 0.5): |Δ|/scale maps to a ±1 vote.
        var faceArousalDeltaScale: Double
        /// Categorical-pool re-fusion weight strategy (shipping `.fixed(0.35)`).
        var mlWeight: MLWeightStrategy

        /// The shipping configuration — `replaySeries(_, .default)` mirrors live math.
        /// 0.35 == `EmotionEngine.mlFusionWeight` (the same literal the US-C8 self-test
        /// and `DynamicFaceWeight` base use).
        static let `default` = ReplayConfig(
            congruenceEnter: 0.0,
            congruenceExit: 0.4,
            congruenceAgreeing: 0.6,
            f1Enter: 0.45,
            f7Enter: 0.45,
            faceArousalDeltaScale: 0.5,
            mlWeight: .fixed(0.35)
        )
    }

    /// One replayed tick's downstream signals under a `ReplayConfig` (US-lab). `Equatable`
    /// so `replaySeries` determinism is a one-line `==` (mirrors `TickOutput`).
    nonisolated struct ReplayTick: Sendable, Equatable {
        var index: Int
        var facePresent: Bool
        var faceDetected: Bool
        // Blink lane (mirrors `EyeChannel.ingest` — identical math to `TickOutput`).
        var blink: Bool
        var prolongedClosure: Bool
        var blinksPerMinute: Double
        // Change-point lane (mirrors `AffectHub.ingestStateShift`).
        var valenceFired: Bool
        var arousalFired: Bool
        var stateShift: Bool
        // Congruence lane (mirrors `AffectHub.ingestCongruence`, config-thresholded).
        var congruence: NamedCongruence
        var congruenceBreakBegan: Bool
        // Construct lane — F1 genuinely replayed (face+eyes, plus any recorded
        // hands/head/voice proxies); F7 genuinely replayed when the trace carries an
        // `interactionReading`, inert on older face+eyes-only traces.
        var f1Active: Bool
        var f1Score: Double
        var f7Active: Bool
        var f7Score: Double
        // Categorical A/B lane: the RE-FUSED dominant under `config.mlWeight`, or nil when
        // this tick carries no geometry+FER+ distributions (pre-US-lab / no-face frame).
        var refusedDominant: Emotion?
    }

    /// The whole-trace series under a config (US-lab): the per-tick output + convenience
    /// roll-ups the A/B diff reads. `Equatable` for the determinism self-test.
    nonisolated struct ReplayTickSeries: Sendable, Equatable {
        var config: ReplayConfig
        var ticks: [ReplayTick]
        var blinkCount: Int
        var stateShiftCount: Int
        var congruenceBreakCount: Int
        var f1Activations: Int
        var f7Activations: Int
        /// True iff at least one tick carried the geometry+FER+ distributions the
        /// categorical A/B needs — false for an old (pre-US-lab) trace ⇒ params-only.
        var hasDistributions: Bool
    }

    /// Replay a decoded trace through fresh downstream state under `config`, returning the
    /// richer per-tick `ReplayTickSeries`. Pure; NO `Date()`, NO randomness.
    static func replaySeries(_ trace: Trace, config: ReplayConfig = .default) -> ReplayTickSeries {
        // Fresh state, same defaults the live app + `replay` construct, plus the
        // config-thresholded congruence engine and the face-arousal proxy baseline.
        var blink = BlinkDetector()
        var valenceCPD = ChangePointDetector()
        var arousalCPD = ChangePointDetector()
        var congruence = CongruenceEngine()
        congruence.divergenceEnter = config.congruenceEnter
        congruence.divergenceExit = config.congruenceExit
        congruence.agreeingThreshold = config.congruenceAgreeing
        var faceArousalMedian: Double?   // seed-if-absent + slow retrack (mirrors the hub)

        // F1 / F7 latches, config-overridden enter but each mode's shipped exit+dwell.
        let f1 = F1ComposureMode()
        let f7 = F7FrustrationMode()
        var f1Latch = latch(from: f1.hysteresis, enter: config.f1Enter)
        var f7Latch = latch(from: f7.hysteresis, enter: config.f7Enter)

        var ticks: [ReplayTick] = []
        ticks.reserveCapacity(trace.ticks.count)
        var blinkCount = 0, stateShiftCount = 0, congruenceBreakCount = 0
        var f1Activations = 0, f7Activations = 0
        var hasDistributions = false

        for (i, tick) in trace.ticks.enumerated() {
            // --- Blink lane (identical to `replay`) ---
            var didBlink = false
            if tick.facePresent, let l = tick.eyeOpenLeft, let r = tick.eyeOpenRight {
                if blink.ingest(openness: (l + r) / 2, date: tick.t) == .blink { blinkCount += 1; didBlink = true }
            } else {
                blink.markAbsent(at: tick.t)
            }
            let bpm = blink.blinksPerMinute

            // --- Change-point lane (identical to `replay`) ---
            var vFired = false, aFired = false
            let faceDetected = tick.faceReading.faceDetected
            if faceDetected {
                vFired = valenceCPD.observe(tick.faceReading.valence, at: tick.faceReading.date)
                aFired = arousalCPD.observe(tick.faceReading.arousal, at: tick.faceReading.date)
                if vFired || aFired { stateShiftCount += 1 }
            }

            // --- Congruence lane (mirrors `AffectHub.ingestCongruence` with config knobs) ---
            var votes: [Channel: ChannelVote] = [:]
            if faceDetected {
                let observed = tick.faceReading.arousal
                let median: Double
                if let m = faceArousalMedian {
                    let next = m + 0.02 * (observed - m)   // == AffectHub.faceArousalBaselineAlpha
                    faceArousalMedian = next
                    median = next
                } else {
                    faceArousalMedian = observed             // seed on the first face
                    median = observed
                }
                let signed = max(-1, min(1, (observed - median) / config.faceArousalDeltaScale))
                let reliability = ChannelConfidence.confidence(
                    calibrationQuality: 1, availability: .live, secondsSinceUpdate: 0,
                    tau: 1, dataQuality: tick.faceReading.quality)
                if reliability > 0 { votes[.face] = ChannelVote(signedArousalDelta: signed, reliability: reliability) }
            }
            if let eyes = tick.eyesReading, eyes.availability != .unavailable,
               let signedDelta = eyes.features[.blinkRate], let magnitude = eyes.arousal?.value {
                let signed = signedDelta < 0 ? -magnitude : magnitude   // == EyeChannel.signedArousalDelta
                let reliability = ChannelConfidence.confidence(
                    calibrationQuality: 1, availability: eyes.availability, secondsSinceUpdate: 0,
                    tau: 1, dataQuality: eyes.quality)
                if reliability > 0 { votes[.eyes] = ChannelVote(signedArousalDelta: signed, reliability: reliability) }
            }
            // Recorded hands / head / voice votes: reconstructed from each
            // recorded reading with the SAME formulas the live channels use — hands/head
            // squash their energy-delta feature by the channel's documented scale (the
            // literals mirror `HandsChannel.energyDeltaScale` 0.5 / `HeadChannel
            // .energyDeltaScale` 1.0 — MainActor statics this nonisolated replayer can't
            // read, the established F1 literal idiom), voice recovers the signed
            // activation from its published meter via the one shared formula. Calibration
            // quality 1 like the eyes lane: a replay trusts the recording's own quality.
            if let hands = tick.handsReading, hands.availability != .unavailable,
               let raw = hands.features[.gestureEnergy] {
                let signed = max(-1, min(1, raw / 0.5))                 // == HandsChannel.signedArousalDelta
                let reliability = ChannelConfidence.confidence(
                    calibrationQuality: 1, availability: hands.availability, secondsSinceUpdate: 0,
                    tau: 1, dataQuality: hands.quality)
                if reliability > 0 { votes[.hands] = ChannelVote(signedArousalDelta: signed, reliability: reliability) }
            }
            if let head = tick.headReading, head.availability != .unavailable,
               let raw = head.features[.headMotionEnergy] {
                let signed = max(-1, min(1, raw / 1.0))                 // == HeadChannel.signedArousalDelta
                let reliability = ChannelConfidence.confidence(
                    calibrationQuality: 1, availability: head.availability, secondsSinceUpdate: 0,
                    tau: 1, dataQuality: head.quality)
                if reliability > 0 { votes[.head] = ChannelVote(signedArousalDelta: signed, reliability: reliability) }
            }
            if let voice = tick.voiceReading, voice.availability != .unavailable,
               let meter = voice.arousal {
                let signed = VoiceChannel.signedActivation(from: meter)  // == VoiceChannel.signedArousalDelta
                let reliability = ChannelConfidence.confidence(
                    calibrationQuality: 1, availability: voice.availability, secondsSinceUpdate: 0,
                    tau: 1, dataQuality: voice.quality)
                if reliability > 0 { votes[.voice] = ChannelVote(signedArousalDelta: signed, reliability: reliability) }
            }
            let cUpdate = congruence.update(votes: votes, at: tick.t)
            if cUpdate.divergenceBegan { congruenceBreakCount += 1 }

            // --- Construct lane (F1 + F7 genuinely replayed over whatever the trace
            //     carries: eyes, and the recorded interaction/voice/hands/head readings —
            //     F7 fuses once an interactionReading is present; F1's extra proxies
            //     light up exactly as in `AffectHub.evaluateFusion`) ---
            var readings: [Channel: ChannelReading] = [.face: enrichedFace(tick)]
            if let eyes = tick.eyesReading { readings[.eyes] = eyes }
            if let inter = tick.interactionReading { readings[.interaction] = inter }
            if let voice = tick.voiceReading { readings[.voice] = voice }
            if let hands = tick.handsReading { readings[.hands] = hands }
            if let head = tick.headReading { readings[.head] = head }
            var f1Active = false, f1Score = 0.0
            if let out = f1.fuse(readings) {
                f1Score = out.score
                let was = f1Latch.isActive
                f1Active = f1Latch.update(score: out.score)
                if f1Active && !was { f1Activations += 1 }
            } else { f1Latch.reset() }
            var f7Active = false, f7Score = 0.0
            if let out = f7.fuse(readings) {
                f7Score = out.score
                let was = f7Latch.isActive
                f7Active = f7Latch.update(score: out.score)
                if f7Active && !was { f7Activations += 1 }
            } else { f7Latch.reset() }

            // --- Categorical A/B lane: re-fuse geometry+FER+ under the config strategy ---
            var refusedDominant: Emotion?
            if let geo = tick.geometryDistribution, let ml = tick.mlDistribution {
                hasDistributions = true
                refusedDominant = refuse(geometry: geo, ml: ml, strategy: config.mlWeight,
                                         faceIntensity: tick.faceReading.intensity).dominant.emotion
            }

            ticks.append(ReplayTick(
                index: i,
                facePresent: tick.facePresent,
                faceDetected: faceDetected,
                blink: didBlink,
                prolongedClosure: blink.prolongedClosure,
                blinksPerMinute: bpm,
                valenceFired: vFired,
                arousalFired: aFired,
                stateShift: vFired || aFired,
                congruence: cUpdate.state.named,
                congruenceBreakBegan: cUpdate.divergenceBegan,
                f1Active: f1Active,
                f1Score: f1Score,
                f7Active: f7Active,
                f7Score: f7Score,
                refusedDominant: refusedDominant
            ))
        }

        return ReplayTickSeries(
            config: config,
            ticks: ticks,
            blinkCount: blinkCount,
            stateShiftCount: stateShiftCount,
            congruenceBreakCount: congruenceBreakCount,
            f1Activations: f1Activations,
            f7Activations: f7Activations,
            hasDistributions: hasDistributions
        )
    }

    /// Decode JSONL bytes and replay-series.
    static func replaySeries(jsonl data: Data, config: ReplayConfig = .default) throws -> ReplayTickSeries {
        replaySeries(try Trace(jsonl: data), config: config)
    }

    /// Load a trace file and replay-series.
    static func replaySeries(contentsOf url: URL, config: ReplayConfig = .default) throws -> ReplayTickSeries {
        replaySeries(try Trace(contentsOf: url), config: config)
    }

    // MARK: - Replay helpers (pure)

    /// A `ConstructHysteresis` with `enter` overridden but the mode's shipped exit + dwell
    /// kept — the "honestly rewire the enter threshold" knob for the construct lane.
    private static func latch(from base: ConstructHysteresis, enter: Double) -> ConstructHysteresis {
        ConstructHysteresis(enter: enter, exit: base.exit,
                            enterDwellTicks: base.enterDwellTicks, exitDwellTicks: base.exitDwellTicks)
    }

    /// The face channel reading fusion consumes, enriched with the brow/lid AUs F1/F7 read
    /// (mirrors `AffectHub.enrichedFaceReading`, minus the live separability the hub injects
    /// — a replay treats it as ungated, exactly like a direct unit call).
    private static func enrichedFace(_ tick: TraceTick) -> ChannelReading {
        var r = tick.faceReading.asChannelReading()
        let map: [(String, FeatureKey)] = [("au1", .au1), ("au4", .au4), ("au5", .au5), ("au7", .au7), ("au15", .au15)]
        for (key, fk) in map { if let v = tick.auVector[key] { r.features[fk] = v } }
        return r
    }

    /// Re-fuse the recorded geometry + FER+ distributions under a weight strategy — the
    /// categorical A/B core. `.fixed(w)` is the log-opinion pool at constant weight;
    /// `.dynamic` is the Aviezer `DynamicFaceWeight.mlWeight` on the SAME evidence.
    private static func refuse(geometry: EmotionDistribution, ml: EmotionDistribution,
                              strategy: MLWeightStrategy, faceIntensity: Double) -> EmotionDistribution {
        let base = 0.35   // == EmotionEngine.mlFusionWeight
        let weight: Double
        switch strategy {
        case .fixed(let w):
            weight = w
        case .dynamic:
            weight = DynamicFaceWeight.mlWeight(
                base: base, faceIntensity: faceIntensity,
                faceAmbiguity: geometry.normalizedEntropy, mlConfidence: ml.dominant.probability)
        }
        return geometry.fused(with: ml, weight: weight)
    }
}

#endif
