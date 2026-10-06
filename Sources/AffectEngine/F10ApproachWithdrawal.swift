//
//  F10ApproachWithdrawal.swift
//  AffectLens
//
//  F10 — APPROACH ⇄ WITHDRAWAL (US-D14b, PRD v2 §4.2 F10 / §4.3). The anger-vs-sadness
//  TIE-BREAKER made into its own coupled axis. Anchor: Harmon-Jones & Allen 1998; Carver &
//  Harmon-Jones 2009 — motivational direction is DISSOCIABLE from valence: anger is
//  negative-valence but APPROACH-motivated, while sadness / shame are WITHDRAWAL. When the
//  face reads "negative" but can't say WHICH, motor-energy + head-orientation split anger
//  (approach) from sadness (withdrawal) — the branch valence alone cannot make (§4.3).
//
//  ONE COUPLED AXIS (mirror F3). Approach (+) ⇄ withdrawal (−), NEVER two meters — a
//  `CoupledPoleLatch` guarantees only ONE pole (or neutral) ever latches. The axis is the
//  reusable `MotivationalDirection` primitive (§4.3) over the head's motor + orientation
//  (hands add an expansive-gesture vote when live). Head-only motor is the MVV — with only
//  the head lens on, motor-energy alone carries the axis (documented); hands ENHANCE it.
//
//  THE tanh SCALE (documented). `MotivationalDirection` squashes through `tanh`, so a single
//  strong cue lands near ±0.33 and two aligned cues near ±0.65 — never saturating. So F10's
//  pole-enter (0.28) sits well BELOW F3's raw-axis 0.45: it is calibrated to the squashed
//  scale, where a lone strong cue must be able to lean the axis.
//
//  THE CONTEXT-SENSITIVE LEAN (§4.3, in the NARRATION, never the chip). The chip shows the
//  bare DIRECTION ("movement leans approach / withdrawal"). The insight NARRATION, which sees
//  the face reading, adds the tie-break LEAN only when the face is currently NEGATIVE:
//  approach ⇒ "leans displeasure / anger-side", withdrawal ⇒ "leans dejection-side" — LEANS
//  only, never a discrete label (the F4 lean vocabulary spirit). A neutral / positive face
//  gets direction language only ("movement leans approach / engagement").
//
//  DIMENSIONAL VETO. F10 is a NAMED POLE + insight + a bipolar bar + ladder only. It does NOT
//  move the published valence/arousal (`FusionOutput.valence`/`arousal` stay nil; the hub
//  leaves `EmotionEngine.vaTransform` nil). Off by default; ceiling ≤ 0.6.
//

#if os(visionOS) || os(macOS)

import Foundation

/// F10 Approach ⇄ Withdrawal — the Hd×H coupled DIRECTION axis (PRD §4.2 / §4.3). A
/// `nonisolated` value type: its metadata, `fuse` math, pole labels, and ladder builder are
/// pure and self-testable off the main actor. Conforms to `CoupledFusionMode` so the hub
/// drives its two-pole latch.
nonisolated struct F10ApproachWithdrawalMode: CoupledFusionMode {

    // MARK: Identity / honesty metadata

    var id: String { ConstructID.approachWithdrawal }   // toggle key: fusion.f10-approach-withdrawal.enabled
    var title: String { "Approach ⇄ Withdrawal" }
    /// Head is the MVV — the head channel's motor + orientation carry the axis on their own
    /// (§4.3: the two innate displays are head-defined). Hands ENHANCE it with an expansive-
    /// gesture vote when the aura is open. So `requires` is [.head]; hands join automatically.
    var requires: Set<Channel> { [.head] }

    var rationale: String { HonestyPhrases.approachWithdrawalRationale }
    var confound: String { HonestyPhrases.approachWithdrawalConfound }
    var citation: String? { "Harmon-Jones & Allen 1998" }
    /// A coarse behavioral DIRECTION read (head orientation is not gaze; motor is a proxy), so
    /// the ceiling is low — 0.6, matching F1; the head lens's own modest confidence keeps the
    /// fused value well below it in practice.
    var confidenceCeiling: Double { 0.6 }

    // MARK: Two-pole latch (the ONE coupled meter)

    /// The pole-latch band + dwell (~15 Hz ticks). `enter 0.28 / exit 0.16` is a real band on
    /// the tanh-squashed direction scale (a single strong cue ≈ 0.33 must be able to enter);
    /// `enterDwell 30 ≈ 2 s` demands the lean PERSIST; `exitDwell 15 ≈ 1 s` (exitDwell <
    /// enterDwell buys the neutral dead band on a hard approach⇄withdrawal flip).
    static let poleEnter = 0.28
    static let poleExit = 0.16
    static let poleEnterDwell = 30
    static let poleExitDwell = 15

    nonisolated var coupledLatch: CoupledPoleLatch {
        CoupledPoleLatch(enter: Self.poleEnter, exit: Self.poleExit,
                         enterDwellTicks: Self.poleEnterDwell, exitDwellTicks: Self.poleExitDwell)
    }

    /// The surfaced pole label — bare DIRECTION language (the tie-break LEAN lives in the
    /// narration, which sees the face). `+` approach, `−` withdrawal, `0` ⇒ nil.
    nonisolated func poleName(forSign sign: Int) -> String? {
        if sign > 0 { return HonestyPhrases.approachWithdrawalApproachState }
        if sign < 0 { return HonestyPhrases.approachWithdrawalWithdrawalState }
        return nil
    }

    // MARK: Tunables (documented — all in the readings' own units)

    /// A gesture RATE (bursts/min) that normalizes to a full expansiveness cue for the
    /// motivational-direction primitive (only used when the hands lens is live — the enhancer).
    static let gestureRateScale = 6.0
    /// |axis| beyond which the ladder's L0 (direction) rung resolves.
    static let leanDeadband = 0.15

    // MARK: Fuse

    /// Fuse the current readings into F10's signed DIRECTION axis, or `nil` when the head lens
    /// isn't producing a reading this tick (never a fabricated read — §4.2). Reads `.head`
    /// (required — motor + `dominanceLean`) and, when live, `.hands` (`gestureRate` — the
    /// enhancer). `score == |axis|`; the pole is latched downstream by the hub's `CoupledPoleLatch`.
    func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
        guard let head = readings[.head], head.availability != .unavailable else { return nil }

        // MOTOR — the head's arousal magnitude (0…1); HEAD LEAN — the signed dominance-lean
        // (+ head-back/level, − head-down/turned-away); GESTURE — the hands' expansiveness,
        // when live (the enhancer). Missing cues degrade gracefully in `MotivationalDirection`.
        let headMotor = head.arousal?.value
        let headLean = head.features[.dominanceLean]
        let gestureRate = readings[.hands].flatMap { h -> Double? in
            guard h.availability != .unavailable, let r = h.features[.gestureRate] else { return nil }
            return clamp01(r / Self.gestureRateScale)
        }
        let direction = MotivationalDirection.direction(motorEnergy: headMotor, headLean: headLean, gestureRate: gestureRate)
        let score = abs(direction)

        // CONTRIBUTIONS — the legible-fusion audit. `.head` = |axis| (its overall say); `.hands`
        // = the gesture enhancer when present.
        var contributions: [Channel: Double] = [.head: score]
        if let g = gestureRate { contributions[.hands] = g }

        // EVIDENCE — cite only present, contributing signals. Head-motion energy is always the
        // MVV; the head-orientation (pitch/yaw the dominance-lean derives from) when it leans;
        // the gesture rate when hands enhance.
        var evidence: [SignalRef] = [.headMotionEnergy]
        if (headLean ?? 0) != 0 { evidence.append(.headPitch); evidence.append(.headYaw) }
        if gestureRate != nil { evidence.append(.gestureRate) }

        // CONFIDENCE — the head lens's own (deliberately modest) confidence, capped. Epistemic.
        let headConf = head.arousal?.confidence ?? head.quality
        let confidence = min(confidenceCeiling, headConf)

        return FusionOutput(
            namedState: nil,                    // the hub names the POLE once latched
            valence: nil, arousal: nil,         // F10 does NOT move the published V/A
            contributions: contributions,
            confidence: confidence,
            score: score,
            evidence: evidence,
            axis: direction
        )
    }

    // MARK: Disambiguation ladder (§6.6 — a minimal coupled ladder)

    /// F10's rungs for the current published state. Delegates to the pure
    /// `ladder(output:isActive:)` so the mapping is self-testable without a hub.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep] {
        Self.ladder(output: state.output, isActive: state.isActive)
    }

    /// Pure builder: the mode's live state → a minimal 2-rung ladder. L0 direction present →
    /// the approach / withdrawal verdict (or the neutral dead-band fork). `nil` output ⇒ none.
    static func ladder(output: FusionOutput?, isActive: Bool) -> [LadderStep] {
        guard let out = output else { return [] }
        let axis = out.axis ?? 0
        let leaning = abs(axis) > leanDeadband

        var steps: [LadderStep] = []
        func add(_ claim: String, _ status: LadderStep.Status) {
            steps.append(LadderStep(id: steps.count, claim: claim, status: status))
        }

        add(HonestyPhrases.approachWithdrawalL0,
            leaning ? .resolved : .ambiguous(HonestyPhrases.approachWithdrawalL0Fork))
        if isActive {
            add(axis >= 0 ? HonestyPhrases.approachWithdrawalApproachState
                          : HonestyPhrases.approachWithdrawalWithdrawalState, .resolved)
        } else {
            add(HonestyPhrases.approachWithdrawalVerdictNeutral,
                .ambiguous(HonestyPhrases.approachWithdrawalVerdictNeutralFork))
        }
        return steps
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

#endif
