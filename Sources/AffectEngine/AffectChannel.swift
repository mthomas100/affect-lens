//
//  AffectChannel.swift
//  AffectLens
//
//  The channel OUTPUT protocol (US-A2, PRD v2 §7.3) — the common shape every
//  affect-sensing lens presents to the hub and to fusion. It is an *output*
//  contract only: inputs are heterogeneous (Persona pixels, hand anchors, head
//  6DoF, audio…), so there is no associated input type — each concrete channel
//  owns its own actor analyzer and simply publishes a `ChannelReading`.
//
//  The face lens (`EmotionEngine`) is the first and always-on adopter; its
//  ~4-line conformance lives at the bottom of this file so `EmotionEngine.swift`
//  itself stays untouched (byte-identical face pipeline). Later items add the
//  eyes/hands/head/voice/interaction channels — each a `@MainActor @Observable
//  final class` adopting this protocol.
//

import Foundation

/// The common OUTPUT shape of one affect-sensing channel (PRD v2 §7.3).
///
/// Adopted by `@MainActor @Observable final class` channels (the face lens is
/// `EmotionEngine`), so the protocol is `@MainActor`-isolated to match the
/// project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` regime — every member
/// is main-actor work.
@MainActor
protocol AffectChannel {
    /// Which channel this is (fixed by the PRD §2.1 inventory).
    var id: Channel { get }
    /// The channel's most recent output, in the channel-generic form fusion
    /// consumes. The face lens projects its `EmotionReading` via
    /// `asChannelReading()`.
    var latest: ChannelReading { get }
    /// Whether this lens is currently switched on. The face lens is the
    /// always-on default (`true`); later channels gate on `@AppStorage` +
    /// sensor availability.
    var isEnabled: Bool { get }
    /// Drop any transient per-channel signal state, returning the channel to a
    /// clean baseline WITHOUT destroying user calibration or persisted state.
    func reset()
}

#if os(visionOS) || os(macOS)

// MARK: - Face lens conformance

/// `EmotionEngine` is the face channel — the first and always-on `AffectChannel`
/// (PRD v2 §7.3). This extension is the whole adoption; `EmotionEngine.swift` is
/// left untouched so the face pipeline stays byte-identical.
extension EmotionEngine: AffectChannel {
    /// The face lens reads the rendered **Persona** avatar (never the real
    /// face) and is the only channel that carries a discrete-emotion posterior.
    var id: Channel { .face }

    /// Projects the live `EmotionReading` into the channel-generic
    /// `ChannelReading` (`.asChannelReading()`) — a pure, side-effect-free view.
    var latest: ChannelReading { reading.asChannelReading() }

    /// The face lens is the always-on default; it has no independent
    /// enable/disable gate (unlike the later opt-in channels).
    var isEnabled: Bool { true }

    /// Deliberate no-op. A channel `reset()` is meant to clear *transient*
    /// per-channel signal state, but the face engine exposes only *destructive*
    /// resets — re-running neutral calibration (`startCalibration()`, which
    /// wipes the user's persisted baseline) and `clearHistory()` — neither of
    /// which is a non-destructive channel reset. The smoother / intensity state
    /// is private and self-decaying, so there is nothing safe to clear here.
    /// Resetting the face lens is therefore intentionally a no-op, kept so the
    /// always-on face lens satisfies the protocol without changing any existing
    /// behavior.
    func reset() {}
}

#endif
