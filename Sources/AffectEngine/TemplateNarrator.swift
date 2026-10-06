//
//  TemplateNarrator.swift
//  AffectLens
//
//  The template-string narrator (US-B7, PRD v2 §6.3) — shipped FIRST, before the
//  FoundationModels narrator (which is gated on the K5 latency keystone). It turns
//  an `AffectEvent` into a plain-language `InsightEntry` STRICTLY from the
//  `HonestyPhrases` templates, so every narrated line is honest by construction
//  and passes metric M7 (`EmotionSelfTests.narratorHonesty()`).
//
//  When the FM narrator lands it slots in behind the same `SignalRef` evidence
//  contract and the same `HonestyPhrases.containsBanned` post-filter; this template
//  narrator remains the always-available fallback.
//

import Foundation

/// One narrated feed entry (US-B7 §6.3). Carries the sentence plus the structured
/// backing (kind + evidence + confidence) the feed reveals when a row is expanded.
/// Codable so it can ride the golden-trace fixture alongside its `AffectEvent`.
nonisolated struct InsightEntry: Identifiable, Sendable, Codable {
    /// Shares the originating `AffectEvent.id` (stable identity across the bus).
    let id: UUID
    /// When the narrated event occurred.
    let t: Date
    /// The honest, banned-substring-clean sentence.
    let text: String
    /// The event kind this entry narrates (for the expandable detail / filtering).
    let kind: EventKind
    /// The present signals cited — rendered as evidence chips on expand.
    let evidence: [SignalRef]
    /// Epistemic confidence (0…1) — rendered as a WORD, separate from intensity.
    let confidence: Double
}

/// Pure, `nonisolated` template narrator. No state, no I/O — a total function from
/// an event to an honest entry.
nonisolated enum TemplateNarrator {

    /// The face valence below which F10's approach/withdrawal narration adds the §4.3
    /// negative-affect tie-break LEAN (a small deadband so a near-neutral face gets direction
    /// language only). Kept here (cross-platform) so the visionOS F10 mode and this narrator
    /// share one source; the pure lean CHOOSER lives in `HonestyPhrases.approachWithdrawal`.
    static let faceNegativeThreshold = -0.15

    /// Narrate one event. Every produced sentence comes from `HonestyPhrases`
    /// templates, cites the event's present `SignalRef`s, and states a confidence
    /// word separate from any intensity. `reading` is accepted for future
    /// enrichment; the template forms need only the event.
    static func narrate(_ event: AffectEvent, reading: EmotionReading?) -> InsightEntry {
        let text: String
        switch event.kind {
        case .stateShift:
            // Axis = the primary cited signal (the hub lists it first); direction
            // from the signed baselineDelta.
            let axis = event.evidence.first ?? .valence
            let dir: HonestyPhrases.Direction = (event.baselineDelta ?? 0) >= 0 ? .up : .down
            text = HonestyPhrases.stateShift(axis: axis, direction: dir, confidence: event.confidence)
        case .congruenceBreak:
            // Cross-channel divergence (US-C10a §4.4) — names the disagreeing signals,
            // frames reduced certainty, never "concealment".
            text = HonestyPhrases.congruenceBreak(evidence: event.evidence, confidence: event.confidence)
        case .arousalConsensus:
            // Cross-channel agreement onset (US-C10a §4.4).
            text = HonestyPhrases.arousalConsensus(evidence: event.evidence, confidence: event.confidence)
        case .vocalEvent:
            // An on-device laughter/sound event (US-D12) — corroboration ONLY (F6 later),
            // never an emotion verdict. Cites the present vocal signal + Persona grounding.
            text = HonestyPhrases.vocalEvent(evidence: event.evidence, confidence: event.confidence)
        case .selfTouch:
            // A hands self-touch RATE tick (US-D13a) — a neutral observation, never a single-
            // touch verdict, never an anxiety framing. Cites the self-touch-rate signal.
            text = HonestyPhrases.selfTouch(confidence: event.confidence)
        case .gestureBurst:
            // A hands motion-energy spike (US-D13a) — never a named pose (no gesture dictionary).
            text = HonestyPhrases.gestureBurst(confidence: event.confidence)
        case .constructStateChanged:
            // A named fusion construct latched (US-C9 F7, US-C10 F1, US-C11 F3). Route by
            // the construct's OWN id (US-C11): the earlier evidence-signature heuristic
            // misroutes any construct whose signals overlap another's — F3's blink family
            // has no `.cancelRate`, so it would have fallen through to F1's composure
            // template. The `constructID` carried on the event fixes that at the source.
            switch event.constructID {
            case ConstructID.frustration:
                text = HonestyPhrases.frustration(confidence: event.confidence)
            case ConstructID.composure:
                text = HonestyPhrases.composure(confidence: event.confidence)
            case ConstructID.cognitiveLoad:
                // F2 Cognitive load (US-D14a) — the attribution sentence BUILT from the
                // present, contributing signals (effort/load language only, never "stress").
                text = HonestyPhrases.cognitiveLoad(evidence: event.evidence, confidence: event.confidence)
            case ConstructID.frownHeadDown:
                // F4 Frown+head-down (US-D14a) — the hedged LEAN, recovered from the discrete
                // `F4Lean` code the hub forwarded on `baselineDelta`. Never a discrete label.
                let lean = F4Lean(rawValue: event.baselineDelta ?? 0) ?? .ambiguous
                text = HonestyPhrases.frownHeadDown(lean: lean, evidence: event.evidence,
                                                    confidence: event.confidence)
            case ConstructID.fatigueEngagement:
                // Pole from the signed axis the hub carries on `baselineDelta`
                // (+ engaged / − alertness declining).
                let engaged = (event.baselineDelta ?? 0) >= 0
                text = HonestyPhrases.fatigueEngagement(engaged: engaged,
                                                        evidence: event.evidence,
                                                        confidence: event.confidence)
            case ConstructID.corroboratedPositivity:
                // F6 Corroborated positivity (US-D14b) — "echoed across channels", never a
                // smile-authenticity verdict. Cites the present corroborating signals.
                text = HonestyPhrases.corroboratedPositivity(evidence: event.evidence, confidence: event.confidence)
            case ConstructID.approachWithdrawal:
                // F10 Approach ⇄ Withdrawal (US-D14b) — pole from the signed axis on
                // `baselineDelta`; the §4.3 CONTEXT-SENSITIVE tie-break LEAN keys off the face
                // reading's valence (NEGATIVE ⇒ name the displeasure / dejection side; else
                // direction language only). A LEAN, never a discrete label.
                let approach = (event.baselineDelta ?? 0) >= 0
                let faceNegative = (reading?.valence ?? 0) < Self.faceNegativeThreshold
                text = HonestyPhrases.approachWithdrawal(approach: approach, faceNegative: faceNegative,
                                                         evidence: event.evidence, confidence: event.confidence)
            case ConstructID.dominance:
                // F8 Dominance display (US-D14b) — DISPLAY language only; expansion vs
                // contraction from the signed axis on `baselineDelta`.
                let expansion = (event.baselineDelta ?? 0) >= 0
                text = HonestyPhrases.dominance(expansion: expansion, evidence: event.evidence,
                                                confidence: event.confidence)
            case ConstructID.expansiveDisplay:
                // F9 Expansive display (US-D14b) — head-only display; "pride" only as a hedged
                // gloss, NO power-pose causal claim.
                text = HonestyPhrases.expansiveDisplay(evidence: event.evidence, confidence: event.confidence)
            case ConstructID.covertArousal:
                // F5 Corroborated arousal (US-D14b) — multiple non-face channels agree; a level,
                // never a direction or a feeling, never "concealment".
                text = HonestyPhrases.covertArousal(evidence: event.evidence, confidence: event.confidence)
            default:
                // nil (pre-US-C11 traces) or an unknown id ⇒ the safe legacy fallback by
                // evidence signature (frustration cites interaction friction; else composure).
                if event.evidence.contains(.cancelRate) {
                    text = HonestyPhrases.frustration(confidence: event.confidence)
                } else {
                    text = HonestyPhrases.composure(confidence: event.confidence)
                }
            }
        default:
            text = HonestyPhrases.generic(kind: event.kind,
                                          evidence: event.evidence,
                                          confidence: event.confidence)
        }
        return InsightEntry(id: event.id,
                            t: event.t,
                            text: text,
                            kind: event.kind,
                            evidence: event.evidence,
                            confidence: event.confidence)
    }
}
