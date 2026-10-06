//
//  LensRegistry.swift
//  AffectLens
//
//  The channel-lens registry (US-B6, PRD v2 §6.1 / §6.8 / §7.3). Extends the
//  app's tab-enum registry idiom into a `Lens` enum that
//  declares ALL SIX user-facing lenses now — face, eyes, hands, head, voice,
//  interaction. Face (always-on), eyes (US-B5) and interaction (US-B8) have live
//  channels; the rest render the *designed* UNAVAILABLE state, honestly ("not yet
//  wired"), until later items flip them live.
//
//  Honesty bar (PRD law, §6.7): every lens carries "from your Persona" framing
//  and NO emotion claim on any non-face lens — face alone owns the discrete
//  posterior; the rest own an arousal / attention / effort-style modulator.
//
//  Availability is a THREE-state design (PRD §6.8 last bullet / §6.9), never an
//  error toast: AVAILABLE · UNAVAILABLE-BUT-ENABLEABLE (greyed + inline CTA) ·
//  UNAVAILABLE (greyed + honest reason). The AMBIGUOUS state lives one layer in,
//  inside a lens's interpretation strata (the forked / split-label meter), not at
//  the card level.
//

#if os(visionOS) || os(macOS)

import Foundation

// MARK: - Lens

/// One user-facing affect lens. A pure-metadata value type (`nonisolated`, per the
/// project's MainActor-default regime): title, SF Symbol, a one-line honest scope,
/// and the `@AppStorage` key that gates it. Maps 1:1 onto a `Channel` (minus the
/// non-user-facing `.context` modifier, PRD §3.7).
///
/// `Codable` + `Hashable` (both synthesized from the `String` raw value) so a `Lens`
/// can be the value type of the detachable `WindowGroup(id: "lens-detail", for: Lens.self)`
/// (US-lab, §6.8 detachable columns) — SwiftUI requires the window value be `Codable & Hashable`.
nonisolated enum Lens: String, CaseIterable, Identifiable, Sendable, Codable, Hashable {
    case face
    case eyes
    case hands
    case head
    case voice
    case interaction

    var id: String { rawValue }

    /// The sensing channel this lens surfaces (1:1 by raw value).
    var channel: Channel {
        switch self {
        case .face: return .face
        case .eyes: return .eyes
        case .hands: return .hands
        case .head: return .head
        case .voice: return .voice
        case .interaction: return .interaction
        }
    }

    /// The always-on default lens (face) has no enable toggle; everything else is
    /// opt-in (PRD law: off by default except face).
    var isAlwaysOn: Bool { self == .face }

    /// `@AppStorage`/`UserDefaults` key that gates the lens, or `nil` for the
    /// always-on face lens. The `eyes` key is the literal `"lens.eyes.enabled"` —
    /// kept a plain literal (not `EyeChannel.enabledKey`, which is MainActor-isolated
    /// and can't be read from this nonisolated metadata) but asserted equal to
    /// `EyeChannel.enabledKey` in `EmotionSelfTests`, so the two can never drift.
    var enabledDefaultsKey: String? {
        switch self {
        case .face: return nil                    // always-on — no toggle
        case .eyes: return "lens.eyes.enabled"    // == EyeChannel.enabledKey (asserted)
        default: return "lens.\(rawValue).enabled"
        }
    }

    var title: String {
        switch self {
        case .face: return "Face"
        case .eyes: return "Eyes / blink"
        case .hands: return "Hands"
        case .head: return "Head"
        case .voice: return "Voice"
        case .interaction: return "Interaction"
        }
    }

    var systemImage: String {
        switch self {
        case .face: return "face.smiling"
        case .eyes: return "eye"
        case .hands: return "hand.raised"
        case .head: return "person.bust"
        case .voice: return "waveform"
        case .interaction: return "hand.tap"
        }
    }

    /// One-line honest scope. Persona framing everywhere; NO emotion claim on any
    /// non-face lens (PRD §6.7 honesty law).
    var scope: String {
        switch self {
        case .face:
            return "Expression estimate from your Persona — the 8-way posterior, plus valence & arousal."
        case .eyes:
            return "Blink rate & eye openness from your Persona — an attention / fatigue signal, not an emotion."
        case .hands:
            return "Hand motion energy & self-touch — an agitation / load signal."
        case .head:
            return "Head pose & motion — a dominance / approach signal, never valence."
        case .voice:
            return "Vocal prosody — an arousal signal only; never your words, never an emotion."
        case .interaction:
            return "Input tempo & corrections — an effort / engagement signal."
        }
    }
}

// MARK: - LensAvailability (the three designed states)

/// The three designed lens states (PRD §6.8 last bullet / §6.9) — never an error
/// toast. `nonisolated` value type so it can be produced and matched anywhere.
nonisolated enum LensAvailability: Equatable, Sendable {
    /// Live: the lens is producing (or can immediately produce) a usable signal.
    case available
    /// Present but switched off — greyed, with an inline call-to-action to enable it.
    case unavailableButEnableable(cta: String)
    /// Not reachable in this build (sensor gated, or the channel isn't wired yet) —
    /// greyed, with an honest reason. "Not yet wired" is honest and fine here.
    case unavailable(reason: String)

    /// True only for `.available` — the greying test for a lens card.
    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

// MARK: - Availability resolution (the honest, centralized mapping)

extension Lens {
    /// Resolve this lens against the live hub into one of the three designed states.
    /// The single, centralized source of truth for lens availability (PRD §6.9) —
    /// `@MainActor` because it reads the hub's channel state.
    ///
    /// - face: always available (the always-on lens; the card's mini-state reflects
    ///   whether a Persona face is currently locked).
    /// - eyes: available iff its lens flag is on; otherwise enableable (US-B5 flag
    ///   `lens.eyes.enabled`).
    /// - interaction: available iff its lens flag is on; otherwise enableable (US-B8
    ///   flag `lens.interaction.enabled`). Zero-permission + fully windowed, so it is
    ///   enableable immediately (its signal density is use-dependent, and the lens
    ///   itself reports the designed low-signal state when starved — PRD §4.2 F7).
    /// - hands: real channel-driven states (US-D13a). Flowing ⇒ available; enabled but the
    ///   immersive space is closed ⇒ enableable with the "open the aura" CTA; disabled ⇒
    ///   enableable; auth-denied / provider-unsupported / session-error ⇒ the honest
    ///   `.unavailable` reason (never faked).
    /// - head: DUAL-SOURCE (US-D13b) — the windowed pose works in the plain window, so it is
    ///   available iff its lens flag is on (enableable otherwise), UNLESS the thermal governor
    ///   has paused aux sensing — then honestly `.unavailable` with the cooling reason. Its
    ///   copy notes it is richer with the immersive space open.
    /// - voice: available iff its lens flag is on; enableable otherwise, UNLESS the mic was
    ///   denied — then it is honestly `.unavailable` with the Settings reason (US-D12).
    @MainActor
    func availability(in hub: AffectHub) -> LensAvailability {
        switch self {
        case .face:
            return .available
        case .eyes:
            return hub.eyes.isEnabled
                ? .available
                : .unavailableButEnableable(cta: "Enable to read blink rate from your Persona.")
        case .interaction:
            return hub.interaction.isEnabled
                ? .available
                : .unavailableButEnableable(cta: "Enable to read input tempo & corrections from how you use this app.")
        case .voice:
            if hub.voice.micDenied {
                return .unavailable(reason: "Microphone access is off — turn it on in Settings to read vocal arousal.")
            }
            return hub.voice.isEnabled
                ? .available
                : .unavailableButEnableable(cta: "Enable to read vocal arousal on-device — pitch, loudness, tempo. Never your words.")
        case .hands:
            // Live/degraded hand data is flowing ⇒ available (the degraded/out-of-frustum
            // state is shown one layer in, inside the lens).
            if hub.hands.availability != .unavailable { return .available }
            switch hub.hands.unavailableReason {
            case .disabled, .none:
                return .unavailableButEnableable(cta: "Enable to read hand-motion energy & self-touch from the immersive space.")
            case .immersiveClosed:
                return .unavailableButEnableable(cta: "Hands need the immersive space — open the aura.")
            case .authDenied:
                return .unavailable(reason: "Hand tracking is off — allow it in Settings to read hand motion.")
            case .providerUnsupported:
                return .unavailable(reason: "Hand tracking isn't available here (it doesn't run in the simulator).")
            case .sessionError(let m):
                return .unavailable(reason: "Hand tracking couldn't start — \(m)")
            }
        case .head:
            if hub.head.thermalPaused {
                return .unavailable(reason: "Head sensing eased back to keep the device cool — it resumes as it cools down.")
            }
            return hub.head.isEnabled
                ? .available
                : .unavailableButEnableable(cta: "Enable to read head pose & motion from your Persona — richer with the immersive space open.")
        }
    }
}

#endif
