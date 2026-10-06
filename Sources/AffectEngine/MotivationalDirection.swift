//
//  MotivationalDirection.swift
//  AffectLens
//
//  The motivational-DIRECTION primitive (US-D14a, PRD v2 §4.3) — a genuinely new
//  cross-cutting axis that is DISSOCIABLE from valence (Harmon-Jones & Allen 1998;
//  Carver & Harmon-Jones 2009): anger is negative-valence but APPROACH-motivated, while
//  sadness / shame are WITHDRAWAL. When the face reads "negative" but can't say WHICH,
//  motor-energy + head-orientation splits anger from sadness — the branch valence alone
//  cannot make. Built REUSABLE on purpose: it underpins step 2 of the F4 frown+head-down
//  ladder today, and F10 Approach/Withdrawal (next item) + F9 consume it unchanged.
//
//  HONESTY / LIMITS. This is a coarse behavioral read, not a felt state. It maps three
//  optional, per-user-normalized cues to a single signed lean in [−1, +1]:
//    • +1 APPROACH   = head level / forward + HIGH motor + expansive gesture;
//    • −1 WITHDRAWAL = head-down / turned-away + LOW motor + collapsed gesture.
//  It is CONSULTED inside a negative-affect disambiguation (a frown is already present),
//  which is what licenses "low motor ⇒ withdrawal" — outside that context low motor is
//  merely calm. Callers pass only what they have; MISSING cues degrade gracefully (fewer
//  voters ⇒ a weaker magnitude, pulled toward 0), and a missing cue can NEVER fabricate a
//  direction (its weight simply drops out of the numerator while the denominator holds).
//

import Foundation

#if os(visionOS) || os(macOS)

/// The pure, `nonisolated` motivational-direction blend (PRD v2 §4.3). A total function
/// over its optional inputs — no state, no I/O — so it is self-testable off the main actor
/// and reusable by any construct, per the project's MainActor-default regime.
nonisolated enum MotivationalDirection {

    // MARK: Cue weights (the fixed reliability vector — documented)

    /// Head orientation is the most DIRECT approach/withdrawal cue (the two innate displays
    /// are head-defined; §3.4), so it carries the most weight; motor energy is next; gesture
    /// expansiveness is the lightest (noisiest, hands-only) support.
    static let headWeight = 1.0
    static let motorWeight = 0.8
    static let gestureWeight = 0.5
    /// The FIXED denominator = the sum of ALL three cue weights. Dividing by the fixed total
    /// (not by the present-weight sum) is what makes a MISSING cue shrink the magnitude
    /// toward 0 instead of being silently renormalized away — "fewer voters ⇒ weaker lean."
    static let totalWeight = headWeight + motorWeight + gestureWeight

    // MARK: The blend

    /// Map three optional per-user-normalized cues to a signed lean in [−1, +1]
    /// (+ approach / − withdrawal). Each present cue casts a vote in [−1, +1]:
    ///   • `motorEnergy` ∈ [0, 1] (0 still … 1 briskly moving) → `2·x − 1` (HIGH ⇒ approach,
    ///     LOW ⇒ withdrawal). `nil` = the cue is absent (NOT zero motor) and simply doesn't vote.
    ///   • `headLean` ∈ [−1, +1] is ALREADY signed (the head channel's gaze-gated
    ///     `dominanceLean`: + head-back/level/expansion, − head-down/turned-away) → used directly.
    ///   • `gestureRate` ∈ [0, 1] (0 collapsed … 1 expansive) → `2·x − 1`. `nil` = absent.
    /// The present votes are combined as a reliability-weighted sum over the FIXED total
    /// weight, then squashed through `tanh` for a smooth, bounded lean that never quite
    /// saturates (a lean is never a certainty). All-nil ⇒ 0 (no evidence, no fabricated lean).
    ///
    /// - Returns: the signed motivational direction in [−1, +1] (approach positive).
    static func direction(motorEnergy: Double?, headLean: Double?, gestureRate: Double?) -> Double {
        var weightedSum = 0.0
        if let motor = motorEnergy { weightedSum += motorWeight * (2 * clamp01(motor) - 1) }
        if let head = headLean     { weightedSum += headWeight * clamp(head, -1, 1) }
        if let gesture = gestureRate { weightedSum += gestureWeight * (2 * clamp01(gesture) - 1) }
        // Fixed-denominator normalization (missing voters shrink the magnitude), then a gentle
        // bounded squash. `tanh` is ≈ identity for small leans and softens toward the extremes.
        return tanh(weightedSum / totalWeight)
    }

    // MARK: Helpers

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
}

#endif
