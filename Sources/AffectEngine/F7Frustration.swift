//
//  F7Frustration.swift
//  AffectLens
//
//  F7 — FRUSTRATION (task friction) — the first concrete `FusionMode` (US-C9,
//  PRD v2 §4.2 F7 / §4.6). The killer property: it needs NO new sensor and NO new
//  permission — it marries the always-on face lens to the zero-permission, fully
//  windowed INTERACTION lens, so it is a fusion flagship that ships early.
//
//  THE CONJUNCTION IS THE CONSTRUCT. F7 fires only when BOTH a negative-leaning
//  Persona expression AND interaction friction (cancels / corrections climbing) are
//  present together — because that co-occurrence is exactly what disambiguates
//  "frustrated with the task" from plain sadness (the face alone) or plain effort/load
//  (the interaction alone). Either signal by itself is INSUFFICIENT, so the score is a
//  geometric mean that collapses to 0 the moment one component is absent.
//
//  HONESTY LAW (§4.2 / §6.7). The sanctioned framing is "frustration (TASK FRICTION)",
//  never bare "frustration"; the named confound — task difficulty and feeling are
//  indistinguishable here — is stated verbatim in the rationale + surfaced by the
//  RationalePanel. F7 NEVER asserts frustration from the interaction channel alone.
//  Confidence is stated separately from intensity and capped by `confidenceCeiling`.
//
//  DIMENSIONAL VETO. F7 is a NAMED STATE + insight + UI chip only. It does NOT move the
//  published valence/arousal (`FusionOutput.valence`/`arousal` stay nil, and the hub
//  leaves `EmotionEngine.vaTransform` nil) — dimensional blending is a later decision.
//

#if os(visionOS) || os(macOS)

import Foundation

/// F7 Frustration (task friction) — `F×I` fused construct (PRD §4.6 windowed MVV).
/// A `nonisolated` value type: its metadata and `fuse` math are pure and self-testable
/// off the main actor, per the project's MainActor-default regime.
nonisolated struct F7FrustrationMode: FusionMode {

    // MARK: Identity / honesty metadata

    var id: String { ConstructID.frustration }           // toggle key: fusion.f7-frustration.enabled
    var title: String { "Frustration (task friction)" } // the sanctioned framing (never bare "frustration")
    var requires: Set<Channel> { [.face, .interaction] }

    var rationale: String {
        "Marries a negative-leaning Persona expression to interaction friction — cancels "
        + "and corrections climbing as you work THIS app's own controls. It reports "
        + "frustration only when BOTH are present together, which is what separates "
        + "frustration-with-the-task from plain sadness (face alone) or plain effort "
        + "(interaction alone). Task difficulty and feeling are indistinguishable here."
    }
    var confound: String {
        "task difficulty and feeling look alike — a hard task and a frustrating one drive the same signals"
    }
    var citation: String? { "interaction dynamics + Chua 2024" }
    /// F7 may never claim more than moderate-high trust: the confound is strong and the
    /// interaction signal is a behavioral proxy, not a felt state.
    var confidenceCeiling: Double { 0.7 }

    // MARK: Hysteresis (documented band + dwell, ~15 Hz ticks)

    /// Frustration is a SUSTAINED state, so the latch dwells before it surfaces and
    /// re-arms faster than it commits:
    ///   • enter 0.45 / exit 0.30 — a real hysteresis band, so a score wandering the
    ///     middle can't chatter the label;
    ///   • enter-dwell 38 ticks ≈ 2.5 s at the fan-out's ~15 Hz — a single mis-pinch or
    ///     a momentary frown can't trip it;
    ///   • exit-dwell 15 ticks ≈ 1 s — once the friction clears, drop the (now stale)
    ///     negative attribution promptly rather than lingering on it.
    var hysteresis: ConstructHysteresis {
        ConstructHysteresis(enter: 0.45, exit: 0.30, enterDwellTicks: 38, exitDwellTicks: 15)
    }

    // MARK: Tunables (documented thresholds — all in the readings' own units)

    /// Ignore valence this shallow (probability-weighted circumplex valence rests at 0;
    /// negative emotions anchor ≈ −0.55…−0.80, so a small dip is not a "negative lean").
    static let valenceDeadband = 0.10
    /// Negativity beyond the deadband that maps to a FULL face-negative component — a
    /// clearly negative Persona read (v ≈ −0.55) tops it out.
    static let valenceSpan = 0.45
    /// Ignore AU4 (brow-lowerer, already baseline-relative) this shallow…
    static let au4Deadband = 0.15
    /// …and this much elevation past the deadband maps to a full AU4 component.
    static let au4Span = 0.45
    /// A cancel/correction-RATE rise (Δ from the per-user baseline) that maps to full
    /// friction from that term. A +0.25 (25-percentage-point) climb tops it out.
    static let cancelDeltaScale = 0.25
    /// A rising input-tempo Δ (per minute, from baseline) that maps to full friction
    /// from the secondary term — rapid repeated attempts.
    static let tempoDeltaScale = 15.0
    /// Friction weights: the cancel/correction rate DOMINATES (the PRD's "cancel/
    /// correction-rate↑" — the direct friction cue); a rising tempo adds a little.
    /// (Press-duration, published under `.responseLatency`, is deliberately EXCLUDED:
    /// it is a dwell proxy, NOT true stimulus→response latency, so leaning on it as
    /// "latency↑" would overclaim — InteractionChannel documents that caveat.)
    static let cancelWeight = 0.7
    static let tempoWeight = 0.3
    /// A construct is at most as trustworthy as its WEAKEST channel, discounted further
    /// because a conjunction of two proxies is inherently less certain than either.
    static let confidenceDamping = 0.85

    // MARK: Fuse

    /// Fuse the current per-channel readings into F7's output, or `nil` if the required
    /// signals aren't present this tick. Returns `nil` when the interaction reading is
    /// STARVED (`.unavailable`) — the designed low-signal state, NEVER a fabricated read
    /// (§4.2): no output ⇒ no score ⇒ the hysteresis can't latch and no event fires.
    func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
        guard let face = readings[.face], face.availability != .unavailable,
              let inter = readings[.interaction], inter.availability != .unavailable
        else { return nil }

        // FACE component — negative lean = the STRONGER of a negative valence beyond a
        // deadband and an AU4 (brow-knit) elevation beyond a deadband, each clamped [0,1].
        let v = face.valence?.value ?? 0
        let negValence = clamp01((max(0, -v) - Self.valenceDeadband) / Self.valenceSpan)
        let au4 = face.features[.au4] ?? 0
        let au4Component = clamp01((au4 - Self.au4Deadband) / Self.au4Span)
        let faceComponent = max(negValence, au4Component)

        // INTERACTION component — friction = cancel/correction-rate rise (dominant) plus
        // a rising input tempo (secondary). Only RISES count as friction (a drop in
        // cancels or a slowdown is not friction), so each Δ is floored at 0.
        let cancelDelta = inter.features[.cancelRate] ?? 0
        let tempoDelta = inter.features[.inputTempo] ?? 0
        let cancelComponent = clamp01(max(0, cancelDelta) / Self.cancelDeltaScale)
        let tempoComponent = clamp01(max(0, tempoDelta) / Self.tempoDeltaScale)
        let frictionComponent = clamp01(Self.cancelWeight * cancelComponent + Self.tempoWeight * tempoComponent)

        // SCORE — geometric mean: the construct is the CONJUNCTION, so EITHER component
        // at 0 forces the score to 0 (that is the greater-than-sum property, made literal).
        let score = (faceComponent * frictionComponent).squareRoot()

        // CONFIDENCE — min of the channel confidences (face's valence-meter confidence;
        // interaction's epistemic `quality`), damped, then capped at the ceiling. Always
        // ≤ the weakest channel's confidence (epistemic — kept separate from `score`).
        let faceConf = face.valence?.confidence ?? face.arousal?.confidence ?? 0
        let interConf = inter.quality
        let confidence = min(confidenceCeiling, min(faceConf, interConf) * Self.confidenceDamping)

        // EVIDENCE — only the signals that actually contributed (the honesty law: cite
        // only present signals). At least one face signal fires whenever faceComponent > 0.
        var evidence: [SignalRef] = []
        if negValence > 0 { evidence.append(.valence) }
        if au4Component > 0 { evidence.append(.au4) }
        evidence.append(.cancelRate)                 // the primary friction signal
        if tempoComponent > 0 { evidence.append(.inputTempo) }

        // CONTRIBUTIONS — the two channels with their component magnitudes (M5: "shows
        // contributing channels + weight"). vaTransform stays nil ⇒ no valence/arousal here.
        return FusionOutput(
            namedState: nil,                          // the hub sets the name once latched
            valence: nil, arousal: nil,               // F7 does NOT move the published V/A
            contributions: [.face: faceComponent, .interaction: frictionComponent],
            confidence: confidence,
            score: score,
            evidence: evidence
        )
    }

    // MARK: Disambiguation ladder (§6.6 — a minimal reuse of the F1 widget)

    /// F7's 2-rung ladder: L0 the negative Persona lean → L1 the interaction-friction
    /// conjunction that surfaces "frustration (task friction)". Proves the §6.6 widget is
    /// construct-agnostic; F7 can grow richer rungs later with no rework. `nil` output
    /// (starved / off) ⇒ no ladder.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep] {
        guard let out = state.output else { return [] }
        let negLean = (out.contributions[.face] ?? 0) > 0
        return [
            LadderStep(id: 0, claim: HonestyPhrases.frustrationLadderL0,
                       status: negLean ? .resolved : .ambiguous(HonestyPhrases.frustrationLadderL0Fork)),
            LadderStep(id: 1, claim: HonestyPhrases.frustrationLadderL1,
                       status: state.isActive ? .resolved : .ambiguous(HonestyPhrases.frustrationLadderL1Fork))
        ]
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

#endif
