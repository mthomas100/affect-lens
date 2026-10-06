//
//  FusionWeighting.swift
//  AffectLens
//
//  Pure fusion-weighting math (US-C8, PRD v2 §5.1 L2 / §5.4). Three deterministic,
//  `nonisolated` helpers the face pipeline threads its own signals through:
//
//    • ChannelConfidence — the per-channel confidence algebra c_k (§5.4).
//    • DynamicFaceWeight — Aviezer dynamic weighting of the categorical pool's
//      FER+ weight, plus Guo-2017 temperature scaling of FER+, plus the pure
//      weight-selection rule the engine mirrors.
//    • EmotionDistribution.normalizedEntropy — the geometry-ambiguity signal.
//
//  SEAM-A VETO (PRD §5.1 / §7.2): the categorical 8-class log-opinion pool is
//  FACE-ONLY. Every input to `DynamicFaceWeight` is derived from the face lens
//  (geometry expression-energy, geometry entropy, the FER+ expert's own
//  confidence). Non-face channels NEVER enter this pool — they influence only the
//  dimensional (valence/arousal) track, via `EmotionEngine.vaTransform`, in later
//  items.
//
//  All types are `nonisolated` value types (the project defaults new types to
//  MainActor) so the math is deterministic and self-testable off the main actor.
//

import Foundation

#if os(visionOS) || os(macOS)

/// The engine's circumplex pair — structurally the tuple
/// `EmotionDistribution.valenceArousal` already returns. A named alias so the
/// dimensional-combine hook (`EmotionEngine.vaTransform`) and its `combineVA`
/// routing read cleanly.
typealias ValenceArousal = (valence: Double, arousal: Double)

/// The per-channel **confidence algebra** (PRD v2 §5.4):
///
///   c_k = q_cal,k · a_k · exp(−Δt_k / τ_k) · q_data,k
///
/// One computation that flows THREE ways (§5.4):
///   1. into the dimensional filter as the observation noise `R_k = σ²/max(c_k, ε)`;
///   2. as a per-axis **meter half-width** (the uncertainty band widens as c_k falls);
///   3. as the categorical log-pool **reliability weight** `r_k`.
///
/// Pure, clamped to [0, 1]. `availability` maps to a_k ∈ {live 1, degraded ½,
/// unavailable 0} — an unavailable channel contributes ZERO confidence, i.e. its
/// reliability drops to identity in the pool (§8.1 US-C8 acceptance criterion).
nonisolated struct ChannelConfidence {

    /// `c_k = q_cal · a · exp(−Δt/τ) · q_data`, clamped to [0, 1].
    /// - `calibrationQuality`, `dataQuality`: 0…1 (clamped defensively).
    /// - `availability`: sets a ∈ {1, ½, 0}.
    /// - `secondsSinceUpdate` (Δt), `tau` (τ): recency = `exp(−Δt/τ)`, 1 at Δt=0,
    ///   halving every `τ·ln2`. A non-positive τ means "no memory" (Δt>0 ⇒ 0).
    static func confidence(
        calibrationQuality: Double,
        availability: ChannelAvailability,
        secondsSinceUpdate: Double,
        tau: Double,
        dataQuality: Double
    ) -> Double {
        let a: Double
        switch availability {
        case .live: a = 1.0
        case .degraded: a = 0.5
        case .unavailable: a = 0.0
        }
        let dt = max(0, secondsSinceUpdate)
        let recency: Double
        if tau > 0 {
            recency = exp(-dt / tau)
        } else {
            recency = dt > 0 ? 0 : 1
        }
        let c = clamp01(calibrationQuality) * a * recency * clamp01(dataQuality)
        return clamp01(c)
    }

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

/// **Dynamic weighting of the categorical pool's FER+ weight** (Aviezer, Trope &
/// Todorov 2012, *Science* 338:1225) + **Guo 2017 temperature scaling**.
///
/// Aviezer's finding: at PEAK expressive intensity, isolated faces fall to near
/// chance — the discriminating signal moves off the face. Non-face channels can't
/// enter this 8-class pool (seam-a veto), so the honest in-pool analog is: as the
/// face's detected **intensity** and/or the geometry classifier's **ambiguity**
/// rise, trust the single-frame GEOMETRY prototype match LESS and lean toward the
/// appearance expert (FER+) — but only insofar as FER+ is itself confident this
/// frame. At rest (low intensity AND low ambiguity) the weight is EXACTLY today's
/// constant `base` (0.35), so the default reading is unchanged.
nonisolated enum DynamicFaceWeight {

    /// Reliability clamp for FER+'s contribution to the categorical pool. The pool
    /// must never collapse the per-user-calibrated geometry expert (floor) nor let a
    /// single generic appearance model dominate it (ceiling). `base` (0.35, today's
    /// `mlFusionWeight`) sits inside this range; the modulation's natural span is
    /// [base, maxWeight], and `minWeight` is the defensive floor.
    static let minWeight = 0.15
    static let maxWeight = 0.55

    /// The Aviezer modulation. Monotone NON-DECREASING in `faceIntensity`,
    /// `faceAmbiguity`, and `mlConfidence`; result clamped to
    /// [`minWeight`, `maxWeight`]. At zero drive (`faceIntensity == 0` AND
    /// `faceAmbiguity == 0`) it returns `base` EXACTLY — the byte-identical anchor.
    ///
    /// - Parameters:
    ///   - base: the resting FER+ weight (`mlFusionWeight`, 0.35).
    ///   - faceIntensity: 0…1 overall facial expression energy (how hard the face is
    ///     emoting — the engine's `smoothedEnergy`).
    ///   - faceAmbiguity: 0…1 geometry-distribution ambiguity (its `normalizedEntropy`).
    ///   - mlConfidence: 0…1 FER+ self-confidence (its distribution's peak probability).
    static func mlWeight(
        base: Double,
        faceIntensity: Double,
        faceAmbiguity: Double,
        mlConfidence: Double
    ) -> Double {
        // Aviezer drive: peak intensity OR ambiguity (AND/OR ⇒ the stronger cue).
        let drive = max(clamp01(faceIntensity), clamp01(faceAmbiguity))
        // "…only insofar as ML confidence supports it": damp the lean by FER+'s own
        // peak probability, so a flat/uncertain FER+ read can't override a sharp
        // per-user geometry read.
        let lean = drive * clamp01(mlConfidence)
        // Push UP from base toward the ceiling; never past it, never below the floor.
        let weight = base + lean * (maxWeight - base)
        return min(maxWeight, max(minWeight, weight))
    }

    /// The engine's weight-SELECTION rule, as a pure function (US-C8 self-test).
    /// Returns `base` (0.35) verbatim when dynamic weighting is disabled — the
    /// byte-identical default — and the Aviezer `mlWeight` when enabled. The engine
    /// INLINES this same guard so the disabled path evaluates neither the geometry
    /// entropy nor `mlWeight`; this twin exists so the rule is directly testable.
    static func effectiveMLWeight(
        dynamicEnabled: Bool,
        base: Double,
        faceIntensity: Double,
        faceAmbiguity: Double,
        mlConfidence: Double
    ) -> Double {
        guard dynamicEnabled else { return base }
        return mlWeight(base: base, faceIntensity: faceIntensity,
                        faceAmbiguity: faceAmbiguity, mlConfidence: mlConfidence)
    }

    /// **Guo 2017 temperature scaling** of a distribution: `p_i^(1/T)` renormalized.
    /// `T == 1` ⇒ identity; `T > 1` flattens (raises entropy — less confident);
    /// `T < 1` sharpens (lowers entropy). Applied to FER+ BEFORE it enters the
    /// categorical pool so its confidence — and hence the reliability weight — means
    /// what it says. Numerically safe: `p_i ∈ [0,1]`, `pow(0, 1/T)=0` for `T>0`, and
    /// `EmotionDistribution(normalizing:)` handles the (guarded) all-zero case.
    /// `T ≤ 0` ⇒ identity.
    static func temperatured(_ dist: EmotionDistribution, T: Double) -> EmotionDistribution {
        guard T > 0, T != 1 else { return dist }
        let invT = 1.0 / T
        var scaled = [Emotion: Double]()
        for e in Emotion.allCases {
            scaled[e] = pow(dist[e], invT)
        }
        return EmotionDistribution(normalizing: scaled)
    }

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

extension EmotionDistribution {
    /// Shannon entropy normalized to [0, 1] — 0 for a one-hot (fully committed)
    /// distribution, 1 for the uniform distribution over `Emotion.allCases`. The
    /// engine uses it as the geometry classifier's **ambiguity** signal for dynamic
    /// weighting (higher ⇒ less committed ⇒ lean more on the appearance expert).
    /// Pure and additive. `nonisolated` (this file's math is deliberately off-main —
    /// see the file header) so the nonisolated `TraceReplayer.replaySeries` A/B re-fusion
    /// can read it; every existing MainActor caller is unaffected.
    nonisolated var normalizedEntropy: Double {
        let n = Emotion.allCases.count
        guard n > 1 else { return 0 }
        var h = 0.0
        for e in Emotion.allCases {
            let p = self[e]
            if p > 0 { h -= p * log(p) }
        }
        return min(1, max(0, h / log(Double(n))))
    }
}

#endif
