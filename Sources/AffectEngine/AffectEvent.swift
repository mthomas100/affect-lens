//
//  AffectEvent.swift
//  AffectLens
//
//  The typed AffectEvent bus vocabulary (US-B7, PRD v2 §5.3) — the auditable
//  chokepoint for every mechanical or agent behavior. "One type, three consumers"
//  (debug HUD feed, regression fixture, LLM input); append-only, never a side
//  channel. This file defines the three value types that ride the bus; the bus
//  itself (`private(set) var events` + `emit`) lives on `AffectHub` (§5.5).
//
//  Honesty law (PRD §6.7 / §9.1 M7): the narrator may cite ONLY the signals in
//  `SignalRef`. Later the FoundationModels narrator's `@Generable` output schema is
//  constrained by this SAME enum, so "never invents a channel" becomes a
//  TYPE-level guarantee, and the template narrator here is held to it by
//  `EmotionSelfTests.narratorHonesty()`.
//

import Foundation

/// The CLOSED vocabulary of signals the app can actually cite — every case is a
/// signal that is (or will be, as its channel lands) genuinely present in a
/// reading. The narrator may reference ONLY these; a claim about anything not in
/// this enum is, by construction, unspeakable.
///
/// Grouped by channel. Today's live signals are the face reading-level ones
/// (`valence` / `arousal` / `confidence` / `dominantEmotion`), the FACS AUs
/// (present every frame in `EmotionEngine.auVector`), and the eyes lens features
/// (`blinkRate` / `eyeOpenVariance` / `prolongedClosure`). The remaining cases
/// mirror `FeatureKey` so later channels (hands / head / voice / interaction /
/// context) emit into the same closed vocabulary as they arrive.
nonisolated enum SignalRef: String, Codable, Sendable, CaseIterable {
    // face — reading-level (not `FeatureKey`s: they live on `EmotionReading`)
    case valence
    case arousal
    case confidence
    case dominantEmotion
    // face — FACS Action Units (present in `EmotionEngine.auVector` every frame)
    case au1, au2, au4, au5, au6, au7, au9, au12, au15, au20, au23, au25, au26
    case auUnilateral
    // eyes
    case blinkRate
    case eyeOpenVariance
    case prolongedClosure
    case eyeOpenness
    // hands
    case selfTouchRate
    case gestureEnergy
    case gestureRate
    case handAperture
    // head
    case headPitch
    case headYaw
    case headRoll
    case headMotionEnergy
    // voice
    case vocalF0
    case vocalIntensity
    case vocalTempo
    /// A recency-weighted "a laugh-like sound registered recently" scalar ∈ [0, 1]
    /// (US-D14b F6): 1 the instant an on-device laughter event fires, decaying linearly
    /// to 0 over the voice channel's `laughterRecencyWindow`. The corroborating signal
    /// F6 Corroborated-Positivity cites — a sound EVENT recency, never a valence claim.
    case recentLaughter
    // interaction
    case cancelRate
    case responseLatency
    case inputTempo
    // context
    case sessionMinutes

    /// A short, honest human phrase for this signal — used verbatim in narrator
    /// sentences and as the evidence-chip label in the insight feed. Deliberately
    /// names the SIGNAL, never a felt emotion.
    var displayName: String {
        switch self {
        case .valence: return "valence"
        case .arousal: return "arousal"
        case .confidence: return "confidence"
        case .dominantEmotion: return "dominant expression"
        case .au1: return "AU1"
        case .au2: return "AU2"
        case .au4: return "AU4"
        case .au5: return "AU5"
        case .au6: return "AU6"
        case .au7: return "AU7"
        case .au9: return "AU9"
        case .au12: return "AU12"
        case .au15: return "AU15"
        case .au20: return "AU20"
        case .au23: return "AU23"
        case .au25: return "AU25"
        case .au26: return "AU26"
        case .auUnilateral: return "asymmetry"
        case .blinkRate: return "blink rate"
        case .eyeOpenVariance: return "eye-openness variance"
        case .prolongedClosure: return "prolonged eye closure"
        case .eyeOpenness: return "eye openness"
        case .selfTouchRate: return "self-touch rate"
        case .gestureEnergy: return "gesture energy"
        case .gestureRate: return "gesture rate"
        case .handAperture: return "hand aperture"
        case .headPitch: return "head pitch"
        case .headYaw: return "head yaw"
        case .headRoll: return "head roll"
        case .headMotionEnergy: return "head-motion energy"
        case .vocalF0: return "vocal pitch"
        case .vocalIntensity: return "vocal intensity"
        case .vocalTempo: return "vocal tempo"
        case .recentLaughter: return "recent laughter"
        case .cancelRate: return "cancel rate"
        case .responseLatency: return "response latency"
        case .inputTempo: return "input tempo"
        case .sessionMinutes: return "session length"
        }
    }
}

/// The kind of thing that happened on the bus (PRD v2 §5.3). Most kinds land with
/// their channels in later items; today only `.stateShift` is emitted (BOCPD on the
/// face valence/arousal stream) plus the calibration/availability lifecycle kinds.
nonisolated enum EventKind: String, Codable, Sendable {
    case blink
    case eyeClosureProlonged
    case selfTouch
    case gestureBurst
    case postureShift
    case headMotionSpike
    case vocalEvent
    case congruenceBreak
    case arousalConsensus
    /// A Bayesian change-point on an honest dimensional axis (BOCPD; Adams &
    /// MacKay 2007). Today: a shift on the face valence or arousal stream.
    case stateShift
    /// A named FUSION construct latched active (or, quietly, cleared) — US-C9. Today:
    /// F7 Frustration crossing its `ConstructHysteresis`. `channel` is nil (a fused
    /// construct has no single owner); `evidence` carries its contributing signals.
    /// Additive + Codable-safe for old traces — they predate the case and never carry it.
    case constructStateChanged
    case calibrationStarted
    case calibrationCompleted
    case channelAvailabilityChanged
    case lowExpresserFlag
    case baselineRetrack
}

/// The stable string ids of the fused constructs — the ONE source of truth shared by
/// the (visionOS-only) `FusionMode` structs that back the `fusion.<id>.enabled` toggle
/// and the (all-platform) `TemplateNarrator` that routes a `.constructStateChanged`
/// event to the right template. Lives HERE, unguarded, so both sides reference the same
/// literals with no `#if os(visionOS)` fence and no drift (US-C11). Each value is also
/// the mode's `id` and its toggle-key stem.
nonisolated enum ConstructID {
    /// F1 Composure-under-load (F×E).
    static let composure = "f1-composure"
    /// F2 Cognitive load / effort (E×I MVV → +H/Hd; US-D14a — an attention axis, NOT an emotion).
    static let cognitiveLoad = "f2-cognitive-load"
    /// F3 Fatigue ⇄ Engagement (E over time — the coupled meter, US-C11).
    static let fatigueEngagement = "f3-fatigue-engagement"
    /// F4 Frown + head-down disambiguation (F×Hd windowed; US-D14a — a LEAN + a ladder, never a label).
    static let frownHeadDown = "f4-frown-head-down"
    /// F7 Frustration / task friction (F×I).
    static let frustration = "f7-frustration"
    /// F6 Corroborated Positivity (F×V → +H/Hd; US-D14b — "echoed across channels", the
    /// honesty-safe replacement for the refused smile-authenticity combination, §4.5 #1).
    static let corroboratedPositivity = "f6-corroborated-positivity"
    /// F10 Approach ⇄ Withdrawal (Hd×H coupled; US-D14b — the §4.3 anger-vs-sadness tie-break axis).
    static let approachWithdrawal = "f10-approach-withdrawal"
    /// F8 Dominance display (Hd×H coupled; US-D14b — expansion ⇄ contraction, a POSTURE display).
    static let dominance = "f8-dominance"
    /// F9 Expansive / high-dominance display (Hd×H×F; US-D14b — a display on the dominance axis,
    /// NOT the felt emotion "pride"; head-only, low base-rate).
    static let expansiveDisplay = "f9-expansive-display"
    /// F5 Corroborated arousal (E×(H/Hd/V); US-D14b — the arousal-specific sibling of F1, WITHOUT
    /// the calm-face requirement: ≥2 non-face arousal proxies elevated concurrently).
    static let covertArousal = "f5-covert-arousal"
}

/// The four hedged LEANS the F4 frown+head-down construct can surface (US-D14a), encoded as
/// a discrete code carried on the `.constructStateChanged` event's `baselineDelta` so the
/// (cross-platform) `TemplateNarrator` can recover the lean the (visionOS-only)
/// `F4FrownHeadDownMode` computed — the mode and the narrator share these literals, exactly
/// as they share `ConstructID`. A LEAN is a disambiguation aid, NEVER a discrete-emotion
/// label; the human display strings live in `HonestyPhrases` (also cross-platform). Lives
/// HERE, unguarded, so the visionOS mode and the all-platform narrator reference one source.
nonisolated enum F4Lean: Double, CaseIterable {
    /// AU4 alone (a lowered brow with no lid or oblique companions) — reads as effort.
    case effort = 1
    /// AU4 + AU5/AU7 and/or an approach motivational direction — displeasure, APPROACH-motivated
    /// (anger is negative-valence but approach; §4.3). Never the bare label "anger".
    case displeasureApproach = 2
    /// AU1 + AU15 and/or a withdrawal motivational direction — dejection, WITHDRAWAL-motivated.
    case dejectionWithdrawal = 3
    /// The arms tie or all read weak — honestly unresolved (we can't see gaze, §2.2).
    case ambiguous = 4
}

/// One append-only entry on the affect-event bus (PRD v2 §5.3). Codable so it
/// doubles as the golden-trace fixture (features/events only, never pixels) and as
/// the LLM narrator's input; Identifiable so the UI feed can diff it.
nonisolated struct AffectEvent: Codable, Sendable, Identifiable {
    /// Stable identity (also the id of the `InsightEntry` the narrator derives).
    let id: UUID
    /// When the event occurred.
    let t: Date
    /// The channel it came from, or `nil` for hub-level / cross-channel events.
    let channel: Channel?
    /// What happened.
    let kind: EventKind
    /// Non-negative event size (e.g. |shift| on the axis). Aleatoric, NOT confidence.
    let magnitude: Double
    /// Epistemic trust in the event (0…1) — kept separate from `magnitude`.
    let confidence: Double
    /// The present signals this event is grounded in. The narrator may cite only
    /// these (the honesty law); an empty list means "no citable signal" and the
    /// narrator must not manufacture one.
    let evidence: [SignalRef]
    /// Optional SIGNED delta from the relevant baseline / prior regime (e.g. the
    /// signed axis shift for `.stateShift`, or a coupled construct's signed axis so the
    /// narrator can recover its pole), so a consumer can recover direction while
    /// `magnitude` stays non-negative.
    let baselineDelta: Double?
    /// For a `.constructStateChanged` event, the id of the fused construct that latched
    /// (a `ConstructID` value), so the narrator routes to the RIGHT template by identity
    /// rather than by an evidence heuristic that misroutes constructs sharing a signal
    /// family (US-C11). `nil` for every non-construct event AND for pre-US-C11 traces —
    /// a trailing, defaulted optional, so synthesized Codable encodes nil as an omitted
    /// key and decodes a missing key back to nil (old golden traces round-trip unchanged).
    let constructID: String?

    init(id: UUID = UUID(),
         t: Date = Date(),
         channel: Channel?,
         kind: EventKind,
         magnitude: Double,
         confidence: Double,
         evidence: [SignalRef],
         baselineDelta: Double? = nil,
         constructID: String? = nil) {
        self.id = id
        self.t = t
        self.channel = channel
        self.kind = kind
        self.magnitude = magnitude
        self.confidence = confidence
        self.evidence = evidence
        self.baselineDelta = baselineDelta
        self.constructID = constructID
    }
}
