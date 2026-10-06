//
//  ChannelReading.swift
//  AffectLens
//
//  Channel-generic reading types (US-A1) — the zero-regression spine for
//  multi-channel affect sensing (PRD v2 §7.3). Pure additive value types: the
//  existing face pipeline PROJECTS its `EmotionReading` into a `ChannelReading`
//  (`.asChannelReading()`) rather than being replaced, so this file changes no
//  behavior. Later items add the eyes/hands/head/voice/interaction/context
//  channels, each publishing one of these.
//
//  Honesty note (PRD law): the `face` channel reads the rendered Persona avatar,
//  never the real face; only `face` ever carries a discrete-emotion `posterior`.
//

import Foundation

/// One affect-sensing channel. The inventory is fixed by PRD v2 §2.1; each is a
/// "lens" the user can enable independently. `face` reads the rendered **Persona**
/// avatar (never the real face); every non-face channel owns an
/// arousal / attention / effort-style modulator and NEVER a discrete-emotion label.
nonisolated enum Channel: String, CaseIterable, Codable, Sendable {
    case face
    case eyes
    case hands
    case head
    case voice
    case interaction
    case context
}

/// Whether a channel is currently producing a usable signal.
/// - `live`: sensor present and the signal is usable.
/// - `degraded`: present but low quality — widen uncertainty, never silently drop.
/// - `unavailable`: sensor off, gated (e.g. immersive-only), or no signal.
nonisolated enum ChannelAvailability: String, Codable, Sendable {
    case live
    case degraded
    case unavailable
}

/// A calibrated scalar that carries the app's deliberate two-signal split
/// verbatim: `value` is the **aleatoric magnitude** (how strong / how much the
/// thing is actually happening) and `confidence` is the **epistemic trust** (how
/// much to believe the system). These are different signals — do not collapse
/// them into one number.
nonisolated struct Meter: Sendable, Codable, Equatable {
    /// Aleatoric magnitude — how strong the reading is (e.g. the arousal level).
    var value: Double
    /// Epistemic trust — how much to trust this reading (0…1).
    var confidence: Double
}

/// A derived per-channel feature key. Starter set for US-A1; later channel items
/// extend this enum as each lens lands (its features become new cases).
nonisolated enum FeatureKey: String, Codable, Sendable {
    // face
    case au4
    /// The brow / lid AUs F4 (frown+head-down, US-D14a) needs beyond `au4` to run its
    /// L1 brow-morphology step (AU1+AU15 ⇒ sadness-lean; AU4+AU5/AU7 ⇒ anger-lean; AU4
    /// alone ⇒ effort-lean). Like `au4` these are FACE-only enrichments the hub copies out
    /// of `EmotionEngine.auVector` in `enrichedFaceReading()` (an `EmotionReading` doesn't
    /// carry the AU vector), and `au4` is ALREADY pitch-corrected upstream (§3.4 / US-A0).
    case au1
    case au5
    case au7
    case au15
    /// The per-user resting face-arousal baseline key (a rolling robust median of the
    /// face reading's circumplex arousal, used by `AffectHub` as the `.face`
    /// `BaselineStore` feature the congruence engine measures its signed arousal DELTA
    /// against). Internal to baselining — not published as a delta feature in a
    /// `ChannelReading`.
    case faceArousal
    // eyes
    case blinkRate
    case eyeOpenVariance
    case prolongedClosure
    /// The per-user open-eye openness baseline key (used by `EyeChannel` as the
    /// `.eyes` `BaselineStore` feature for the adaptive-EAR threshold). Internal to
    /// baselining — not published as a delta feature in a `ChannelReading`.
    case eyeOpenness
    // hands
    case selfTouchRate
    case gestureEnergy
    case gestureRate
    case handAperture
    // head
    case headPitch
    case headYaw
    case headRoll
    case headMotionEnergy
    /// The hedged dominance-lean ∈ [−1, 1] (US-D13b, §3.4): + head-back+level
    /// ("expansion"), − head-down+turned-away ("withdrawal"). A gaze-gated FEATURE whose
    /// confidence contribution is ALWAYS capped low (we read head orientation, not gaze).
    case dominanceLean
    // voice
    case vocalF0
    case vocalIntensity
    case vocalTempo
    /// A recency-weighted "laugh-like sound heard recently" scalar ∈ [0, 1] (US-D14b F6):
    /// 1 the instant an on-device laughter event fires, decaying linearly to 0 over the
    /// voice channel's `laughterRecencyWindow`. Published in the voice `ChannelReading` so a
    /// PURE fusion `fuse(...)` (F6) can read the corroborating laughter recency without
    /// reaching the event bus. A sound-EVENT recency only — never a valence or emotion claim.
    case recentLaughter
    // interaction
    case cancelRate
    case responseLatency
    case inputTempo
    // context
    case sessionMinutes
}

/// The channel-generic reading — one timestamped output from a single channel.
/// Every lens publishes one of these and fusion consumes them (PRD v2 §7.3).
/// `EmotionReading` projects into `ChannelReading(channel: .face)` via
/// `asChannelReading()`; it is not replaced.
nonisolated struct ChannelReading: Sendable, Codable {
    /// Which channel produced this reading.
    var channel: Channel
    /// When this reading was produced.
    var date: Date
    /// Whether the channel's signal is live, degraded, or unavailable.
    var availability: ChannelAvailability
    /// 0…1 heuristic signal quality (landmark confidence, device fit, recency…).
    var quality: Double
    /// Valence meter — populated only by channels that measure valence (`face`).
    var valence: Meter?
    /// Arousal meter — most channels can contribute an arousal estimate.
    var arousal: Meter?
    /// 0…1 aleatoric expression strength for this channel.
    var intensity: Double
    /// Derived (delta-from-baseline) features this channel carries.
    var features: [FeatureKey: Double]
    /// The 8-class discrete-emotion posterior. **Populated ONLY by the `face`
    /// channel.** This is PRD law (§0.3 / seam-a veto): non-face channels own
    /// arousal / attention / effort modulators and never carry a discrete-emotion
    /// label, so `posterior` is always `nil` for them.
    var posterior: EmotionDistribution?
    /// The per-Persona **expressive-separability** score (`[0, 1]`, §5.4) — the
    /// low-expresser widener, carried on the reading so a PURE fusion `fuse(...)` can
    /// gate on it without reaching the hub/`BaselineStore`. Like `posterior` this is a
    /// **face-only** enrichment (the hub injects `BaselineStore.separability(for:.face)`
    /// into `enrichedFaceReading()`); every other channel leaves it `nil`. A trailing,
    /// defaulted optional so no existing `ChannelReading(...)` call site changes and old
    /// Codable traces decode it as `nil`. `nil` means "no separability info supplied"
    /// (a construct treats that as ungated — the hub always supplies the real value).
    var expressiveSeparability: Double? = nil
}

// MARK: - Face projection

extension EmotionReading {
    /// Projects this face reading into the channel-generic `ChannelReading`
    /// (PRD v2 §7.3: `EmotionReading` *projects into* `ChannelReading(channel: .face)`
    /// rather than being replaced). A pure, side-effect-free view — zero behavior
    /// change to the face pipeline.
    ///
    /// - Availability maps the only presence signal the reading encodes:
    ///   `faceDetected` → `.live`, otherwise `.unavailable`. (`EmotionReading`
    ///   has no notion of a partially-degraded face, so `.degraded` is not
    ///   synthesized here.)
    /// - `features` is intentionally empty: an `EmotionReading` does not carry the
    ///   AU vector (that lives on `EmotionEngine.auVector`), so there is no `au4`
    ///   to report without inventing a value. A call site that holds the AU vector
    ///   can populate `features` itself.
    nonisolated func asChannelReading() -> ChannelReading {
        ChannelReading(
            channel: .face,
            date: date,
            availability: faceDetected ? .live : .unavailable,
            quality: quality,
            valence: Meter(value: valence, confidence: confidence),
            arousal: Meter(value: arousal, confidence: confidence),
            intensity: intensity,
            features: [:],
            posterior: distribution
        )
    }
}
