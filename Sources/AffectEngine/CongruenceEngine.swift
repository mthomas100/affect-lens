//
//  CongruenceEngine.swift
//  AffectLens
//
//  THE CONGRUENCE / INCONGRUENCE ENGINE (US-C10a, PRD v2 §4.4) — channel agreement
//  as a first-class COMPUTED SCALAR. This is the literal "greater than the sum":
//  consensus tightens confidence, divergence becomes a NAMED state that is never
//  averaged away.
//
//  It ships the FIRST TWO options of §4.4 (OQ8), and ONLY those two — no
//  Dempster-Shafer / TMC (deferred):
//    (1) reliability-weighted SIGN / GRADIENT consensus on the shared AROUSAL axis
//        — each channel emits a signed delta a_k ∈ [−1, 1] (sign = direction vs the
//        channel's own per-user baseline) with reliability r_k; do the signs agree?
//    (2) windowed SYNCHRONY — cosine similarity of the channels' mean-centered
//        arousal-delta trajectories over a sliding window; a sustained DROP is a
//        divergence EVENT (DeCon PMC4016122; UVS/CIAS MDPI 2025 10(3):88) that wakes
//        the narrator and composes with the BOCPD `.stateShift` bus.
//
//  HONESTY LAW (§4.4): named divergence states, NEVER "concealment", and this engine
//  NEVER averages valence across a split — it operates purely on the shared AROUSAL
//  axis (valence is the face's alone, §2 master law). It COMPUTES and DISPLAYS
//  agreement; it does NOT (yet) change any fused reading — `EmotionEngine.vaTransform`
//  stays nil and the pad's main dot stays today's face V/A.
//
//  PURITY / ISOLATION: a `nonisolated struct` mutated on whatever actor holds it
//  (the MainActor `AffectHub`), exactly like `ChangePointDetector` — so the math is
//  deterministic and self-testable off the main actor (the project defaults new
//  types to MainActor; this opts out).
//

#if os(visionOS) || os(macOS)

import Foundation

// MARK: - Value types

/// One channel's arousal vote (US-C10a). The MINIMAL honest per-channel input to
/// cross-channel consensus: a signed direction on the shared arousal axis, plus how
/// much to trust it this tick.
nonisolated struct ChannelVote: Sendable, Codable, Equatable {
    /// `a_k ∈ [−1, 1]`. Sign = direction vs the channel's OWN per-user baseline
    /// (`+` = more activated than the user's resting/neutral, `−` = calmer);
    /// magnitude = strength after the channel's documented squash. This is a DELTA,
    /// not an absolute circumplex arousal coordinate.
    var signedArousalDelta: Double
    /// `r_k ∈ [0, 1]` — the channel's reliability THIS tick (from `ChannelConfidence`:
    /// availability × calibration × data quality). A channel with `r_k == 0` does not
    /// vote — it is EXCLUDED from consensus (one dark channel changes nothing).
    var reliability: Double
}

/// The direction the voting channels agree on along the shared arousal axis.
nonisolated enum ConsensusDirection: String, Sendable, Codable, Equatable {
    /// Net reliability-weighted arousal moving UP (more activated).
    case rising
    /// Net reliability-weighted arousal moving DOWN (calmer).
    case falling
    /// Net move within the flat band — agreeing on "no meaningful change".
    case flat
    /// Undefined — fewer than two channels are voting.
    case unknown
}

/// The NAMED agreement state (mapping documented on `CongruenceEngine`). A DESIGNED
/// vocabulary, not a smooth scalar — so the UI and narrator can speak plainly.
nonisolated enum NamedCongruence: String, Sendable, Codable, Equatable {
    /// Fewer than two voting channels — one voice is not agreement (a designed state,
    /// NOT an error: the ring shows no judgment).
    case insufficient
    /// High reliability-weighted sign consensus, not in a sustained divergence.
    case agreeing
    /// Partial agreement — some consensus, but below the "agreeing" bar.
    case mixed
    /// A SUSTAINED (hysteretic) synchrony divergence — the channels are pulling
    /// different ways on arousal. NEVER framed as concealment (§4.4).
    case diverging
}

/// The full congruence read for one tick — `Codable` so it can ride the golden-trace
/// fixture, `Equatable` so the hub only republishes it on a real change.
nonisolated struct CongruenceState: Sendable, Codable, Equatable {
    /// Reliability-weighted sign agreement ∈ [0, 1] (1 = all same sign, 0 = perfectly
    /// opposed). `nil` when fewer than two channels vote (nothing to agree ABOUT).
    var consensus: Double?
    /// The agreed direction on the arousal axis.
    var direction: ConsensusDirection
    /// Windowed cosine-synchrony scalar ∈ [−1, 1]; `nil` until a channel pair has
    /// enough co-observed history to correlate.
    var synchrony: Double?
    /// The per-channel votes retained for display (ghost dots + reliability-driven
    /// opacity). Empty in the `.insufficient` state (nothing worth displaying as a
    /// cross-channel vote); the voting channels otherwise.
    var votes: [Channel: ChannelVote]
    /// The named agreement state.
    var named: NamedCongruence

    /// The designed "no judgment" state — fewer than two voters.
    static let insufficient = CongruenceState(
        consensus: nil, direction: .unknown, synchrony: nil, votes: [:], named: .insufficient
    )
}

/// One tick's output from the engine: the new state plus the two RISING-EDGE flags
/// the hub turns into bus events (so edge detection lives in the pure, testable core,
/// not the hub).
nonisolated struct CongruenceUpdate: Sendable, Equatable {
    var state: CongruenceState
    /// A sustained synchrony divergence just LATCHED this tick — fire `.congruenceBreak`
    /// exactly once (mirrors the BOCPD cooldown idiom).
    var divergenceBegan: Bool
    /// Strong sign-consensus just onset this tick (crossed the agreeing bar with ≥2
    /// voters, not diverging) — fire `.arousalConsensus`.
    var agreementBegan: Bool
}

// MARK: - Engine

/// The congruence engine (US-C10a, PRD v2 §4.4). Fed one `[Channel: ChannelVote]`
/// per tick; emits a `CongruenceUpdate`. Pure value type — all state is here, mutated
/// through `update`.
///
/// NAMED-STATE MAPPING (documented):
///   • `< 2` voting channels                → `.insufficient` (consensus `nil`)
///   • a sustained synchrony divergence is LATCHED (option 2) → `.diverging`
///   • else `consensus ≥ agreeingThreshold` → `.agreeing`
///   • else                                 → `.mixed`
/// `.diverging` is deliberately coupled to the HYSTERETIC synchrony latch, not a
/// single-tick consensus dip: divergence is a SUSTAINED phenomenon (a momentary
/// opposite-sign tick reads `.mixed`), which is why it fires the narrator only once.
nonisolated struct CongruenceEngine {

    // MARK: Configuration (documented constants)

    /// |net reliability-weighted arousal| below this reads as `.flat` direction
    /// (agreeing on ~no change) rather than rising/falling.
    var flatBand: Double = 0.08
    /// consensus ≥ this (with ≥2 voters, not diverging) ⇒ `.agreeing`, and drives the
    /// `.arousalConsensus` onset event.
    var agreeingThreshold: Double = 0.6

    /// Sliding-window span for the synchrony trajectories (~12 s). At the app's ~15 Hz
    /// analysis cadence that is ~180 samples; pruned by age, and hard-capped at
    /// `maxSamples` so memory is bounded regardless of session length (the
    /// `ChangePointDetector.maxRun` idiom).
    var windowDuration: TimeInterval = 12
    /// Hard cap on retained trajectory ticks (bounded memory; ~12 s @ 15 Hz ≈ 180,
    /// with head-room).
    var maxSamples: Int = 300
    /// A channel PAIR needs at least this many co-observed ticks before its cosine
    /// counts toward synchrony (a handful of frames can't establish covariation).
    var minPairSamples: Int = 6

    /// Synchrony must DROP to ≤ this (uncorrelated-or-anti-correlated) to begin a
    /// divergence, ...
    var divergenceEnter: Double = 0.0
    /// ... and must RECOVER to ≥ this to re-arm (the hysteresis band [enter, exit],
    /// mirroring the BOCPD arm/cooldown split so one divergence fires once).
    var divergenceExit: Double = 0.4
    /// Synchrony must stay ≤ `divergenceEnter` for at least this long before the
    /// divergence LATCHES and fires (a dwell, so a blip can't trip it).
    var divergenceDwell: TimeInterval = 1.0

    /// Reliabilities at or below this don't vote (`r_k == 0` exclusion, with a tiny
    /// epsilon so floating-point zeros are caught).
    private let voteEpsilon = 1e-9

    // MARK: State

    /// Per-tick co-observed votes (only ticks with ≥2 voters are recorded), pruned by
    /// age + count. Used to correlate channel-pair trajectories (option 2).
    private var history: [(date: Date, votes: [Channel: Double])] = []
    /// The hysteretic divergence latch (true while in a sustained divergence).
    private var divergenceLatched = false
    /// When synchrony first dropped ≤ `divergenceEnter` in the current dip (for the
    /// dwell); `nil` when not currently below.
    private var belowSince: Date?
    /// Rising-edge memory for the agreement-onset event.
    private var wasAgreeing = false

    init() {}

    // MARK: Update

    /// Fold one tick's votes into the engine. Channels with `reliability ≤ 0` are
    /// excluded up front. Returns the new state plus the two rising-edge event flags.
    mutating func update(votes rawVotes: [Channel: ChannelVote], at now: Date) -> CongruenceUpdate {
        // (0) Exclude non-voters (r_k == 0). One dark channel must change nothing.
        let voters = rawVotes.filter { $0.value.reliability > voteEpsilon }

        // Fewer than two voters ⇒ the DESIGNED `.insufficient` state. We cannot assess
        // agreement OR divergence, so reset the divergence hysteresis (re-arm) and the
        // agreement edge, and retain no votes (a single channel is not a cross-channel
        // vote worth displaying).
        guard voters.count >= 2 else {
            divergenceLatched = false
            belowSince = nil
            wasAgreeing = false
            return CongruenceUpdate(state: .insufficient, divergenceBegan: false, agreementBegan: false)
        }

        // (1) Reliability-weighted SIGN / GRADIENT consensus on the arousal axis.
        var weightedSum = 0.0      // Σ r_k a_k  (the signed "gradient" / net move)
        var weightedAbs = 0.0      // Σ r_k |a_k|
        var reliabilitySum = 0.0   // Σ r_k
        for v in voters.values {
            weightedSum += v.reliability * v.signedArousalDelta
            weightedAbs += v.reliability * abs(v.signedArousalDelta)
            reliabilitySum += v.reliability
        }
        // Agreement: |Σ r a| / Σ r|a| ∈ [0,1] — 1 when all deltas share a sign, 0 when
        // they perfectly cancel. When everyone is ~flat (Σ r|a| ≈ 0) the channels
        // trivially AGREE on "no change" ⇒ consensus 1, direction flat.
        let consensus: Double
        if weightedAbs < voteEpsilon {
            consensus = 1.0
        } else {
            consensus = min(1, max(0, abs(weightedSum) / weightedAbs))
        }
        let netMove = reliabilitySum > voteEpsilon ? weightedSum / reliabilitySum : 0
        let direction: ConsensusDirection =
            netMove > flatBand ? .rising : (netMove < -flatBand ? .falling : .flat)

        // (2) Windowed SYNCHRONY. Record this tick's deltas, prune, correlate the
        // channel-pair trajectories.
        history.append((date: now, votes: voters.mapValues { $0.signedArousalDelta }))
        pruneHistory(now: now)
        let synchrony = computeSynchrony(currentVoters: voters)

        // Divergence hysteresis (mirrors the BOCPD arm/dwell/cooldown idiom).
        let divergenceBegan = stepDivergence(synchrony: synchrony, now: now)

        // Named state (see the type doc for the mapping).
        let named: NamedCongruence
        if divergenceLatched {
            named = .diverging
        } else if consensus >= agreeingThreshold {
            named = .agreeing
        } else {
            named = .mixed
        }

        // Agreement ONSET: crossed into `.agreeing` this tick (rising edge), not while
        // diverging.
        let agreementBegan = (named == .agreeing) && !wasAgreeing
        wasAgreeing = (named == .agreeing)

        let state = CongruenceState(
            consensus: consensus,
            direction: direction,
            synchrony: synchrony,
            votes: voters,
            named: named
        )
        return CongruenceUpdate(state: state, divergenceBegan: divergenceBegan, agreementBegan: agreementBegan)
    }

    // MARK: - Divergence hysteresis

    /// Advance the divergence latch from this tick's synchrony. Returns `true` on the
    /// single tick a divergence LATCHES (the `.congruenceBreak` edge). A `nil`
    /// synchrony (not yet computable) makes no transition.
    private mutating func stepDivergence(synchrony: Double?, now: Date) -> Bool {
        guard let s = synchrony else { return false }

        if divergenceLatched {
            // Re-arm only on a clear recovery above the upper threshold.
            if s >= divergenceExit {
                divergenceLatched = false
                belowSince = nil
            }
            return false
        }

        // Not latched: accumulate dwell while synchrony sits at/below the lower
        // threshold; any recovery blip resets the dwell timer.
        if s <= divergenceEnter {
            let since = belowSince ?? now
            belowSince = since
            if now.timeIntervalSince(since) >= divergenceDwell {
                divergenceLatched = true
                belowSince = nil
                return true
            }
        } else {
            belowSince = nil
        }
        return false
    }

    // MARK: - Synchrony math

    /// Reliability-weighted mean of the pairwise mean-centered cosine similarities over
    /// the retained window. `nil` when no channel pair has enough co-observed history.
    /// Pair weight = `min(r_j, r_k)` — the weaker channel caps the pair's trust.
    private func computeSynchrony(currentVoters: [Channel: ChannelVote]) -> Double? {
        let channels = currentVoters.keys.sorted { $0.rawValue < $1.rawValue }
        guard channels.count >= 2 else { return nil }

        var weightedSim = 0.0
        var weightSum = 0.0
        for i in 0..<(channels.count - 1) {
            for j in (i + 1)..<channels.count {
                let a = channels[i], b = channels[j]
                // Co-observed ticks: those where BOTH channels have a delta.
                var xs: [Double] = []
                var ys: [Double] = []
                for tick in history {
                    if let x = tick.votes[a], let y = tick.votes[b] {
                        xs.append(x)
                        ys.append(y)
                    }
                }
                guard xs.count >= minPairSamples,
                      let cos = Self.centeredCosine(xs, ys) else { continue }
                let w = min(currentVoters[a]!.reliability, currentVoters[b]!.reliability)
                weightedSim += w * cos
                weightSum += w
            }
        }
        guard weightSum > voteEpsilon else { return nil }
        return weightedSim / weightSum
    }

    /// Mean-centered cosine similarity (i.e. the Pearson correlation) of two equal-length
    /// trajectories ∈ [−1, 1]. `nil` when the lengths differ, are too short, or either
    /// trajectory is CONSTANT over the window (a channel that never moves has no
    /// trajectory to correlate — it doesn't contribute to synchrony). Exposed `static`
    /// so the cosine math is directly unit-tested.
    static func centeredCosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count >= 2 else { return nil }
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var dot = 0.0, na = 0.0, nb = 0.0
        for k in 0..<a.count {
            let da = a[k] - meanA
            let db = b[k] - meanB
            dot += da * db
            na += da * da
            nb += db * db
        }
        let denom = (na * nb).squareRoot()
        guard denom > 1e-12 else { return nil }   // a constant trajectory → undefined
        return min(1, max(-1, dot / denom))
    }

    // MARK: - Window maintenance

    private mutating func pruneHistory(now: Date) {
        let cutoff = now.addingTimeInterval(-windowDuration)
        history.removeAll { $0.date < cutoff }
        if history.count > maxSamples {
            history.removeFirst(history.count - maxSamples)
        }
    }
}

#endif
