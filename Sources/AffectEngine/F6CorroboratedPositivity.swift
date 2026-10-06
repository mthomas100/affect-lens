//
//  F6CorroboratedPositivity.swift
//  AffectLens
//
//  F6 — CORROBORATED POSITIVITY (US-D14b, PRD v2 §4.2 F6 / §4.5 #1 / §4.6). The
//  honesty-SAFE replacement for the REFUSED smile-authenticity combination (refused list
//  #1): AU6/Duchenne is an intensity artifact, not an authenticity signal (Girard 2021),
//  so the app REFUSES to judge whether a smile is real. F6 asks a different, honest
//  question instead: is a positive Persona expression ECHOED by the other channels?
//
//  THE PHRASING LAW (never soften it). "echoed / not echoed across channels" — NEVER
//  "genuine / fake" (both trap on the banlist by design, precisely because this construct
//  sits on that refused boundary). An absence of echo is a NULL, not a verdict: a positive
//  expression on its own is simply un-corroborated, never "faked". So "not echoed" appears
//  ONLY as the ladder's ambiguous FORK — it is never a fired named state.
//
//  THE CONJUNCTION IS THE CONSTRUCT (mirror F1/F7). Positive facial valence AND a recent
//  on-device laughter event, TOGETHER, are the echo — a geometric mean that collapses to 0
//  the instant either is absent. Head-motion↑ and gesture-rate↑, when live, ELEVATE the
//  echo strength (the immersive enhancers); they never manufacture it.
//
//  ORCHESTRATION DEVIATION (documented). PRD §4.6 files F6 as immersive-only (it lists
//  hands/head-6DoF). But the VOICE channel — whose on-device laughter event is the KEY
//  corroborating signal (§4.2 F6) — landed WINDOWED (US-D12). So F6 ships as requires
//  [.face, .voice] (the laughter-corroborated positivity that works in the plain window),
//  with hands/head as the availability-tier enhancers. It is RICHER with the immersive aura
//  open (the head-motion + gesture echo), and the availability copy says so.
//
//  THE RECENT-LAUGHTER SIGNAL. `fuse` is pure over readings, so it cannot read the event
//  bus. The voice lens instead publishes a recency-weighted `recentLaughter` FEATURE
//  (`VoiceChannel.laughterRecency`: 1 at a laugh, decaying linearly to 0 over 30 s), and F6
//  reads that off the voice `ChannelReading` — a sound-EVENT recency, never a valence claim.
//
//  DIMENSIONAL VETO. F6 is a NAMED STATE + insight + ladder only. It does NOT move the
//  published valence/arousal (`FusionOutput.valence`/`arousal` stay nil; the hub leaves
//  `EmotionEngine.vaTransform` nil). Off by default; ceiling ≤ 0.6.
//

#if os(visionOS) || os(macOS)

import Foundation

/// F6 Corroborated positivity — the F×V (→ +H/Hd) windowed construct. A `nonisolated`
/// value type: its metadata, `fuse` math, and ladder builder are pure and self-testable off
/// the main actor, per the project's MainActor-default regime.
nonisolated struct F6CorroboratedPositivityMode: FusionMode {

    // MARK: Identity / honesty metadata

    var id: String { ConstructID.corroboratedPositivity }   // toggle key: fusion.f6-corroborated-positivity.enabled
    var title: String { "Corroborated positivity" }
    /// Windowed MVV is face × voice (the laughter corroboration works in the plain window —
    /// the orchestration deviation from §4.6's immersive-only filing); hands / head ENHANCE
    /// the echo strength when the immersive aura is open (§4.6). Written generically over
    /// "whichever echo channels are present", so the enhancers Just Work when live.
    var requires: Set<Channel> { [.face, .voice] }

    var rationale: String { HonestyPhrases.corroboratedPositivityRationale }
    var confound: String { HonestyPhrases.corroboratedPositivityConfound }
    var citation: String? { "Girard 2021" }
    /// A corroboration read, not an authenticity verdict — behavioral echo only, so the
    /// ceiling sits at F1's 0.6 and no higher (in practice the voice lens's modest laughter
    /// confidence caps the fused value well below this today).
    var confidenceCeiling: Double { 0.6 }

    // MARK: Hysteresis (documented band + dwell, ~15 Hz ticks)

    /// A short SUSTAINED state — the positive expression + laughter must co-occur, but the
    /// laughter recency decays over 30 s so the enter dwell stays modest: enter 0.40 / exit
    /// 0.25 is a real band; enter-dwell 20 ≈ 1.3 s (a single frame of overlap can't trip it);
    /// exit-dwell 12 ≈ 0.8 s (drop the "echoed" attribution promptly once either cue fades).
    var hysteresis: ConstructHysteresis {
        ConstructHysteresis(enter: 0.40, exit: 0.25, enterDwellTicks: 20, exitDwellTicks: 12)
    }

    // MARK: Tunables (documented thresholds — all in the readings' own units)

    /// A Persona valence within ±`valenceDeadband` reads "near-neutral" — below it there is
    /// no positive expression to corroborate (F6 stays quiescent).
    static let valenceDeadband = 0.15
    /// Positivity past the deadband that drives the positive-valence ramp to 1 — by v ≈ 0.5
    /// the face is clearly smiling.
    static let valenceSpan = 0.35
    /// Head angular-motion energy (rad/s Δ from resting) that maps to a full head-motion echo
    /// — == `HeadChannel.energyDeltaScale` (kept a literal for the same nonisolated reason as
    /// F1's proxy scales: `HeadChannel`'s statics are MainActor-isolated, this list is not).
    static let headMotionScale = 1.0
    /// A gesture RATE (bursts/min) that maps to a full gesture echo (mirror F4's scale).
    static let gestureRateScale = 6.0
    /// How much the strongest motion/gesture echo ELEVATES the base (face×laughter) echo:
    /// a full enhancer multiplies the echo by (1 + this). The enhancers strengthen a real
    /// echo, never create one (a 0 base echo stays 0 regardless of motion).
    static let echoBoostGain = 0.5
    /// A construct is at most as trustworthy as its weakest channel, discounted because a
    /// cross-channel corroboration is inherently uncertain (mirror F1/F7).
    static let confidenceDamping = 0.85
    /// The positive-valence contribution at/above which the ladder's L0 rung reads RESOLVED.
    static let positiveResolvedThreshold = 0.30

    // MARK: Fuse

    /// Fuse the current readings into F6's echo, or `nil` when there is no positive Persona
    /// expression to corroborate (near-neutral / negative valence ⇒ QUIESCENT — no fabricated
    /// read, §4.2; this is the "positive face absent" quiescence, distinct from the ladder's
    /// "not echoed" fork). Reads `.face` + `.voice` (required) and, when live, `.head` /
    /// `.hands` (the echo enhancers). Pure over inputs.
    func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
        guard let face = readings[.face], face.availability != .unavailable,
              let voice = readings[.voice], voice.availability != .unavailable
        else { return nil }

        // POSITIVE-FACE component — only the POSITIVE side of valence ramps (a negative or
        // near-neutral face has nothing to corroborate ⇒ quiescent nil below).
        let v = face.valence?.value ?? 0
        let positiveValence = clamp01((v - Self.valenceDeadband) / Self.valenceSpan)
        guard positiveValence > 0 else { return nil }

        // LAUGHTER component — the recency-weighted on-device laughter event the voice lens
        // publishes (1 at a laugh, decaying to 0 over 30 s). 0 ⇒ un-corroborated (the ladder
        // shows the "not echoed" fork; the score stays 0 and never latches — a null, not a verdict).
        let laughter = clamp01(voice.features[.recentLaughter] ?? 0)

        // ENHANCERS — head-motion↑ + gesture-rate↑, each normalized, the strongest wins.
        var headEcho = 0.0
        if let head = readings[.head], head.availability != .unavailable {
            headEcho = clamp01(max(0, head.features[.headMotionEnergy] ?? 0) / Self.headMotionScale)
        }
        var gestureEcho = 0.0
        if let hands = readings[.hands], hands.availability != .unavailable {
            gestureEcho = clamp01((hands.features[.gestureRate] ?? 0) / Self.gestureRateScale)
        }
        let enhancer = max(headEcho, gestureEcho)

        // BASE ECHO — geometric mean of the positive face AND the recent laughter: the
        // CONJUNCTION is the construct, so either at 0 forces the echo to 0. The enhancers
        // then ELEVATE a real echo (never manufacture one from a 0 base).
        let baseEcho = (positiveValence * laughter).squareRoot()
        let score = clamp01(baseEcho * (1 + Self.echoBoostGain * enhancer))

        // CONTRIBUTIONS — the legible-fusion audit + the ladder's backing scalars.
        var contributions: [Channel: Double] = [.face: positiveValence, .voice: laughter]
        if headEcho > 0 { contributions[.head] = headEcho }
        if gestureEcho > 0 { contributions[.hands] = gestureEcho }

        // EVIDENCE — cite only present, contributing signals (the honesty law).
        var evidence: [SignalRef] = [.valence]
        if laughter > 0 { evidence.append(.recentLaughter) }
        if headEcho > 0 { evidence.append(.headMotionEnergy) }
        if gestureEcho > 0 { evidence.append(.gestureRate) }

        // CONFIDENCE — min of the required channels' confidences (face valence; voice's
        // deliberately-modest arousal/quality), damped, capped. Epistemic — kept SEPARATE.
        let faceConf = face.valence?.confidence ?? 0
        let voiceConf = voice.arousal?.confidence ?? voice.quality
        let confidence = min(confidenceCeiling, min(faceConf, voiceConf) * Self.confidenceDamping)

        return FusionOutput(
            namedState: HonestyPhrases.corroboratedPositivityEchoedState,  // surfaced by the hub on latch
            valence: nil, arousal: nil,         // F6 does NOT move the published V/A
            contributions: contributions,
            confidence: confidence,
            score: score,
            evidence: evidence
        )
    }

    // MARK: Disambiguation ladder (§6.6 — the honesty widget; mandatory for F6)

    /// F6's rungs for the current published state. Delegates to the pure
    /// `ladder(output:isActive:)` so the mapping is self-testable without a hub.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep] {
        Self.ladder(output: state.output, isActive: state.isActive)
    }

    /// Pure builder: the mode's live state → the narrowing ladder (§6.6). L0 positive
    /// expression → L1 laughter within the window → L2 motion/gesture echo → the "echoed"
    /// verdict. When NOT latched the verdict rung shows the "not echoed" FORK (a null, never a
    /// verdict — the only place that phrase ever appears). `nil` output ⇒ no ladder.
    static func ladder(output: FusionOutput?, isActive: Bool) -> [LadderStep] {
        guard let out = output else { return [] }
        let positive = (out.contributions[.face] ?? 0) >= positiveResolvedThreshold
        let laughed = (out.contributions[.voice] ?? 0) > 0
        let motionEchoed = (out.contributions[.head] ?? 0) > 0 || (out.contributions[.hands] ?? 0) > 0

        var steps: [LadderStep] = []
        func add(_ claim: String, _ status: LadderStep.Status) {
            steps.append(LadderStep(id: steps.count, claim: claim, status: status))
        }

        add(HonestyPhrases.corroboratedPositivityL0,
            positive ? .resolved : .ambiguous(HonestyPhrases.corroboratedPositivityL0Fork))
        add(HonestyPhrases.corroboratedPositivityL1,
            laughed ? .resolved : .ambiguous(HonestyPhrases.corroboratedPositivityL1Fork))
        add(HonestyPhrases.corroboratedPositivityL2,
            motionEchoed ? .resolved : .ambiguous(HonestyPhrases.corroboratedPositivityL2Fork))
        add(isActive ? HonestyPhrases.corroboratedPositivityVerdict : HonestyPhrases.corroboratedPositivityVerdictNotEchoed,
            isActive ? .resolved : .ambiguous(HonestyPhrases.corroboratedPositivityVerdictFork))
        return steps
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

#endif
