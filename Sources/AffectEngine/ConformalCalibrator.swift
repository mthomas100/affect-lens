//
//  ConformalCalibrator.swift
//  AffectLens
//
//  Split-conformal APS prediction sets + Lin's concordance (US-E17, PRD v2 §5.4 /
//  §9.1 M6). Pure, `nonisolated`, deterministic math — no I/O, no actor state — so
//  the whole thing is CI-gradable off-device (the DEBUG self-tests replay it).
//
//  WHY THIS EXISTS (PRD §5.4): the face classifier's top-1 label is often a false
//  certainty. Split-conformal APS (Adaptive Prediction Sets, Angelopoulos & Bates)
//  wraps the posterior into a calibrated SET — "likely {calm, focused}" — that
//  covers the true label with probability ≥ 1−α, PER USER. The catch: the app's
//  36-sample calibration ritual only ever labels NEUTRAL, so the NON-neutral
//  calibration data can only come from the ESM ground-truth loop (a user tapping how
//  they actually feel → an `HKStateOfMind`-mapped label paired with the posterior
//  snapshot at report time). Hence this file consumes `SelfReport`s.
//
//  HONESTY LAW: this is a per-USER, on-device calibration. Coverage is "for THIS
//  user" — never a population accuracy claim (PRD §9.1 M6). Below the min-sample
//  gate the calibrator reports `.uncalibrated` and the UI keeps its margin heuristic
//  (`MultiLabelChip.topLabels`); it never fabricates a calibrated set from too few
//  points.
//

#if os(visionOS) || os(macOS)

import Foundation

// MARK: - Split-conformal APS

/// Split-conformal Adaptive Prediction Sets over the 8-class emotion posterior
/// (Romano, Sesia & Candès 2020; Angelopoulos & Bates tutorial). Pure static math.
///
/// The three moving parts, all documented inline:
///  • **score** — the APS non-conformity score of a (posterior, true-label) pair:
///    the cumulative posterior mass, taken in DESCENDING probability order, up to
///    AND INCLUDING the true label. A confident-correct posterior scores low; a
///    posterior that buried the truth scores high.
///  • **calibrate** — `qhat` = the `⌈(n+1)(1−α)⌉/n` empirical quantile of the
///    calibration scores (the finite-sample-corrected conformal quantile).
///  • **predict** — the smallest label set, again in descending order, whose
///    cumulative mass reaches `qhat`. That set covers the truth with prob ≥ 1−α.
nonisolated enum ConformalCalibrator {

    /// Miscoverage level. α = 0.1 ⇒ a 90% coverage target (PRD §9.1 M6's "90%
    /// coverage"). Documented default; overridable for the self-test's sweep.
    static let alpha = 0.1

    /// Minimum mappable calibration pairs before a set is trustworthy. Below this the
    /// finite-sample conformal quantile is too coarse to mean 90% (with n < 20 the
    /// `⌈(n+1)·0.9⌉`-th order statistic jumps in >5% steps), so we stay `.uncalibrated`
    /// and the UI falls back to the margin heuristic. 20 is the documented floor.
    static let minSamples = 20

    /// One calibration example: a posterior snapshot paired with the user's
    /// self-reported (ground-truth) emotion.
    nonisolated struct Pair: Sendable, Equatable {
        var posterior: EmotionDistribution
        var trueLabel: Emotion
    }

    /// The calibrator's state: either not-yet-trustworthy (carrying how many mappable
    /// pairs exist, for the "n / 20" progress copy) or calibrated (carrying `qhat`
    /// and the sample count `n` behind it).
    nonisolated enum Status: Sendable, Equatable {
        case uncalibrated(mappablePairs: Int)
        case calibrated(qhat: Double, n: Int)

        var isCalibrated: Bool {
            if case .calibrated = self { return true }
            return false
        }
    }

    /// APS non-conformity score: cumulative posterior mass (descending) up to and
    /// including `trueLabel`. `EmotionDistribution.ranked` covers all 8 classes, so
    /// the true label is always reached; ties are broken by `ranked`'s sort order
    /// (immaterial to coverage). Range (0, 1].
    static func score(_ posterior: EmotionDistribution, trueLabel: Emotion) -> Double {
        var cumulative = 0.0
        for (emotion, probability) in posterior.ranked {
            cumulative += probability
            if emotion == trueLabel { return cumulative }
        }
        return cumulative   // unreachable: `ranked` enumerates every case
    }

    /// The smallest prefix of the DESCENDING-probability ranking whose cumulative mass
    /// reaches `qhat` — the APS prediction set for a new posterior. `qhat ≥ 1` (the
    /// clamp case below) returns the full set; `qhat ≤ 0` returns the single top label.
    /// Never empty for a valid posterior.
    static func predict(_ posterior: EmotionDistribution, qhat: Double) -> [Emotion] {
        var cumulative = 0.0
        var set: [Emotion] = []
        for (emotion, probability) in posterior.ranked {
            set.append(emotion)
            cumulative += probability
            if cumulative >= qhat { break }
        }
        return set
    }

    /// Fit `qhat` from calibration pairs. Returns `.uncalibrated(mappablePairs:)` below
    /// `minSamples`, else `.calibrated(qhat:n:)`.
    ///
    /// `qhat` is the `k`-th smallest score where `k = ⌈(n+1)(1−α)⌉` (1-indexed) — the
    /// split-conformal quantile with the `+1` finite-sample correction. When `k > n`
    /// (possible only for tiny n / tiny α) the quantile is +∞ in theory; we clamp to
    /// `1.0`, i.e. the always-covers full set.
    static func calibrate(_ pairs: [Pair],
                          alpha: Double = alpha,
                          minSamples: Int = minSamples) -> Status {
        let n = pairs.count
        guard n >= minSamples else { return .uncalibrated(mappablePairs: n) }

        let scores = pairs.map { score($0.posterior, trueLabel: $0.trueLabel) }.sorted()
        let k = Int((Double(n + 1) * (1 - alpha)).rounded(.up))
        let qhat = k > n ? 1.0 : scores[min(max(k, 1), n) - 1]
        return .calibrated(qhat: qhat, n: n)
    }

    /// Build calibration pairs from ESM self-reports: keep only reports that carry BOTH
    /// a posterior snapshot (taken at report time) AND a mappable primary label. Reports
    /// with no face at report time (nil posterior) or no mappable label are excluded —
    /// never imputed. This is the "non-neutral conformal set comes from ESM labels"
    /// path (PRD §5.4 / §5.7).
    static func pairs(from reports: [SelfReport]) -> [Pair] {
        reports.compactMap { report in
            guard let posterior = report.inferredPosterior,
                  let label = report.primaryEmotion else { return nil }
            return Pair(posterior: posterior, trueLabel: label)
        }
    }
}

// MARK: - Lin's concordance correlation coefficient (CCC)

/// Lin's (1989) concordance correlation coefficient — the honest per-user
/// agreement metric between INFERRED valence and SELF-REPORTED valence (PRD §9.1 M6:
/// "for THIS user, valence tracks self-report at CCC 0.5"). CCC rewards agreement on
/// the 45° line (both correlation AND calibration), unlike Pearson's r which ignores
/// bias/scale — the right tool for "does my estimate match how you actually feel."
///
/// `CCC = 2·s_xy / (s_x² + s_y² + (x̄ − ȳ)²)` with POPULATION moments (÷n), exactly
/// as Lin 1989 defines it. Pure; `nil` under 3 pairs or when there is no variance to
/// concord (a degenerate denominator).
nonisolated enum Concordance {
    /// - Returns: the CCC in [−1, 1], or `nil` when `x`/`y` differ in length, have
    ///   fewer than 3 pairs, or have a zero denominator (no spread + equal means).
    static func ccc(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n

        var varX = 0.0, varY = 0.0, cov = 0.0
        for i in x.indices {
            let dx = x[i] - meanX
            let dy = y[i] - meanY
            varX += dx * dx
            varY += dy * dy
            cov += dx * dy
        }
        varX /= n; varY /= n; cov /= n

        let denominator = varX + varY + (meanX - meanY) * (meanX - meanY)
        guard denominator > 0 else { return nil }   // nothing varies ⇒ concordance undefined
        return 2 * cov / denominator
    }
}

#endif
