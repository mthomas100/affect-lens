//
//  F2CognitiveLoad.swift
//  AffectLens
//
//  F2 — COGNITIVE LOAD / EFFORT (US-D14a, PRD v2 §4.2 F2 / §4.6). An ORTHOGONAL
//  attention axis, explicitly NOT an emotion: ONE calibrated 0…1 load meter WITH a
//  variance band. Anchor: Chua 2024; HP Omnicept (a SHIPPED mean+variance cognitive-load
//  meter); Doherty-Sneddon & Phelps 2005 (gaze-aversion is load, not evasion). Windowed
//  MVV is E×I (eyes blink-suppression + interaction slowing/corrections); hands & head
//  ENHANCE when live (§4.6).
//
//  THE HONESTY LAW (never soften it). This is EFFORT / LOAD language ONLY — NEVER "stress",
//  NEVER "anxiety" (both trap on the banlist). The confound is stated verbatim: high effort
//  and unease look alike here, and anxiety vs. task difficulty are indistinguishable, so the
//  ceiling is capped (≤ 0.7) and the surfaced word is "high effort/load", an attention axis.
//
//  THE SIGN DISCIPLINE (what keeps it honest). Load shows up as STILLING, not motion:
//  blink SUPPRESSION (fewer blinks than your own resting rate), interaction SLOWING +
//  corrections, self-touch, and hands/head going STILLER than your own resting baseline.
//  "Stillness" is therefore measured as motion BELOW your resting floor (a genuine negative
//  delta = freezing), so ordinary calm — which sits AT the resting floor — reads ~0 and F2
//  never mistakes calm for load, and HIGH gesture / head motion contributes NOTHING (motion
//  is not load). The confound F2 cannot resolve — anxious-freezing vs. task-load-freezing —
//  is exactly why the language stays "effort/load".
//
//  THE VARIANCE (the Omnicept idiom). The hub records each tick's load score into a rolling
//  window (`RollingLoad`, `spreadWindow`) and writes the standard deviation into
//  `FusionOutput.spread`, so the UI renders the mean as a needle with a ±band, not a bare
//  number. `fuse` stays PURE — the temporal buffer is state the hub already owns for latches.
//
//  DIMENSIONAL VETO. F2 is a NAMED STATE + insight + a mean±variance meter only. It does NOT
//  move the published valence/arousal (`FusionOutput.valence`/`arousal` stay nil; the hub
//  leaves `EmotionEngine.vaTransform` nil).
//

#if os(visionOS) || os(macOS)

import Foundation

/// F2 Cognitive load / effort — the E×I (→ +H/Hd) windowed-MVV construct with a variance
/// band. A `nonisolated` value type: its metadata, `fuse` math, and the pure `spread`
/// helper are self-testable off the main actor, per the project's MainActor-default regime.
nonisolated struct F2CognitiveLoadMode: VarianceReportingFusionMode {

    // MARK: Identity / honesty metadata

    var id: String { ConstructID.cognitiveLoad }        // toggle key: fusion.f2-cognitive-load.enabled
    var title: String { "Cognitive load / effort" }
    /// Windowed MVV is eyes × interaction; hands & head ENHANCE when live (§4.6). Written
    /// generically over "whichever load indicators are present", so the enhancing channels
    /// join automatically the moment they are enabled — no fusion-math change.
    var requires: Set<Channel> { [.eyes, .interaction] }

    var rationale: String { HonestyPhrases.cognitiveLoadRationale }
    var confound: String { HonestyPhrases.cognitiveLoadConfound }
    var citation: String? { "Chua 2024 / HP Omnicept" }
    /// An orthogonal attention proxy, not a felt state, and its confound is strong (effort
    /// and unease look alike), so it never claims more than moderate-high trust — ceiling 0.7.
    var confidenceCeiling: Double { 0.7 }

    // MARK: Hysteresis (documented band + dwell, ~15 Hz ticks)

    /// Load is a SUSTAINED state, so the latch dwells before it surfaces and re-arms faster
    /// than it commits: enter 0.40 / exit 0.28 is a real hysteresis band; enter-dwell 30 ≈
    /// 2 s at the ~15 Hz fan-out (a momentary dip can't trip it); exit-dwell 15 ≈ 1 s.
    var hysteresis: ConstructHysteresis {
        ConstructHysteresis(enter: 0.40, exit: 0.28, enterDwellTicks: 30, exitDwellTicks: 15)
    }

    // MARK: Variance (the Omnicept mean+variance idiom)

    /// The rolling window (seconds) over which the hub computes the load-score standard
    /// deviation → `FusionOutput.spread`. ~8 s smooths per-tick jitter into a stable band
    /// while still reflecting a genuinely wobbling load.
    var spreadWindow: TimeInterval { 8 }

    // MARK: Tunables (documented scales — all in the readings' own units)

    /// A blink-rate SUPPRESSION (Δ/min BELOW your resting rate) that maps to a full
    /// blink-load indicator. Attention suppresses blinks (Holland & Tarlow 1972); 8/min
    /// below resting is a clear suppression on the eyes lens's 12/min arousal scale.
    static let blinkSuppressionScale = 8.0
    /// An input-tempo SLOWING (Δ/min BELOW your baseline) that maps to a full slowing
    /// indicator — deliberate, effortful input runs slower.
    static let tempoSlowScale = 10.0
    /// A cancel/correction-rate RISE (Δ above your baseline) that maps to a full corrections
    /// indicator — a +0.25 (25-pt) climb tops it out (mirrors F7's `cancelDeltaScale`).
    static let cancelRiseScale = 0.25
    /// A self-touch RATE (events/min) that maps to a full self-touch indicator (== the hands
    /// lens's `selfTouchRateScale`); resting self-touch is ~0/min, so the rate IS the delta.
    static let selfTouchScale = 3.0
    /// A hand-motion SUPPRESSION (m/s Δ BELOW your resting hands) that maps to full hand
    /// stillness — gesture suppression under load (Goldin-Meadow); the SIGN is what matters
    /// (below resting = stilling/tension = load; above resting = motion ≠ load).
    static let gestureStillScale = 0.3
    /// A hand aperture at/below which a still hand reads fully TENSE (clenched). Only a real,
    /// positive aperture is read (a 0 aperture is treated as "no data", never full tension).
    static let apertureRelaxed = 0.5
    /// A head-motion SUPPRESSION (rad/s Δ BELOW your resting head) that maps to full head
    /// stillness — postural freezing under load; same below-resting SIGN discipline.
    static let headStillScale = 0.3

    /// Per-indicator BASE weights (before the channel's live reliability multiplies in). Blink
    /// suppression is the best-validated load cue and leads; interaction slowing/corrections
    /// follow; self-touch, hand-tension and head-stillness are lighter enhancers.
    static let blinkWeight = 1.0
    static let slowingWeight = 0.8
    static let correctionsWeight = 0.8
    static let selfTouchWeight = 0.6
    static let handTensionWeight = 0.5
    static let headStillWeight = 0.4

    /// Confidence is at most the mean reliability of the required channels, damped, and
    /// capped by the ceiling (a conjunction of behavioral proxies is inherently uncertain).
    static let confidenceDamping = 0.9

    // MARK: One weighed load indicator

    /// One load indicator: a [0,1] value, a base weight, its citable signal, and the channel
    /// that produced it (for the contribution audit). The channel's live `quality` multiplies
    /// the base weight so a warming / degraded channel counts for less.
    private struct Indicator {
        var value: Double
        var weight: Double
        var signal: SignalRef
        var channel: Channel
    }

    // MARK: Fuse

    /// Fuse the current per-channel readings into F2's load meter, or `nil` if the required
    /// eyes+interaction signals aren't both present this tick (never a fabricated read —
    /// §4.2), or if no live indicator carries any reliability. Reads `.eyes` + `.interaction`
    /// (required) and, when present & live, `.hands` + `.head` (the enhancers). Pure over inputs.
    func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
        guard let eyes = readings[.eyes], eyes.availability != .unavailable,
              let inter = readings[.interaction], inter.availability != .unavailable
        else { return nil }

        var indicators: [Indicator] = []

        // EYES — blink SUPPRESSION (Δ/min below resting; the signed delta's negative side).
        let blinkDelta = eyes.features[.blinkRate] ?? 0
        indicators.append(Indicator(
            value: clamp01(max(0, -blinkDelta) / Self.blinkSuppressionScale),
            weight: Self.blinkWeight * eyes.quality, signal: .blinkRate, channel: .eyes))

        // INTERACTION — slowing (tempo Δ below baseline) + corrections (cancel Δ above baseline).
        let tempoDelta = inter.features[.inputTempo] ?? 0
        let cancelDelta = inter.features[.cancelRate] ?? 0
        indicators.append(Indicator(
            value: clamp01(max(0, -tempoDelta) / Self.tempoSlowScale),
            weight: Self.slowingWeight * inter.quality, signal: .inputTempo, channel: .interaction))
        indicators.append(Indicator(
            value: clamp01(max(0, cancelDelta) / Self.cancelRiseScale),
            weight: Self.correctionsWeight * inter.quality, signal: .cancelRate, channel: .interaction))

        // HANDS (enhance) — self-touch rate + hand TENSION (still-below-resting OR clenched
        // aperture). Motion does NOT load: gesture ABOVE resting yields 0 here (the sign).
        if let hands = readings[.hands], hands.availability != .unavailable {
            let selfTouchRate = hands.features[.selfTouchRate] ?? 0
            indicators.append(Indicator(
                value: clamp01(selfTouchRate / Self.selfTouchScale),
                weight: Self.selfTouchWeight * hands.quality, signal: .selfTouchRate, channel: .hands))

            let gestureDelta = hands.features[.gestureEnergy] ?? 0
            let gestureStill = clamp01(max(0, -gestureDelta) / Self.gestureStillScale)
            let aperture = hands.features[.handAperture] ?? 0
            let apertureTension = aperture > 0
                ? clamp01((Self.apertureRelaxed - aperture) / Self.apertureRelaxed) : 0
            // The tension signal cited is whichever component drives it (motion vs. aperture).
            let tensionSignal: SignalRef = apertureTension > gestureStill ? .handAperture : .gestureEnergy
            indicators.append(Indicator(
                value: max(gestureStill, apertureTension),
                weight: Self.handTensionWeight * hands.quality, signal: tensionSignal, channel: .hands))
        }

        // HEAD (enhance) — head STILLNESS (motion below resting = postural freezing). Head
        // motion ABOVE resting yields 0 (motion ≠ load), same sign discipline.
        if let head = readings[.head], head.availability != .unavailable {
            let headDelta = head.features[.headMotionEnergy] ?? 0
            indicators.append(Indicator(
                value: clamp01(max(0, -headDelta) / Self.headStillScale),
                weight: Self.headStillWeight * head.quality, signal: .headMotionEnergy, channel: .head))
        }

        // LOAD = the reliability-weighted MEAN of the available indicators. No live reliability
        // at all ⇒ no trustworthy load ⇒ nil (never fabricate a value from zero-weight cues).
        let totalW = indicators.reduce(0) { $0 + $1.weight }
        guard totalW > 1e-9 else { return nil }
        let load = clamp01(indicators.reduce(0) { $0 + $1.weight * $1.value } / totalW)

        // CONTRIBUTIONS — per channel, its STRONGEST indicator (the legible-fusion audit).
        var contributions: [Channel: Double] = [:]
        for ind in indicators {
            contributions[ind.channel] = max(contributions[ind.channel] ?? 0, ind.value)
        }

        // EVIDENCE — cite only the signals that ACTUALLY contribute (value > 0), so the
        // narrator's attribution sentence lists only the live, loading cues (the honesty law).
        var evidence: [SignalRef] = []
        for ind in indicators where ind.value > 0 {
            if !evidence.contains(ind.signal) { evidence.append(ind.signal) }
        }

        // CONFIDENCE — mean reliability of the REQUIRED channels, damped, capped at the
        // ceiling. Epistemic — kept SEPARATE from the load magnitude.
        let reliability = (eyes.quality + inter.quality) / 2
        let confidence = min(confidenceCeiling, reliability * Self.confidenceDamping)

        return FusionOutput(
            namedState: HonestyPhrases.cognitiveLoadState,   // "high effort/load" — surfaced by the hub on latch
            valence: nil, arousal: nil,                      // F2 does NOT move the published V/A
            contributions: contributions,
            confidence: confidence,
            score: load,
            evidence: evidence
            // `spread` is set by the hub AFTER fuse (the rolling variance it owns).
        )
    }

    // MARK: Pure variance helper (used by RollingLoad + the self-tests)

    /// Population standard deviation of a load series — the "variance" half of the Omnicept
    /// mean+variance idiom. 0 for < 2 samples (no spread to speak of yet).
    static func spread(of values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

// MARK: - RollingLoad (the hub-owned mean+variance window, US-D14a F2)

/// A tiny rolling buffer of recent load scores over a documented window, exposing the
/// running standard deviation (the Omnicept mean+variance idiom, PRD v2 §4.2 F2). The hub
/// owns the live instance per `VarianceReportingFusionMode` id (parallel to `fusionHysteresis`)
/// and advances it each tick with the fused score, keeping `F2CognitiveLoadMode.fuse` pure.
/// A `nonisolated`, `Equatable` value type so it can live in a hub dictionary.
nonisolated struct RollingLoad: Sendable, Equatable {
    private struct Sample: Sendable, Equatable { var date: Date; var value: Double }
    /// Rolling window (seconds).
    var window: TimeInterval
    private var samples: [Sample] = []

    init(window: TimeInterval) { self.window = window }

    /// Fold one load score in, prune to the window, and return the current spread.
    mutating func record(_ value: Double, at date: Date) -> Double {
        samples.append(Sample(date: date, value: value))
        let cutoff = date.addingTimeInterval(-window)
        samples.removeAll { $0.date < cutoff }
        return F2CognitiveLoadMode.spread(of: samples.map(\.value))
    }

    /// Drop the buffer (a required channel went dark / the mode became unavailable).
    mutating func reset() { samples.removeAll() }
}

#endif
