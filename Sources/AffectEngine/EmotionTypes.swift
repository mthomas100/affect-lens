//
//  EmotionTypes.swift
//  AffectLens
//
//  Core emotion model: the eight basic-emotion classes (Ekman 7 + neutral),
//  probability distributions over them, and timestamped engine readings.
//

import SwiftUI

/// The emotion classes recognized by the engine (Ekman's basic emotions + contempt + neutral).
nonisolated enum Emotion: String, CaseIterable, Codable, Sendable, Identifiable {
    case neutral
    case happiness
    case sadness
    case surprise
    case fear
    case anger
    case disgust
    case contempt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neutral: return "Neutral"
        case .happiness: return "Happy"
        case .sadness: return "Sad"
        case .surprise: return "Surprised"
        case .fear: return "Afraid"
        case .anger: return "Angry"
        case .disgust: return "Disgusted"
        case .contempt: return "Contempt"
        }
    }

    var emoji: String {
        switch self {
        case .neutral: return "😐"
        case .happiness: return "😄"
        case .sadness: return "😢"
        case .surprise: return "😲"
        case .fear: return "😨"
        case .anger: return "😠"
        case .disgust: return "🤢"
        case .contempt: return "😏"
        }
    }

    var color: Color {
        switch self {
        case .neutral: return Color(white: 0.75)
        case .happiness: return .yellow
        case .sadness: return .blue
        case .surprise: return .orange
        case .fear: return .purple
        case .anger: return .red
        case .disgust: return .green
        case .contempt: return .teal
        }
    }

    /// Circumplex-model anchor for this emotion (valence: unpleasant −1 … +1 pleasant,
    /// arousal: calm −1 … +1 excited). Used for the probability-weighted VA estimate.
    var valenceArousal: (valence: Double, arousal: Double) {
        switch self {
        case .neutral: return (0.0, 0.0)
        case .happiness: return (0.85, 0.45)
        case .sadness: return (-0.72, -0.45)
        case .surprise: return (0.15, 0.88)
        case .fear: return (-0.75, 0.80)
        case .anger: return (-0.80, 0.72)
        case .disgust: return (-0.68, 0.35)
        case .contempt: return (-0.55, 0.18)
        }
    }

    /// A short human description of the facial evidence the engine looks for.
    var facsHint: String {
        switch self {
        case .neutral: return "Relaxed features"
        case .happiness: return "AU6+12 — cheek raise, lip corners up"
        case .sadness: return "AU1+4+15 — inner brows up, corners down"
        case .surprise: return "AU1+2+5+26 — brows up, wide eyes, jaw drop"
        case .fear: return "AU1+2+4+5+20 — raised+knit brows, stretched lips"
        case .anger: return "AU4+5+7+23 — lowered brows, tight lids and lips"
        case .disgust: return "AU9+15 — nose wrinkle, upper lip raise"
        case .contempt: return "Unilateral AU12/14 — one-sided smirk"
        }
    }
}

/// A normalized probability distribution over `Emotion`.
nonisolated struct EmotionDistribution: Sendable, Equatable, Codable {
    private(set) var probabilities: [Emotion: Double]

    static let neutralRest: EmotionDistribution = {
        var p = [Emotion: Double]()
        for e in Emotion.allCases { p[e] = e == .neutral ? 1.0 : 0.0 }
        return EmotionDistribution(normalizing: p)
    }()

    /// Builds a distribution by normalizing arbitrary non-negative scores.
    init(normalizing scores: [Emotion: Double]) {
        var clamped = [Emotion: Double]()
        for e in Emotion.allCases { clamped[e] = max(0, scores[e] ?? 0) }
        let total = clamped.values.reduce(0, +)
        if total <= .ulpOfOne {
            clamped = [:]
            for e in Emotion.allCases { clamped[e] = e == .neutral ? 1.0 : 0.0 }
        } else {
            for (k, v) in clamped { clamped[k] = v / total }
        }
        self.probabilities = clamped
    }

    /// Softmax over raw scores with inverse temperature `beta`.
    init(softmaxScores scores: [Emotion: Double], beta: Double) {
        let maxScore = scores.values.max() ?? 0
        var exps = [Emotion: Double]()
        for e in Emotion.allCases {
            exps[e] = exp(beta * ((scores[e] ?? 0) - maxScore))
        }
        self.init(normalizing: exps)
    }

    subscript(_ emotion: Emotion) -> Double {
        probabilities[emotion] ?? 0
    }

    var dominant: (emotion: Emotion, probability: Double) {
        var best: (Emotion, Double) = (.neutral, 0)
        for e in Emotion.allCases {
            let p = self[e]
            if p > best.1 { best = (e, p) }
        }
        return best
    }

    /// Emotions sorted by descending probability.
    var ranked: [(emotion: Emotion, probability: Double)] {
        Emotion.allCases
            .map { ($0, self[$0]) }
            .sorted { $0.1 > $1.1 }
    }

    /// Probability-weighted valence/arousal on the circumplex.
    var valenceArousal: (valence: Double, arousal: Double) {
        var v = 0.0, a = 0.0
        for e in Emotion.allCases {
            let p = self[e]
            let anchor = e.valenceArousal
            v += p * anchor.valence
            a += p * anchor.arousal
        }
        return (v, a)
    }

    /// Exponential-moving-average step toward `target` (alpha = weight of the new sample).
    func lerp(toward target: EmotionDistribution, alpha: Double) -> EmotionDistribution {
        let a = min(1, max(0, alpha))
        var out = [Emotion: Double]()
        for e in Emotion.allCases {
            out[e] = self[e] * (1 - a) + target[e] * a
        }
        return EmotionDistribution(normalizing: out)
    }

    /// Log-linear (product-of-experts) fusion of two distributions.
    /// `weight` is the influence of `other` (0 = ignore, 1 = only other).
    func fused(with other: EmotionDistribution, weight: Double) -> EmotionDistribution {
        let w = min(1, max(0, weight))
        let eps = 1e-4
        var out = [Emotion: Double]()
        for e in Emotion.allCases {
            let logp = (1 - w) * log(self[e] + eps) + w * log(other[e] + eps)
            out[e] = exp(logp)
        }
        return EmotionDistribution(normalizing: out)
    }
}

/// Grades a 0…1 intensity into a human adjective ("Slightly", "Very", …).
nonisolated enum EmotionIntensity {
    static func adjective(_ value: Double) -> String {
        switch value {
        case ..<0.18: return "Barely"
        case ..<0.38: return "Slightly"
        case ..<0.62: return "Moderately"
        case ..<0.82: return "Very"
        default: return "Extremely"
        }
    }
}

/// One timestamped output of the emotion engine.
nonisolated struct EmotionReading: Sendable, Codable {
    var date: Date
    var distribution: EmotionDistribution
    /// The hysteresis-stabilized dominant emotion (what the UI should announce).
    var dominant: Emotion
    /// Smoothed probability of `dominant`.
    var confidence: Double
    /// 0…1 strength of the dominant emotion's facial evidence — how HARD the
    /// expression is being made, independent of how SURE the classifier is.
    /// (For neutral this is overall expression energy, ≈0 at rest.)
    var intensity: Double
    /// Smoothed raw evidence score per emotion (geometric expert, pre-softmax).
    var intensities: [Emotion: Double]
    var valence: Double
    var arousal: Double
    var faceDetected: Bool
    /// 0…1 heuristic quality of the current evidence (landmark confidence × pose penalty).
    var quality: Double

    static let empty = EmotionReading(
        date: .distantPast,
        distribution: .neutralRest,
        dominant: .neutral,
        confidence: 0,
        intensity: 0,
        intensities: [:],
        valence: 0,
        arousal: 0,
        faceDetected: false,
        quality: 0
    )
}

/// Compact history sample for the timeline UI.
nonisolated struct EmotionSample: Sendable, Identifiable {
    let id: UUID
    let date: Date
    let emotion: Emotion
    let confidence: Double

    init(date: Date, emotion: Emotion, confidence: Double) {
        self.id = UUID()
        self.date = date
        self.emotion = emotion
        self.confidence = confidence
    }
}
