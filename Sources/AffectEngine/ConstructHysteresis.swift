//
//  ConstructHysteresis.swift
//  AffectLens
//
//  A small hysteretic NAMED-STATE latch for fusion constructs (US-C9, PRD v2 §7.3).
//  Pure, `nonisolated`, and REUSABLE: F7 Frustration uses it today; F1 / F3 and every
//  later hysteretic construct (§4.2 "build the L3 rule layer around these six as
//  HYSTERETIC named constructs") drives its activation scalar through one of these.
//
//  IDIOM LINEAGE. This mirrors the two hysteresis patterns already shipped in the
//  codebase, generalized to a bare "is this construct active?" latch:
//    • `TemporalSmoother` — a challenger must lead by `switchMargin` for `switchFrames`
//      consecutive frames before the announced label flips (dwell before commit).
//    • `CongruenceEngine.stepDivergence` — a two-threshold arm/dwell/re-arm band
//      (`divergenceEnter` / `divergenceExit` / `divergenceDwell`) so one sustained
//      divergence latches once and only re-arms after a clear recovery.
//  ConstructHysteresis is that same enter/exit band + enter/exit dwell, over a generic
//  0…1 activation score, with NO event vocabulary of its own — the hub owns the live
//  instance per construct and turns the returned edge into a bus event + insight.
//

import Foundation

#if os(visionOS) || os(macOS)

/// A two-threshold, two-dwell activation latch over a scalar score.
///
/// **Enter band > exit band** (`enter > exit`) is the whole point: a construct
/// activates only once the score is convincingly high and deactivates only once it is
/// convincingly low, so a score wandering in the `(exit, enter)` middle NEVER chatters
/// the latch. Both transitions additionally require a DWELL — a run of consecutive
/// qualifying ticks — so a single spike (or a single dropout) can't flip the state:
///   • activate  after `score ≥ enter` for `enterDwellTicks` consecutive ticks;
///   • deactivate after `score ≤ exit`  for `exitDwellTicks`  consecutive ticks.
/// Any non-qualifying tick resets that transition's streak (the run must be
/// unbroken). Dwell is measured in ticks; the caller supplies ticks at its own rate
/// (the app's fan-out is ~15 Hz, so `ticks ≈ seconds × 15`).
///
/// Pure value type: all state is here, advanced only through `update`. `Sendable` +
/// `Equatable` so it can live in a hub dictionary and be compared cheaply.
nonisolated struct ConstructHysteresis: Sendable, Equatable {

    // MARK: Configuration (a real hysteresis band — enter > exit)

    /// Score at/above which the enter-dwell begins accumulating.
    var enter: Double
    /// Score at/below which the exit-dwell begins accumulating (`exit < enter`).
    var exit: Double
    /// Consecutive `≥ enter` ticks required to ACTIVATE (clamped to ≥ 1).
    var enterDwellTicks: Int
    /// Consecutive `≤ exit` ticks required to DEACTIVATE (clamped to ≥ 1).
    var exitDwellTicks: Int

    // MARK: State

    /// Whether the construct is currently latched active.
    private(set) var isActive = false
    /// Unbroken run of `≥ enter` ticks while inactive.
    private var enterStreak = 0
    /// Unbroken run of `≤ exit` ticks while active.
    private var exitStreak = 0

    init(enter: Double, exit: Double, enterDwellTicks: Int, exitDwellTicks: Int) {
        self.enter = enter
        self.exit = exit
        self.enterDwellTicks = enterDwellTicks
        self.exitDwellTicks = exitDwellTicks
    }

    // MARK: Update (the only mutating entry point)

    /// Fold one tick's activation score into the latch and return the resulting
    /// `isActive`. A qualifying tick extends the relevant streak; a non-qualifying tick
    /// resets it (the dwell requires an UNBROKEN run). Dwell counts are read through
    /// `max(1, …)` so a mis-set 0/negative dwell still needs one qualifying tick rather
    /// than firing on nothing.
    @discardableResult
    mutating func update(score: Double) -> Bool {
        if isActive {
            if score <= exit {
                exitStreak += 1
                if exitStreak >= max(1, exitDwellTicks) {
                    isActive = false
                    exitStreak = 0
                    enterStreak = 0
                }
            } else {
                exitStreak = 0
            }
        } else {
            if score >= enter {
                enterStreak += 1
                if enterStreak >= max(1, enterDwellTicks) {
                    isActive = true
                    enterStreak = 0
                    exitStreak = 0
                }
            } else {
                enterStreak = 0
            }
        }
        return isActive
    }

    /// Drop back to inactive and clear both streaks — used when a required channel goes
    /// dark, so re-establishing the construct demands a fresh enter-dwell rather than
    /// resuming a stale latch.
    mutating func reset() {
        isActive = false
        enterStreak = 0
        exitStreak = 0
    }
}

// MARK: - CoupledPoleLatch (the ONE-meter tri-state, US-C11)

/// The latched pole of a bipolar (coupled) construct: a signed axis that flips between
/// two mutually-exclusive named poles, with a neutral dead band between them. The whole
/// point of a COUPLED meter (PRD v2 §4.2 F3, "NEVER two meters — ONE coupled axis").
nonisolated enum Pole: Sendable, Equatable {
    /// In the dead band — neither pole is latched (no strong lean either way).
    case neutral
    /// The negative side of the axis is latched (F3: fatigued / "alertness declining").
    case negative
    /// The positive side of the axis is latched (F3: engaged).
    case positive
}

/// A tri-state latch over a SIGNED axis (`[−1, +1]`) built from TWO `ConstructHysteresis`
/// instances — one per pole — with strict mutual exclusion (US-C11, PRD v2 §4.2 F3).
///
/// This is the "one coupled meter" law made mechanical: it can only ever report ONE pole
/// (or neutral), NEVER both. Each pole latch is advanced over its OWN one-sided
/// magnitude — the negative latch over `max(0, −axis)`, the positive over
/// `max(0, +axis)` — so a strong lean one way starves the other's dwell. On the rare
/// tick where both would read active, the pole matching the current axis sign wins and
/// the loser is `reset()` ("activating one forces the other's state machine reset").
///
/// **The dead band is real when `exitDwellTicks < enterDwellTicks`** (the recommended
/// config): on a hard flip the leaving pole deactivates after its shorter exit dwell
/// while the arriving pole is still accumulating its longer enter dwell, so there is a
/// window where the latch reads `.neutral` — the leaving pole exits BEFORE the arriving
/// pole can enter (the US-C11 invariant), and there is never a dual-active tick.
///
/// Pure value type (all state here, advanced only through `update`); `Sendable` +
/// `Equatable` so it can live in a hub dictionary and be compared cheaply.
nonisolated struct CoupledPoleLatch: Sendable, Equatable {
    private var negative: ConstructHysteresis
    private var positive: ConstructHysteresis
    /// The currently-latched pole (never `.negative` and `.positive` at once).
    private(set) var pole: Pole = .neutral

    /// Build a symmetric two-pole latch: both poles share one band + dwell (measured in
    /// ~15 Hz ticks). `enter > exit` is the hysteresis band; `exitDwell < enterDwell`
    /// buys the neutral dead band on a flip.
    init(enter: Double, exit: Double, enterDwellTicks: Int, exitDwellTicks: Int) {
        negative = ConstructHysteresis(enter: enter, exit: exit,
                                       enterDwellTicks: enterDwellTicks, exitDwellTicks: exitDwellTicks)
        positive = ConstructHysteresis(enter: enter, exit: exit,
                                       enterDwellTicks: enterDwellTicks, exitDwellTicks: exitDwellTicks)
    }

    /// Fold one tick's SIGNED axis into the latch and return the resolved pole. Advances
    /// BOTH pole latches over their own one-sided magnitude, then resolves to a single
    /// pole with strict mutual exclusion — so a caller can never observe a dual-active
    /// state (the ONE-meter invariant).
    @discardableResult
    mutating func update(axis: Double) -> Pole {
        let negActive = negative.update(score: max(0, -axis))
        let posActive = positive.update(score: max(0, axis))
        switch (negActive, posActive) {
        case (true, false): pole = .negative
        case (false, true): pole = .positive
        case (false, false): pole = .neutral                 // the dead band
        case (true, true):
            // Both latched on one tick — force exclusivity toward the current axis sign
            // and reset the loser so it must re-earn its full enter dwell.
            if axis >= 0 { negative.reset(); pole = .positive }
            else { positive.reset(); pole = .negative }
        }
        return pole
    }

    /// Drop both poles back to neutral (a required channel went dark, or the construct
    /// became unavailable) — re-establishing a pole then demands a fresh enter dwell.
    mutating func reset() {
        negative.reset()
        positive.reset()
        pole = .neutral
    }
}

#endif
