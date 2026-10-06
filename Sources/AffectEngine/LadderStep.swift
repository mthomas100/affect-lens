//
//  LadderStep.swift
//  AffectLens
//
//  The pure model behind `DisambiguationLadderView`, moved out of the view file so the
//  engine's construct ladder builders compile without SwiftUI (e.g. in the macOS
//  `affect-replay` tool).
//

#if os(visionOS) || os(macOS)

// MARK: - LadderStep (the pure model — one rung)

/// One rung of a disambiguation ladder. `nonisolated` so construct ladder builders
/// (e.g. `F1ComposureMode.ladder(...)`) are pure and testable off the main actor.
nonisolated struct LadderStep: Identifiable, Equatable {
    /// The state of one rung's claim.
    enum Status: Equatable {
        /// The claim is established — the rung LIGHTS with its claim.
        case resolved
        /// Not yet decided — the rung shows the FORK it can't yet tell apart (the
        /// associated text names the unresolved alternatives / why it's tentative).
        case ambiguous(String)
        /// A confound the app RULES OUT / refuses — greyed WITH STRIKETHROUGH (the
        /// associated text is the honest reason). Never a claim the app makes.
        case ruledOut(String)
    }

    /// Stable position-based identity (assigned by the builder) — collision-free for
    /// `ForEach` even if two rungs shared claim text.
    let id: Int
    /// The rung's claim, in honesty-bounded copy (drawn from `HonestyPhrases`).
    let claim: String
    /// Whether this rung is resolved, an ambiguous fork, or a ruled-out confound.
    let status: Status

    init(id: Int, claim: String, status: Status) {
        self.id = id
        self.claim = claim
        self.status = status
    }
}

#endif
