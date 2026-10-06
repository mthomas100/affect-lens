//
//  EmotionClassifier.swift
//  AffectLens
//
//  EMFACS-style emotion scoring: each basic emotion is defined as a weighted
//  combination of FACS Action Units (its "prototype"), with inhibitor AUs
//  that argue against it. Scores are converted to a probability distribution
//  with a softmax. Pure and deterministic — exercised by EmotionSelfTests.
//

import Foundation

#if os(visionOS) || os(macOS)

enum EmotionClassifier {

    /// One emotion's AU prototype.
    private struct Prototype {
        let emotion: Emotion
        /// AU → weight; weights of the positive evidence sum to 1.
        let evidence: [ActionUnit: Double]
        /// AU → penalty weight subtracted when contradicting AUs fire.
        let inhibitors: [ActionUnit: Double]
        /// Minimum single-AU gate: the score is scaled down unless this AU
        /// exceeds the threshold (keeps prototypes from firing on noise).
        let gate: (unit: ActionUnit, threshold: Double)?
    }

    /// EMFACS prototypes for the seven expressive emotions.
    private static let prototypes: [Prototype] = [
        Prototype(
            emotion: .happiness,
            evidence: [.au12: 0.65, .au6: 0.35],
            inhibitors: [.au4: 0.30, .au15: 0.40],
            gate: (.au12, 0.15)
        ),
        Prototype(
            emotion: .sadness,
            evidence: [.au15: 0.45, .au1: 0.30, .au4: 0.25],
            inhibitors: [.au12: 0.60, .au5: 0.20],
            gate: (.au15, 0.10)
        ),
        Prototype(
            emotion: .surprise,
            evidence: [.au1: 0.15, .au2: 0.25, .au5: 0.30, .au26: 0.30],
            inhibitors: [.au4: 0.40, .au12: 0.20],
            gate: nil
        ),
        Prototype(
            emotion: .fear,
            evidence: [.au5: 0.25, .au20: 0.30, .au4: 0.20, .au1: 0.15, .au26: 0.10],
            inhibitors: [.au12: 0.40],
            gate: (.au5, 0.10)
        ),
        Prototype(
            emotion: .anger,
            evidence: [.au4: 0.40, .au7: 0.25, .au23: 0.25, .au5: 0.10],
            inhibitors: [.au1: 0.30, .au12: 0.50, .au26: 0.20],
            gate: (.au4, 0.15)
        ),
        Prototype(
            emotion: .disgust,
            evidence: [.au9: 0.45, .au15: 0.25, .au4: 0.15, .au7: 0.15],
            inhibitors: [.au12: 0.40, .au5: 0.20],
            gate: (.au9, 0.12)
        ),
        Prototype(
            emotion: .contempt,
            evidence: [.auUnilateral: 0.80, .au23: 0.20],
            inhibitors: [.au26: 0.30, .au25: 0.20],
            gate: (.auUnilateral, 0.15)
        ),
    ]

    /// AUs that represent strong deliberate expression (drive the neutral score down).
    /// `.auUnilateral` (the contempt smirk) is included so a one-sided expression
    /// registers as energy — without it a pure smirk reads as a neutral face.
    private static let energyUnits: [ActionUnit] = [
        .au12, .au15, .au4, .au5, .au9, .au20, .au23, .au26, .au1, .au2, .auUnilateral,
    ]

    /// Softmax inverse temperature: higher = sharper distribution.
    static let beta = 4.5

    /// Raw prototype match scores in 0…1 for each emotion (before softmax).
    static func scores(for au: AUVector) -> [Emotion: Double] {
        func a(_ unit: ActionUnit) -> Double { au[unit] ?? 0 }

        var scores = [Emotion: Double]()

        for p in prototypes {
            var s = 0.0
            for (unit, w) in p.evidence { s += w * a(unit) }
            for (unit, w) in p.inhibitors { s -= w * a(unit) }
            if let gate = p.gate {
                // Scale down smoothly when the gating AU hasn't really fired.
                let g = min(1, a(gate.unit) / max(gate.threshold, 1e-6))
                s *= g
            }
            scores[p.emotion] = max(0, s)
        }

        // Neutral: high when overall AU energy is low.
        scores[.neutral] = max(0, 1 - 1.8 * expressionEnergy(for: au))

        return scores
    }

    /// Overall expressiveness of the face in 0…1 — how far from rest the
    /// strong AUs are, regardless of which emotion they spell.
    static func expressionEnergy(for au: AUVector) -> Double {
        let values = energyUnits.map { au[$0] ?? 0 }
        let strongest = values.max() ?? 0
        let mean = values.reduce(0, +) / Double(values.count)
        return min(1, 0.6 * strongest + 0.4 * mean)
    }

    /// Full pipeline: AU vector → probability distribution.
    static func classify(_ au: AUVector) -> EmotionDistribution {
        EmotionDistribution(softmaxScores: scores(for: au), beta: beta)
    }
}
#endif
