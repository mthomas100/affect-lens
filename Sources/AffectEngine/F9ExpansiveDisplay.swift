//
//  F9ExpansiveDisplay.swift
//  AffectLens
//
//  F9 — EXPANSIVE / HIGH-DOMINANCE DISPLAY (US-D14b, PRD v2 §4.2 F9 / §4.5 #7). A specific
//  DISPLAY on the DOMINANCE axis — a STRONG, sustained head-back expansion with a non-negative
//  face — NOT the felt emotion "pride". Anchor: Tracy & Matsumoto 2008 (the innate
//  high-dominance display). "pride" appears ONLY inside the rationale, as a hedged gloss.
//
//  THE HONESTY LAW (never soften it). The surfaced state is "expansive high-dominance display
//  (head-only)" — labelled head-only because WE CAN'T SEE YOUR TORSO (the expansive posture is
//  a whole-body display; we read the head alone, §2.2 / §3.4). And there is NO power-pose
//  CAUSAL claim: this never says an expansive pose CAUSES confidence, dominance, or hormone
//  changes (Carney 2016 disavowal; refused list §4.5 #7) — it reports the display, nothing more.
//
//  LOW BASE-RATE ⇒ CONSERVATIVE (documented). A genuine high-dominance display is RARE, so F9
//  is deliberately hard to trip: it fires only on a STRONG expansion (a HIGHER lean threshold
//  than F8's ordinary dominance axis) held for a long enter dwell. The higher bar is asserted
//  numerically against F8 in the self-tests (`enter` > `F8.poleEnter`).
//
//  THE CONJUNCTION. Strong sustained expansion AND a non-negative face — a geometric-style
//  gate: a clearly NEGATIVE face (an angry head-back is not this display) drives the score to
//  0. Hands ENHANCE (an expansive gesture corroborates), never manufacture.
//
//  DIMENSIONAL VETO. F9 is a NAMED STATE + insight + ladder only. It does NOT move the
//  published valence/arousal (`FusionOutput.valence`/`arousal` stay nil; the hub leaves
//  `EmotionEngine.vaTransform` nil). Off by default; ceiling ≤ 0.5.
//

#if os(visionOS) || os(macOS)

import Foundation

/// F9 Expansive display — the Hd×H×F windowed construct (PRD §4.2). A `nonisolated` value
/// type: its metadata, `fuse` math, and ladder builder are pure and self-testable off the
/// main actor, per the project's MainActor-default regime.
nonisolated struct F9ExpansiveDisplayMode: FusionMode {

    // MARK: Identity / honesty metadata

    var id: String { ConstructID.expansiveDisplay }     // toggle key: fusion.f9-expansive-display.enabled
    var title: String { "Expansive display (head-only)" }
    /// The head's expansion lean × a non-negative face is the construct; hands ENHANCE when
    /// the aura is open. So `requires` is [.face, .head].
    var requires: Set<Channel> { [.face, .head] }

    var rationale: String { HonestyPhrases.expansiveDisplayRationale }
    var confound: String { HonestyPhrases.expansiveDisplayConfound }
    var citation: String? { "Tracy & Matsumoto 2008" }
    /// A head-only display (torso-blind, gaze-blind) — the ceiling is low, 0.5.
    var confidenceCeiling: Double { 0.5 }

    // MARK: Hysteresis (documented band + dwell — CONSERVATIVE for the low base-rate)

    /// The HIGHER bar (low base-rate ⇒ conservative): `enter 0.60` sits well ABOVE F8's
    /// ordinary-dominance `poleEnter` (0.40), so F8-grade expansion does NOT fire F9 (asserted
    /// numerically in the self-tests); `exit 0.40` is a real band; `enterDwell 45 ≈ 3 s` demands
    /// a sustained STRONG expansion; `exitDwell 20 ≈ 1.3 s`.
    static let expansionEnter = 0.60
    static let expansionExit = 0.40

    var hysteresis: ConstructHysteresis {
        ConstructHysteresis(enter: Self.expansionEnter, exit: Self.expansionExit,
                            enterDwellTicks: 45, exitDwellTicks: 20)
    }

    // MARK: Tunables (documented — all in the readings' own units)

    /// A Persona valence within ±`valenceDeadband` reads "near-neutral" — the non-negative
    /// gate is fully open there.
    static let valenceDeadband = 0.15
    /// Negativity past the deadband that drives the non-negative gate to 0 — by v ≈ −0.5 the
    /// face is clearly negative (an angry head-back is NOT this display), so the score gates off.
    static let valenceSpan = 0.35
    /// A gesture RATE (bursts/min) that normalizes to a full expansive-gesture corroboration
    /// (only when hands are live — the enhancer).
    static let gestureRateScale = 6.0
    /// How much a full expansive-gesture corroboration nudges confidence.
    static let handsCorroboration = 0.2
    /// The expansion-strength contribution at/above which the ladder's L0 rung resolves.
    static let expansionResolvedThreshold = 0.50
    /// The face-gate contribution at/above which the ladder's L1 (non-negative face) resolves.
    static let faceResolvedThreshold = 0.50
    /// A construct is at most as trustworthy as its weakest channel (mirror F1/F7).
    static let confidenceDamping = 0.9

    // MARK: Fuse

    /// Fuse the current readings into F9's expansion-display score, or `nil` when a required
    /// channel isn't live this tick (never a fabricated read — §4.2). Reads `.face` + `.head`
    /// (required) and, when live, `.hands` (`gestureRate` — the enhancer). Pure over inputs.
    func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
        guard let face = readings[.face], face.availability != .unavailable,
              let head = readings[.head], head.availability != .unavailable
        else { return nil }

        // EXPANSION — only the positive (head-back + level) side of the dominance-lean.
        let expansion = clamp01(max(0, head.features[.dominanceLean] ?? 0))

        // NON-NEGATIVE FACE GATE — fully open (1) for a non-negative face, ramping to 0 as the
        // face goes clearly negative (an angry head-back is NOT an expansive display).
        let v = face.valence?.value ?? 0
        let negativity = max(0, -v)
        let faceGate = clamp01(1 - (negativity - Self.valenceDeadband) / Self.valenceSpan)

        // SCORE — the conjunction: strong expansion AND a non-negative face. Either at 0 ⇒ 0.
        let score = expansion * faceGate

        // HANDS ENHANCE — an expansive gesture rate corroborates (confidence only).
        var handsEnhance = 0.0
        if let hands = readings[.hands], hands.availability != .unavailable {
            handsEnhance = clamp01((hands.features[.gestureRate] ?? 0) / Self.gestureRateScale)
        }

        // CONTRIBUTIONS — the legible-fusion audit + the ladder's backing scalars.
        var contributions: [Channel: Double] = [.head: expansion, .face: faceGate]
        if handsEnhance > 0 { contributions[.hands] = handsEnhance }

        // EVIDENCE — the head-back orientation + the non-negative face; the gesture when it corroborates.
        var evidence: [SignalRef] = [.headPitch, .valence]
        if handsEnhance > 0 { evidence.append(.gestureRate) }

        // CONFIDENCE — min of the required channels, damped, capped at the low ceiling (torso-
        // /gaze-blindness is the epistemic limit). Hands corroborate. Kept SEPARATE from score.
        let faceConf = face.valence?.confidence ?? 0
        let base = min(faceConf, head.quality) * Self.confidenceDamping
        let confidence = min(confidenceCeiling, base * (1 + Self.handsCorroboration * handsEnhance))

        return FusionOutput(
            namedState: HonestyPhrases.expansiveDisplayState,   // "…head-only" — surfaced by the hub on latch
            valence: nil, arousal: nil,                          // F9 does NOT move the published V/A
            contributions: contributions,
            confidence: confidence,
            score: score,
            evidence: evidence
        )
    }

    // MARK: Disambiguation ladder (§6.6 — the honesty widget)

    /// F9's rungs for the current published state. Delegates to the pure
    /// `ladder(output:isActive:)` so the mapping is self-testable without a hub.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep] {
        Self.ladder(output: state.output, isActive: state.isActive)
    }

    /// Pure builder: the mode's live state → the narrowing ladder. L0 strong expansion → L1
    /// non-negative face → the head-only display verdict, then a PERMANENT ruled-out rung
    /// refusing the power-pose causal / torso claims (greyed + struck). `nil` ⇒ no ladder.
    static func ladder(output: FusionOutput?, isActive: Bool) -> [LadderStep] {
        guard let out = output else { return [] }
        let strongExpansion = (out.contributions[.head] ?? 0) >= expansionResolvedThreshold
        let faceOK = (out.contributions[.face] ?? 0) >= faceResolvedThreshold

        var steps: [LadderStep] = []
        func add(_ claim: String, _ status: LadderStep.Status) {
            steps.append(LadderStep(id: steps.count, claim: claim, status: status))
        }

        add(HonestyPhrases.expansiveDisplayL0,
            strongExpansion ? .resolved : .ambiguous(HonestyPhrases.expansiveDisplayL0Fork))
        add(HonestyPhrases.expansiveDisplayL1,
            faceOK ? .resolved : .ambiguous(HonestyPhrases.expansiveDisplayL1Fork))
        add(isActive ? HonestyPhrases.expansiveDisplayVerdict : HonestyPhrases.expansiveDisplayVerdictNotYet,
            isActive ? .resolved : .ambiguous(HonestyPhrases.expansiveDisplayVerdictNotYetFork))
        add(HonestyPhrases.expansiveDisplayRuledOut,
            .ruledOut(HonestyPhrases.expansiveDisplayRuledOutReason))
        return steps
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

#endif
