//
//  F3FatigueEngagement.swift
//  AffectLens
//
//  F3 — FATIGUE ⇄ ENGAGEMENT (US-C11, PRD v2 §4.2 F3 / §4.6). The construct that is
//  NOT two meters: ONE coupled axis that FLIPS ON THE BLINK SIGN. Anchor: Wierwille
//  1994 / Dinges & Grace 1998 (PERCLOS — a prolonged-closure fraction rising well over
//  a per-user baseline is the textbook drowsiness index); Maffei & Angrilli 2018 (blink
//  dynamics). "E over time" — the windowed-MVV construct whose SECOND axis is TIME, not
//  a second channel (it requires only [.eyes]); the CONTEXT channel's session duration
//  is a MODIFIER (§3.7), not a display.
//
//  THE ONE-METER LAW (never soften it). Blink is directionally ambiguous ALONE — low =
//  engaged OR early-task; high = fatigue OR anxiety OR mind-wandering (§3.2). So F3 is
//  ONE zero-centred axis in [−1, +1], NEVER two simultaneous meters:
//    • the ENGAGED pole (positive) = sustained blink SUPPRESSION + steady eyes;
//    • the FATIGUED pole (negative) = sustained blink RATE↑ + prolonged closures
//      (AU43/PERCLOS burden), ACCRUING with session time.
//  Sign convention: fatigued NEGATIVE, engaged POSITIVE. A `CoupledPoleLatch` (two
//  hysteretic pole machines with a neutral dead band) guarantees only ONE pole (or
//  neutral) ever latches — the ONE-meter law made mechanical.
//
//  THE SESSION-ACCRUAL ASYMMETRY (the honest part). Fatigue BUILDS with time on task
//  (Wierwille: raises from ~the 4th minute), so the fatigued-pole evidence is amplified
//  by a documented multiplicative ramp of session minutes (1.0 at 0 min → ~1.5 at ≥45
//  min, capped). ENGAGEMENT is NOT time-amplified — fresh eyes early in a session are
//  engagement, not the ABSENCE of fatigue — so the ramp touches the fatigued pole ONLY.
//
//  NON-DIAGNOSTIC CEILING. The surfaced states are "engaged" and "alertness declining"
//  (with the sanctioned nudge "consider a break") — NEVER a medical/drowsiness
//  diagnosis. The named confound (boredom / calm low-arousal look identical here — it is
//  an attention / alertness axis, not an emotion) is stated verbatim. Ceiling ≤ 0.7.
//
//  DIMENSIONAL VETO. F3 is a NAMED STATE + insight + ladder + a bipolar bar only. It
//  does NOT move the published valence/arousal (`FusionOutput.valence`/`arousal` stay
//  nil; the hub leaves `EmotionEngine.vaTransform` nil).
//

#if os(visionOS) || os(macOS)

import Foundation

/// F3 Fatigue ⇄ Engagement — the E-over-time COUPLED construct (PRD §4.6 windowed MVV).
/// A `nonisolated` value type: its metadata, `fuse` math, pole labels, and ladder builder
/// are pure and self-testable off the main actor, per the project's MainActor-default
/// regime. Conforms to `CoupledFusionMode` so the hub drives its two-pole latch.
nonisolated struct F3FatigueEngagementMode: CoupledFusionMode {

    // MARK: Identity / honesty metadata

    var id: String { ConstructID.fatigueEngagement }     // toggle key: fusion.f3-fatigue-engagement.enabled
    var title: String { "Fatigue ⇄ Engagement" }
    /// Requires the EYES lens ONLY. The "fusion" here is E-over-TIME (the windowed blink
    /// stream against its own baseline); the CONTEXT channel's session minutes is a
    /// MODIFIER (§3.7), consumed when present but deliberately NOT a required channel — so
    /// the synthesized context reading never gates availability. (Head-droop / motion
    /// decay join `requires` when the head channel lands — the enhanced tier, §4.6.)
    var requires: Set<Channel> { [.eyes] }

    var rationale: String { HonestyPhrases.fatigueEngagementRationale }
    var confound: String { HonestyPhrases.fatigueEngagementConfound }
    var citation: String? { "Wierwille 1994 / Dinges PERCLOS" }
    /// An attention/alertness proxy off a single ambiguous channel over time — honest but
    /// never diagnostic, so the ceiling sits at F7's moderate-high 0.7 and no higher.
    var confidenceCeiling: Double { 0.7 }

    // MARK: Two-pole latch (the ONE coupled meter, US-C11)

    /// The pole-latch band + dwell (~15 Hz ticks). `enter 0.45 / exit 0.25` is a real
    /// hysteresis band; `enterDwell 30 ≈ 2 s` demands the lean PERSIST (a single long
    /// blink can't trip it); `exitDwell 15 ≈ 1 s` releases faster. exitDwell < enterDwell
    /// is what buys the neutral DEAD BAND on a hard flip — the leaving pole exits before
    /// the arriving pole can enter (no dual-active tick; PRD's ONE-meter law).
    static let poleEnter = 0.45
    static let poleExit = 0.25
    static let poleEnterDwell = 30
    static let poleExitDwell = 15

    nonisolated var coupledLatch: CoupledPoleLatch {
        CoupledPoleLatch(enter: Self.poleEnter, exit: Self.poleExit,
                         enterDwellTicks: Self.poleEnterDwell, exitDwellTicks: Self.poleExitDwell)
    }

    /// The surfaced pole label — the sanctioned, NON-diagnostic copy. `+` engaged, `−`
    /// "alertness declining" (never a "fatigue"/drowsiness medical claim).
    nonisolated func poleName(forSign sign: Int) -> String? {
        if sign > 0 { return HonestyPhrases.fatigueEngagementEngagedState }
        if sign < 0 { return HonestyPhrases.fatigueEngagementFatiguedState }
        return nil
    }

    // MARK: Tunables (documented thresholds — all in the readings' own units)

    /// |blink-rate Δ| (per minute, from the per-user resting rate) that maps to a
    /// full-magnitude blink component — the same 12/min scale the eyes lens uses for its
    /// arousal meter (`EyeChannel.arousalDeltaScale`), so a rise and a suppression are
    /// measured on one consistent axis.
    static let blinkScale = 12.0
    /// A |blink-rate Δ| below this (per minute) is "near baseline" — no clear trend (the
    /// ladder's L0 discriminator). ≈ the 12/min scale's 0.15 fraction.
    static let blinkTrendDeadband = 0.15
    /// Blink dominates each pole (the direct, best-validated cue); closures (fatigued) and
    /// steadiness (engaged) are the secondary terms.
    static let blinkWeight = 0.7
    static let closureWeight = 0.3
    static let stabilityWeight = 0.3
    /// Eye-openness VARIANCE at/above which steadiness reads 0 — below it the eyes read
    /// "steady" (engaged support), above it "erratic" (a PERCLOS-ish fatigue cue).
    /// Provisional (a per-user variance baseline is a later refinement, mirroring how the
    /// resting blink rate is learned); the blink term dominates, so a coarse scale is safe.
    static let steadinessVarScale = 0.01
    /// How much rising eye-openness variance (unsteadiness) adds to the closure burden,
    /// alongside the prolonged-closure flag — the "variance direction over the window" half
    /// of the PERCLOS-ish burden. A secondary term; a real prolonged closure alone already
    /// tops the burden out.
    static let unsteadinessShare = 0.5

    // MARK: Session accrual (the fatigued-ONLY time amplifier, §3.7 context modifier)

    /// Session minutes at which the fatigued-pole amplifier reaches its cap.
    static let accrualRampMinutes = 45.0
    /// The extra fatigued gain at the cap: 1.0 at 0 min → 1.5 at ≥45 min. Engagement is
    /// never amplified by time (the documented asymmetry — fresh eyes early ≠ fatigue).
    static let accrualGain = 0.5

    /// The multiplicative fatigued-pole amplifier for `minutes` of session time — 1.0 at
    /// 0 min, ramping linearly to `1 + accrualGain` at `accrualRampMinutes`, then capped.
    static func fatigueAccrual(minutes: Double) -> Double {
        1 + accrualGain * min(1, max(0, minutes) / accrualRampMinutes)
    }

    /// A component magnitude at/above which the ladder's L0 (blink-trend) rung resolves.
    static let trendResolvedThreshold = 0.15

    // MARK: Fuse

    /// Fuse the current per-channel readings into F3's SIGNED axis, or `nil` if the eyes
    /// lens isn't producing a usable reading this tick (never a fabricated read — §4.2).
    /// Reads `.eyes` (required) and, when present, `.context`.sessionMinutes (the §3.7
    /// modifier). `score == |axis|`; the pole is latched downstream by the hub's
    /// `CoupledPoleLatch`.
    func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
        guard let eyes = readings[.eyes], eyes.availability != .unavailable else { return nil }

        let blinkDelta = eyes.features[.blinkRate] ?? 0                 // signed Δ/min from resting
        let variance = eyes.features[.eyeOpenVariance] ?? 0
        let prolonged = (eyes.features[.prolongedClosure] ?? 0) > 0.5

        // SESSION ACCRUAL (context modifier, §3.7) — amplifies the FATIGUED pole only.
        let minutes = max(0, readings[.context]?.features[.sessionMinutes] ?? 0)
        let accrual = Self.fatigueAccrual(minutes: minutes)

        // One-sided blink components (the axis's namesake, on a single 12/min scale).
        let blinkUp = clamp01(max(0, blinkDelta) / Self.blinkScale)    // fatigue direction
        let blinkDown = clamp01(max(0, -blinkDelta) / Self.blinkScale) // engaged direction
        // Eye-openness variance read as a SIGNED steadiness: low variance = steady eyes
        // (engaged support); high variance = erratic lids (a PERCLOS-ish fatigue cue).
        let steadiness = clamp01(1 - variance / Self.steadinessVarScale)
        // Closure burden (PERCLOS-ish): a prolonged closure present + rising variance (the
        // "variance direction over the window"). A prolonged closure alone tops it out.
        let closureBurden = clamp01((prolonged ? 1.0 : 0.0) + Self.unsteadinessShare * (1 - steadiness))

        // POLES (each ≥ 0). Accrual touches the fatigued pole ONLY (the asymmetry).
        let fatigued = clamp01((Self.blinkWeight * blinkUp + Self.closureWeight * closureBurden) * accrual)
        let engaged = clamp01(Self.blinkWeight * blinkDown + Self.stabilityWeight * steadiness)

        // ONE coupled axis: engaged (positive) minus fatigued (negative). `score = |axis|`.
        let axis = max(-1, min(1, engaged - fatigued))
        let score = abs(axis)

        // CONFIDENCE — the eyes lens's own (deliberately modest) arousal confidence,
        // capped at the ceiling. Epistemic, kept SEPARATE from the axis magnitude.
        let eyesConf = eyes.arousal?.confidence ?? eyes.quality
        let confidence = min(confidenceCeiling, eyesConf)

        // EVIDENCE — cite only present signals (the honesty law). `.blinkRate` whenever
        // there is a real trend either way; closures / variance / session as they apply.
        var evidence: [SignalRef] = []
        if abs(blinkDelta) / Self.blinkScale > Self.blinkTrendDeadband { evidence.append(.blinkRate) }
        if prolonged { evidence.append(.prolongedClosure) }
        if variance > 1e-9 { evidence.append(.eyeOpenVariance) }
        if minutes > 0 { evidence.append(.sessionMinutes) }
        if evidence.isEmpty { evidence.append(.blinkRate) }            // never an empty citation

        // CONTRIBUTIONS — the blink-trend magnitude (ladder L0 discriminator) and, as the
        // ONE documented exception, the raw session MINUTES under `.context` (NOT a 0…1
        // weight) so `ladder(for:)` can render "over [X] min". `.context` is the modifier
        // channel, never a lens weight, so this overloads no real contributor.
        let contributions: [Channel: Double] = [
            .eyes: clamp01(abs(blinkDelta) / Self.blinkScale),
            .context: minutes
        ]

        return FusionOutput(
            namedState: nil,                    // the hub names the POLE once latched
            valence: nil, arousal: nil,         // F3 does NOT move the published V/A
            contributions: contributions,
            confidence: confidence,
            score: score,
            evidence: evidence,
            axis: axis
        )
    }

    // MARK: Disambiguation ladder (§6.6 — the honesty widget)

    /// F3's rungs for the current published state. Delegates to the pure
    /// `ladder(output:isActive:)` so the mapping is self-testable without a hub.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep] {
        Self.ladder(output: state.output, isActive: state.isActive)
    }

    /// Pure builder: the mode's live state → the ladder rungs (§6.6). The claim NARROWS:
    /// L0 blink trend vs baseline → L1 closures / PERCLOS burden → L2 session accrual
    /// ("over [X] min") → the pole verdict, OR an ambiguous "steady state" fork while in
    /// the dead band. `nil` output ⇒ no ladder.
    static func ladder(output: FusionOutput?, isActive: Bool) -> [LadderStep] {
        guard let out = output else { return [] }
        let engaged = (out.axis ?? 0) > 0
        let blinkTrend = (out.contributions[.eyes] ?? 0) > trendResolvedThreshold
        let closures = out.evidence.contains(.prolongedClosure)
        let minutes = out.contributions[.context] ?? 0

        var steps: [LadderStep] = []
        func add(_ claim: String, _ status: LadderStep.Status) {
            steps.append(LadderStep(id: steps.count, claim: claim, status: status))
        }

        add(HonestyPhrases.fatigueEngagementLadderL0,
            blinkTrend ? .resolved : .ambiguous(HonestyPhrases.fatigueEngagementLadderL0Fork))
        add(HonestyPhrases.fatigueEngagementLadderL1,
            closures ? .resolved : .ambiguous(HonestyPhrases.fatigueEngagementLadderL1Fork))
        add(HonestyPhrases.fatigueEngagementLadderL2(minutes: minutes),
            isActive ? .resolved : .ambiguous(HonestyPhrases.fatigueEngagementLadderL2Fork))
        if isActive {
            add(engaged ? HonestyPhrases.fatigueEngagementVerdictEngaged
                        : HonestyPhrases.fatigueEngagementVerdictFatigued,
                .resolved)
        } else {
            add(HonestyPhrases.fatigueEngagementVerdictNeutral,
                .ambiguous(HonestyPhrases.fatigueEngagementVerdictNeutralFork))
        }
        return steps
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

#endif
