//
//  F8Dominance.swift
//  AffectLens
//
//  F8 — DOMINANCE DISPLAY (US-D14b, PRD v2 §4.2 F8 / §3.4). A slow bipolar POSTURE-display
//  axis on the head's dominance-lean: expansion (+) ⇄ contraction / withdrawal (−). Anchor:
//  Tracy & Matsumoto 2008 — the two innate nonverbal displays (head-back + expanded =
//  high-dominance / expansion; head-down + turned-away = withdrawal / submission).
//
//  DISPLAY LANGUAGE ONLY (never soften it). The surfaced states are "expansion display" and
//  "contracted / withdrawn display" — a description of a POSTURE on the DOMINANCE axis, NEVER
//  a felt emotion. We read HEAD ORIENTATION, not gaze, and NOT the torso (§2.2 / §3.4), so
//  the confidence ceiling is low (≤ 0.5) and the rationale carries the gaze + torso hedges.
//  NO nod/shake meaning, NO head-tilt dictionary (refused list §4.5 #4/#5).
//
//  ONE COUPLED AXIS (mirror F3). A `CoupledPoleLatch` guarantees only ONE pole (or neutral)
//  ever latches. The axis is the head's gaze-gated `dominanceLean` ∈ [−1, 1] (US-D13b), which
//  is already the innate-display formula (head-back+level ⇒ +, head-down+turned-away ⇒ −).
//
//  "SUSTAINED" = THE LATCH WINDOW (documented). F8 is a SLOW axis: the "sustained
//  dominance-lean" requirement is enforced by the coupled latch's LONG enter dwell (~3 s at
//  the ~15 Hz fan-out) — the same mechanism F3 uses for "sustained" blink trends, so a
//  fleeting head-back tilt can't trip it. (A dedicated per-tick median filter over the lean
//  is a deferred refinement; the dwell IS the window today.)
//
//  HANDS ENHANCE (the immersive tier). When the aura is open, an expansive GESTURE rate
//  CORROBORATES the EXPANSION side only (an expansion display with active, expansive hands is
//  more trustworthy); it nudges confidence, never the axis — a head-only display is never
//  manufactured by the hands.
//
//  DIMENSIONAL VETO. F8 is a NAMED POLE + insight + a bipolar bar + ladder only. It does NOT
//  move the published valence/arousal (`FusionOutput.valence`/`arousal` stay nil; the hub
//  leaves `EmotionEngine.vaTransform` nil). Off by default; ceiling ≤ 0.5.
//

#if os(visionOS) || os(macOS)

import Foundation

/// F8 Dominance display — the Hd×H coupled expansion ⇄ contraction axis (PRD §4.2 / §3.4). A
/// `nonisolated` value type: its metadata, `fuse` math, pole labels, and ladder builder are
/// pure and self-testable off the main actor. Conforms to `CoupledFusionMode`.
nonisolated struct F8DominanceMode: CoupledFusionMode {

    // MARK: Identity / honesty metadata

    var id: String { ConstructID.dominance }        // toggle key: fusion.f8-dominance.enabled
    var title: String { "Dominance display" }
    /// The head channel's gaze-gated dominance-lean is the whole axis (§3.4); hands
    /// CORROBORATE the expansion side when the aura is open. So `requires` is [.head].
    var requires: Set<Channel> { [.head] }

    var rationale: String { HonestyPhrases.dominanceRationale }
    var confound: String { HonestyPhrases.dominanceConfound }
    var citation: String? { "Tracy & Matsumoto 2008" }
    /// A head-ORIENTATION display, not gaze and not the torso — the ceiling is deliberately
    /// low (0.5): this is as sure as a head-only dominance read can honestly be.
    var confidenceCeiling: Double { 0.5 }

    // MARK: Two-pole latch (the ONE coupled meter — SLOW)

    /// The pole-latch band + dwell (~15 Hz ticks). `enter 0.40 / exit 0.25` is a real band on
    /// the [−1, 1] dominance-lean (which reaches ±1 at the pose scales); `enterDwell 45 ≈ 3 s`
    /// is the LONG "slow axis" window — a fleeting head-back can't trip it; `exitDwell 20 ≈
    /// 1.3 s` (exitDwell < enterDwell buys the neutral dead band on a flip).
    static let poleEnter = 0.40
    static let poleExit = 0.25
    static let poleEnterDwell = 45
    static let poleExitDwell = 20

    nonisolated var coupledLatch: CoupledPoleLatch {
        CoupledPoleLatch(enter: Self.poleEnter, exit: Self.poleExit,
                         enterDwellTicks: Self.poleEnterDwell, exitDwellTicks: Self.poleExitDwell)
    }

    /// The surfaced pole label — DISPLAY language only. `+` expansion, `−` contraction, `0` ⇒ nil.
    nonisolated func poleName(forSign sign: Int) -> String? {
        if sign > 0 { return HonestyPhrases.dominanceExpansionState }
        if sign < 0 { return HonestyPhrases.dominanceContractionState }
        return nil
    }

    // MARK: Tunables (documented — all in the readings' own units)

    /// A gesture RATE (bursts/min) that normalizes to a full expansive-gesture corroboration
    /// (only used when the hands lens is live — the enhancer).
    static let gestureRateScale = 6.0
    /// How much a full expansive-gesture corroboration nudges confidence on the EXPANSION side.
    static let handsCorroboration = 0.2
    /// |axis| beyond which the ladder's L0 (a clear dominance lean) rung resolves.
    static let leanDeadband = 0.15

    // MARK: Fuse

    /// Fuse the current readings into F8's signed dominance axis, or `nil` when the head lens
    /// isn't producing a reading this tick (never a fabricated read — §4.2). Reads `.head`
    /// (required — the `dominanceLean` feature) and, when live, `.hands` (`gestureRate` — the
    /// expansion-side corroboration). `score == |axis|`; the pole is latched by the hub.
    func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
        guard let head = readings[.head], head.availability != .unavailable else { return nil }

        // THE AXIS — the head's gaze-gated dominance-lean (already the innate-display formula,
        // + expansion / − contraction). Clamped for safety; `score == |axis|`.
        let axis = max(-1, min(1, head.features[.dominanceLean] ?? 0))
        let score = abs(axis)

        // HANDS ENHANCE — an expansive gesture rate CORROBORATES the expansion side only.
        var handsEnhance = 0.0
        if let hands = readings[.hands], hands.availability != .unavailable {
            handsEnhance = clamp01((hands.features[.gestureRate] ?? 0) / Self.gestureRateScale)
        }

        // CONTRIBUTIONS — the legible-fusion audit. `.head` = |axis|; `.hands` = the enhancer.
        var contributions: [Channel: Double] = [.head: score]
        if handsEnhance > 0 { contributions[.hands] = handsEnhance }

        // EVIDENCE — cite the head-orientation signals the dominance-lean derives from; add the
        // gesture rate when hands corroborate.
        var evidence: [SignalRef] = [.headPitch, .headYaw]
        if handsEnhance > 0 { evidence.append(.gestureRate) }

        // CONFIDENCE — the head channel's tracking quality, capped at the low ceiling (the
        // epistemic limit is the gaze/torso blindness, not tracking). Hands corroborate the
        // EXPANSION side only. Epistemic — kept SEPARATE from the axis magnitude.
        let corroboration = axis >= 0 ? (1 + Self.handsCorroboration * handsEnhance) : 1
        let confidence = min(confidenceCeiling, head.quality * corroboration)

        return FusionOutput(
            namedState: nil,                    // the hub names the POLE once latched
            valence: nil, arousal: nil,         // F8 does NOT move the published V/A
            contributions: contributions,
            confidence: confidence,
            score: score,
            evidence: evidence,
            axis: axis
        )
    }

    // MARK: Disambiguation ladder (§6.6 — a minimal coupled ladder)

    /// F8's rungs for the current published state. Delegates to the pure
    /// `ladder(output:isActive:)` so the mapping is self-testable without a hub.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep] {
        Self.ladder(output: state.output, isActive: state.isActive)
    }

    /// Pure builder: the mode's live state → a minimal 2-rung ladder. L0 a clear dominance
    /// lean → the expansion / contraction display verdict (or the neutral fork). `nil` ⇒ none.
    static func ladder(output: FusionOutput?, isActive: Bool) -> [LadderStep] {
        guard let out = output else { return [] }
        let axis = out.axis ?? 0
        let leaning = abs(axis) > leanDeadband

        var steps: [LadderStep] = []
        func add(_ claim: String, _ status: LadderStep.Status) {
            steps.append(LadderStep(id: steps.count, claim: claim, status: status))
        }

        add(HonestyPhrases.dominanceL0,
            leaning ? .resolved : .ambiguous(HonestyPhrases.dominanceL0Fork))
        if isActive {
            add(axis >= 0 ? HonestyPhrases.dominanceExpansionState
                          : HonestyPhrases.dominanceContractionState, .resolved)
        } else {
            add(HonestyPhrases.dominanceVerdictNeutral,
                .ambiguous(HonestyPhrases.dominanceVerdictNeutralFork))
        }
        return steps
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

#endif
