//
//  F4FrownHeadDown.swift
//  AffectLens
//
//  F4 — FROWN + HEAD-DOWN DISAMBIGUATION (THE DESIGN NOTES' WORKED EXAMPLE, US-D14a, PRD v2
//  §4.2 F4 / §4.6 / §6.6). The construct whose OUTPUT IS A LEAN + A LADDER, NEVER A LABEL:
//  a lowered brow is ambiguous — effort, displeasure, or dejection — and a head-down tilt
//  can FAKE the lowered brow entirely (the "AU4 imposter", Witkower & Tracy 2019/2020). So
//  F4 does not assert an emotion; it runs a progressive-narrowing LADDER and surfaces a
//  hedged LEAN. Anchor: Witkower & Tracy 2019/2020; Harmon-Jones & Allen 1998 (§4.3).
//
//  THE LADDER (the reusable §6.6 UX template):
//    L0 PITCH-CORRECT — INHERITED. The engine already strips the geometric AU4 the head-down
//       tilt fakes upstream (US-A0; the enriched face reading's `au4` is ALREADY corrected).
//       This rung REFLECTS that: "brow looks lowered, but your head is down — correcting."
//    L1 BROW MORPHOLOGY — AU1+AU15 ⇒ sadness/dejection lean; AU4+(AU5|AU7) ⇒ displeasure/
//       anger lean; AU4 ALONE ⇒ effort lean.
//    L2 MOTIVATIONAL DIRECTION (§4.3, the reusable `MotivationalDirection` primitive) —
//       approach ⇒ displeasure-approach; withdrawal ⇒ dejection-withdrawal; weak ⇒ fork.
//    L3 HEAD-ORIENTATION PROXY — head toward content ⇒ leans focused effort; head DOWN-and-
//       turned-AWAY ⇒ leans withdrawal. ALWAYS LOW-CONFIDENCE: we read head orientation, not
//       gaze, so a straight look-DOWN at content stays unresolved (the killer demo — it does
//       NOT flip to anger). PRD-mandated copy: "we can't see your gaze — may stay unresolved."
//    L4 BLINK / LOAD — a light blink-suppression read (eyes, when live) supports effort.
//    L5 TIME-ON-TASK / FRICTION — session minutes + interaction corrections frame long-
//       session effort.
//    + a PERMANENT ruled-out rung: a single "anger" label from a lowered brow — refused,
//      because the head-down tilt fakes it (corrected at step 0).
//
//  HONESTY LAW. The namedState is one of four hedged LEANS, NEVER a discrete emotion label.
//  The shame-vs-concentration split stays UNRESOLVED (gaze-blind); "shame" appears only as a
//  hedged gloss in the rationale copy, never in a live state name. Confidence is LOW-ceilinged
//  (≤ 0.5): this is a disambiguation aid, not a verdict. vaTransform stays nil; off by default.
//
//  QUIESCENCE. With no lowered brow to disambiguate (corrected AU4 at/below the trigger) F4
//  produces NO output — the row shows just its rationale, no ladder, no chip.
//

#if os(visionOS) || os(macOS)

import Foundation

/// F4 Frown + head-down — the F×Hd windowed disambiguation construct (PRD §4.6). A
/// `nonisolated` value type: its metadata, `fuse` math, lean logic, and ladder builder are
/// pure and self-testable off the main actor, per the project's MainActor-default regime.
nonisolated struct F4FrownHeadDownMode: FusionMode {

    // MARK: Identity / honesty metadata

    var id: String { ConstructID.frownHeadDown }        // toggle key: fusion.f4-frown-head-down.enabled
    var title: String { "Frown + head-down (disambiguation)" }
    /// Windowed MVV is face × head (§4.6); eyes/interaction ENHANCE steps L4-L5 when live.
    var requires: Set<Channel> { [.face, .head] }

    var rationale: String { HonestyPhrases.frownHeadDownRationale }
    var confound: String { HonestyPhrases.frownHeadDownConfound }
    var citation: String? { "Witkower & Tracy 2019/2020" }
    /// A gaze-blind disambiguation AID, never a verdict — the ceiling is deliberately low.
    var confidenceCeiling: Double { 0.5 }

    // MARK: Hysteresis (documented band + dwell, ~15 Hz ticks)

    /// A lean surfaces only once the frown PERSISTS (a momentary knit can't trip it): enter
    /// 0.40 / exit 0.25 is a real band; enter-dwell 30 ≈ 2 s; exit-dwell 15 ≈ 1 s.
    var hysteresis: ConstructHysteresis {
        ConstructHysteresis(enter: 0.40, exit: 0.25, enterDwellTicks: 30, exitDwellTicks: 15)
    }

    // MARK: Tunables (documented — all in the readings' own units)

    /// Corrected-AU4 (brow-lowerer, already baseline-relative + pitch-corrected) at/below
    /// which there is no lowered brow to disambiguate — F4 stays QUIESCENT (no output).
    static let au4Trigger = 0.15
    /// Head pitch Δ (rad, ~8.6°) BELOW neutral counted as "head down" (matches the US-A0
    /// pitch-correction deadband). Convention: − pitch = head down (`HeadChannel`).
    static let pitchDownThreshold = 0.15
    /// |head yaw Δ| (rad, ~11°) beyond which the head is "turned away" — the second half of
    /// the down-AND-away withdrawal geometry (a straight look-down does NOT clear this).
    static let yawAwayThreshold = 0.20
    /// A gesture RATE (bursts/min) that normalizes to a full expansiveness cue for the
    /// motivational-direction primitive (only used when the hands lens is live).
    static let gestureRateScale = 6.0
    /// A blink-rate SUPPRESSION (Δ/min below resting) that maps to a full L4 load cue.
    static let blinkSuppressionScale = 8.0
    /// |motivational direction| beyond which L2 resolves to approach / withdrawal.
    static let directionDeadband = 0.15
    /// A morphology-arm strength at/above which L1 resolves to that arm.
    static let morphoResolveThreshold = 0.20
    /// Minimum winning lean-score to name a lean at all (below it ⇒ ambiguous).
    static let leanFloor = 0.20
    /// Minimum margin the top lean-score must beat the runner-up by (else ⇒ ambiguous).
    static let ambiguityMargin = 0.12
    /// Session minutes at/above which L5 reads a long-session effort framing.
    static let longSessionMinutes = 5.0
    /// Confidence damping applied to the face confidence (before the ≤ 0.5 ceiling).
    static let confidenceDamping = 0.7
    /// Small lean-score bonuses for the low-confidence L3 head-orientation and L4 blink cues.
    static let orientationBonus = 0.20
    static let blinkSupportWeight = 0.40

    // MARK: Fuse

    /// Fuse the current readings into F4's lean + the ladder's backing scalars, or `nil` when
    /// the required face/head signals aren't both present, OR when there is no lowered brow to
    /// disambiguate (corrected AU4 ≤ trigger ⇒ QUIESCENT — no fabricated read, §4.2). Reads
    /// `.face` (enriched with au1/au4/au5/au7/au15) + `.head` (required) and, when live,
    /// `.hands` / `.eyes` / `.interaction` / `.context` (the L2-L5 enhancers). Pure over inputs.
    func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
        guard let face = readings[.face], face.availability != .unavailable,
              let head = readings[.head], head.availability != .unavailable
        else { return nil }

        // TRIGGER — a lowered brow (corrected AU4) must be present, else stay quiescent.
        let au4 = face.features[.au4] ?? 0
        guard au4 > Self.au4Trigger else { return nil }

        let au1 = face.features[.au1] ?? 0
        let au5 = face.features[.au5] ?? 0
        let au7 = face.features[.au7] ?? 0
        let au15 = face.features[.au15] ?? 0

        // L1 BROW MORPHOLOGY arms (AU4 is the given; the companions discriminate). Which arm
        // fired is recovered in `ladder(output:)` from the cited AU evidence, so the two arm
        // strengths feed the lean-scores here and the ladder reads them back from `evidence`.
        let angerArm = min(au4, max(au5, au7))                       // AU4 + lid ⇒ displeasure/anger
        let sadnessArm = min(au1, au15)                             // AU1 + AU15 ⇒ dejection
        let companions = max(au1, au15, au5, au7)
        let effortArm = max(0, au4 - companions)                    // AU4 alone ⇒ effort

        // L2 MOTIVATIONAL DIRECTION (§4.3 primitive) — head/hand motor + head lean + gesture.
        let headMotor = head.arousal?.value
        let handMotor = readings[.hands].flatMap { $0.availability != .unavailable ? $0.arousal?.value : nil }
        let motor: Double? = [headMotor, handMotor].compactMap { $0 }.max()
        let headLean = head.features[.dominanceLean]
        let gestureRate = readings[.hands].flatMap { h -> Double? in
            guard h.availability != .unavailable, let r = h.features[.gestureRate] else { return nil }
            return min(1, max(0, r / Self.gestureRateScale))
        }
        let direction = MotivationalDirection.direction(motorEnergy: motor, headLean: headLean, gestureRate: gestureRate)

        // L3 HEAD-ORIENTATION proxy (always low-confidence — we read orientation, not gaze).
        let pitchDelta = head.features[.headPitch] ?? 0
        let yawDelta = head.features[.headYaw] ?? 0
        let headDown = pitchDelta < -Self.pitchDownThreshold
        let turnedAway = abs(yawDelta) > Self.yawAwayThreshold
        let downAndAway = headDown && turnedAway
        let towardContent = !headDown                              // level / toward content

        // L4 BLINK / LOAD — a light blink-suppression read from the eyes lens, when live.
        let eyesLive = readings[.eyes].map { $0.availability != .unavailable } ?? false
        let blinkSuppression: Double = {
            guard eyesLive, let d = readings[.eyes]?.features[.blinkRate] else { return 0 }
            return min(1, max(0, -d) / Self.blinkSuppressionScale)
        }()

        // L5 TIME-ON-TASK / FRICTION — session minutes (context) + interaction corrections.
        let minutes = max(0, readings[.context]?.features[.sessionMinutes] ?? 0)
        let interactionLive = readings[.interaction].map { $0.availability != .unavailable } ?? false
        let cancelRise = interactionLive ? max(0, readings[.interaction]?.features[.cancelRate] ?? 0) : 0

        // THE LEAN — combine the arms, the motivational direction, and the low-confidence
        // orientation / blink support into three competing lean-scores; a clear winner names
        // the lean, a tie or an all-weak field stays honestly ambiguous.
        let effortScore = effortArm + Self.blinkSupportWeight * blinkSuppression + (towardContent ? Self.orientationBonus : 0)
        let approachScore = angerArm + max(0, direction)
        let withdrawalScore = sadnessArm + max(0, -direction) + (downAndAway ? Self.orientationBonus : 0)
        let lean = decideLean(effort: effortScore, approach: approachScore, withdrawal: withdrawalScore)

        // SCORE — the trigger-normalized frown strength, so a persistent lowered brow latches
        // (surfacing the lean, whatever it is — including "ambiguous"), independent of WHICH
        // lean won. Kept SEPARATE from confidence.
        let score = min(1, max(0, (au4 - Self.au4Trigger) / (1 - Self.au4Trigger)))

        // CONFIDENCE — the face confidence, damped, hard-capped at the low ceiling. Epistemic.
        let faceConf = face.valence?.confidence ?? face.arousal?.confidence ?? face.quality
        let confidence = min(confidenceCeiling, faceConf * Self.confidenceDamping)

        // EVIDENCE — cite ONLY the present signals (the honesty law). AU4 always (the trigger);
        // the companion AUs that fired; the head cues that fired; the L4/L5 cues when they apply.
        var evidence: [SignalRef] = [.au4]
        if au5 > 0 { evidence.append(.au5) }
        if au7 > 0 { evidence.append(.au7) }
        if au1 > 0 { evidence.append(.au1) }
        if au15 > 0 { evidence.append(.au15) }
        if headDown { evidence.append(.headPitch) }
        if turnedAway { evidence.append(.headYaw) }
        if blinkSuppression > 0 { evidence.append(.blinkRate) }
        if minutes >= Self.longSessionMinutes { evidence.append(.sessionMinutes) }
        if cancelRise > 0 { evidence.append(.cancelRate) }

        // CONTRIBUTIONS — the ladder's backing scalars (mirrors F3's documented overload of
        // `contributions` for state a pure `ladder(output:isActive:)` needs):
        //   .face = the winning morphology-arm strength (L1 resolves above the threshold);
        //   .head = the SIGNED motivational direction ∈ [−1,1] (L2 sign + magnitude);
        //   .eyes = the blink-suppression value (L4), present ONLY when the eyes lens is live;
        //   .context = raw session MINUTES (L5), like F3; .interaction = the cancel rise (L5).
        var contributions: [Channel: Double] = [
            .face: max(effortArm, angerArm, sadnessArm),
            .head: direction
        ]
        if eyesLive { contributions[.eyes] = blinkSuppression }
        contributions[.context] = minutes
        if interactionLive { contributions[.interaction] = cancelRise }

        return FusionOutput(
            namedState: HonestyPhrases.frownHeadDownLeanName(lean),  // the hedged LEAN — surfaced by the hub on latch
            valence: nil, arousal: nil,                              // F4 does NOT move the published V/A
            contributions: contributions,
            confidence: confidence,
            score: score,
            evidence: evidence,
            leanCode: lean.rawValue                                  // forwarded to the narrator via baselineDelta
        )
    }

    /// Pick the winning lean from the three competing scores: a clear winner names the lean;
    /// an all-weak field or a near-tie stays honestly ambiguous (§6.6 — never assert).
    private func decideLean(effort: Double, approach: Double, withdrawal: Double) -> F4Lean {
        let ranked: [(F4Lean, Double)] = [
            (.effort, effort), (.displeasureApproach, approach), (.dejectionWithdrawal, withdrawal)
        ].sorted { $0.1 > $1.1 }
        guard let top = ranked.first, top.1 >= Self.leanFloor else { return .ambiguous }
        let runnerUp = ranked.count > 1 ? ranked[1].1 : 0
        return (top.1 - runnerUp) >= Self.ambiguityMargin ? top.0 : .ambiguous
    }

    // MARK: Disambiguation ladder (§6.6 — the honesty widget; F4 is ladder-FORWARD)

    /// F4's rungs for the current published state. Delegates to the pure
    /// `ladder(output:isActive:)` so the mapping is self-testable without a hub.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep] {
        Self.ladder(output: state.output, isActive: state.isActive)
    }

    /// Pure builder: the mode's live state → the narrowing ladder (§6.6). Reads the scalars
    /// `fuse` stashed on the output (see CONTRIBUTIONS above) + `evidence` + `leanCode`. The
    /// claim NARROWS L0→L5, then a PERMANENT ruled-out rung refuses the false-anger label.
    /// `nil` output (quiescent / off / no tick yet) ⇒ no ladder (the clean nil path).
    static func ladder(output: FusionOutput?, isActive: Bool) -> [LadderStep] {
        guard let out = output else { return [] }
        let ev = Set(out.evidence)
        let headDown = ev.contains(.headPitch)
        let turnedAway = ev.contains(.headYaw)
        let angerPresent = ev.contains(.au5) || ev.contains(.au7)
        let sadnessPresent = ev.contains(.au1) || ev.contains(.au15)
        let morphoStrength = out.contributions[.face] ?? 0
        let direction = out.contributions[.head] ?? 0
        let eyesLive = out.contributions[.eyes] != nil
        let blinkSuppressed = (out.contributions[.eyes] ?? 0) >= 0.2
        let minutes = out.contributions[.context] ?? 0
        let friction = ev.contains(.cancelRate)

        var steps: [LadderStep] = []
        func add(_ claim: String, _ status: LadderStep.Status) {
            steps.append(LadderStep(id: steps.count, claim: claim, status: status))
        }

        // L0 — pitch-correction inherited (Step 0). Always resolved: the brow IS lowered
        // (the trigger), and the head-down tilt (if any) has already been corrected upstream.
        add(headDown ? HonestyPhrases.frownHeadDownL0HeadDown : HonestyPhrases.frownHeadDownL0Level, .resolved)

        // L1 — brow morphology. Resolves to an arm when exactly one companion set fires with
        // enough strength; ambiguous (the mandated fork) when tied or too weak.
        let bothArms = angerPresent && sadnessPresent
        if morphoStrength >= morphoResolveThreshold, !bothArms {
            let claim = angerPresent ? HonestyPhrases.frownHeadDownL1Anger
                : sadnessPresent ? HonestyPhrases.frownHeadDownL1Sadness
                : HonestyPhrases.frownHeadDownL1Effort
            add(claim, .resolved)
        } else {
            add(HonestyPhrases.frownHeadDownL1, .ambiguous(HonestyPhrases.frownHeadDownL1Fork))
        }

        // L2 — motivational direction (§4.3).
        if abs(direction) >= directionDeadband {
            add(direction > 0 ? HonestyPhrases.frownHeadDownL2Approach : HonestyPhrases.frownHeadDownL2Withdrawal, .resolved)
        } else {
            add(HonestyPhrases.frownHeadDownL2, .ambiguous(HonestyPhrases.frownHeadDownL2Fork))
        }

        // L3 — head-orientation proxy. ALWAYS low-confidence (gaze-blind). Head down-and-away
        // ⇒ withdrawal; head level/toward ⇒ focused effort; a straight look-DOWN (down but not
        // turned away) is the concentration case that must STAY unresolved (the killer demo).
        if turnedAway && headDown {
            add(HonestyPhrases.frownHeadDownL3Withdrawal, .resolved)
        } else if !headDown {
            add(HonestyPhrases.frownHeadDownL3Toward, .resolved)
        } else {
            add(HonestyPhrases.frownHeadDownL3, .ambiguous(HonestyPhrases.frownHeadDownL3Fork))
        }

        // L4 — blink / load (eyes, when live).
        if eyesLive {
            add(blinkSuppressed ? HonestyPhrases.frownHeadDownL4Loaded : HonestyPhrases.frownHeadDownL4,
                blinkSuppressed ? .resolved : .ambiguous(HonestyPhrases.frownHeadDownL4Fork))
        } else {
            add(HonestyPhrases.frownHeadDownL4, .ambiguous(HonestyPhrases.frownHeadDownL4NeedsEyes))
        }

        // L5 — time-on-task / friction.
        if minutes >= longSessionMinutes {
            add(HonestyPhrases.frownHeadDownL5(minutes: minutes, friction: friction), .resolved)
        } else {
            add(HonestyPhrases.frownHeadDownL5Early, .ambiguous(HonestyPhrases.frownHeadDownL5Fork))
        }

        // The PERMANENT ruled-out rung — the false-anger label the head-down tilt can mimic,
        // refused (greyed + struck), corrected at step 0. The lean itself drives the chip +
        // narrator (via `leanCode`); the ladder shows the reasoning that produced it.
        add(HonestyPhrases.frownHeadDownRuledOut, .ruledOut(HonestyPhrases.frownHeadDownRuledOutReason))

        return steps
    }
}

#endif
