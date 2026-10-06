//
//  FusionRegistry.swift
//  AffectLens
//
//  The fusion-mode registry + protocol (US-B6, PRD v2 §7.3 / §6.7). A fusion mode
//  is a named, science-backed construct that combines 2+ channels into something
//  NO single lens can measure (PRD §4.2). This item ships the REGISTRY, the
//  toggle plumbing (`fusion.<id>.enabled`, default false), and the `RationalePanel`
//  honesty component — but registers NO concrete modes yet (the constructs arrive
//  in later items). A DEBUG-only placeholder in `EmotionSelfTests` exercises the
//  round-trip; nothing here is wired into the running app.
//
//  Honesty law (PRD §6.7): every mode declares its required channels and carries a
//  non-empty `rationale` (the shown "why"), plus the named confound it can't rule
//  out, a citation chip, and a confidence ceiling — the legible-fusion contract.
//

#if os(visionOS) || os(macOS)

import SwiftUI

// MARK: - FusionOutput

/// The minimal fused output (US-B6, enriched US-C9). `nonisolated` Sendable value
/// type. `Equatable` so the hub only republishes a `FusionModeState` on a real change.
nonisolated struct FusionOutput: Sendable, Equatable {
    /// The named construct state, e.g. "frustration (task friction)" — set by the hub
    /// ONLY once the construct's `ConstructHysteresis` has latched active; `nil` while
    /// the fused evidence is present but not (yet) a surfaced named state.
    var namedState: String?
    /// Fused valence, only from modes that touch a valence-bearing channel (face).
    var valence: Meter?
    /// Fused arousal — most constructs land here.
    var arousal: Meter?
    /// Contributing channels and their live weights / component magnitudes (the
    /// legible-fusion audit — PRD §6.2 / M5: the weights ARE the reliability vector,
    /// and "every fused insight shows contributing channels").
    var contributions: [Channel: Double]
    /// Epistemic trust in this fused reading (0…1), separate from any magnitude.
    var confidence: Double
    /// The construct's raw ACTIVATION scalar (0…1), PRE-hysteresis — the score the
    /// hub's `ConstructHysteresis` latches on. Distinct from `confidence` (epistemic):
    /// this is "how strongly the construct's evidence is present this tick."
    var score: Double
    /// The present `SignalRef`s this fused output is grounded in — fed straight into the
    /// `.constructStateChanged` event's `evidence` (the honesty law: the narrator may
    /// cite only present signals). Empty means "no citable signal."
    var evidence: [SignalRef]
    /// True when the per-Persona **low-expresser gate** (§5.4) is actively limiting this
    /// construct — the calibration's expressive range is narrow (or unknown), so the
    /// reading is held tentative (confidence multiplied down + the activation bar
    /// raised). Drives the disambiguation ladder's "reading stays tentative" rung. A
    /// trailing, defaulted field so constructs that don't gate (F7) never set it.
    var separabilityLimited: Bool
    /// The SIGNED bipolar axis (`[−1, +1]`) of a COUPLED construct (US-C11 F3): one
    /// zero-centred meter that flips between two poles (F3: − fatigued / + engaged), with
    /// `score == |axis|`. `nil` for single-poled constructs (F7/F1) — the hub reads this
    /// to drive a `CoupledPoleLatch` (surfacing the POLE, not just active/inactive) and
    /// the UI reads it to draw ONE zero-centred bar. A trailing, defaulted optional so no
    /// existing `FusionOutput(...)` changes.
    var axis: Double?
    /// The rolling VARIANCE (spread) of a construct's activation score over its documented
    /// window — the HP-Omnicept "mean + variance" load-meter idiom (US-D14a F2). The hub
    /// owns the live sample buffer per `VarianceReportingFusionMode` id and sets this AFTER
    /// `fuse`, so the mode's `fuse` stays pure; the UI then renders `score` (the mean) as a
    /// needle with a `±spread` band rather than a bare number. `nil` for every construct
    /// that doesn't report variance (F1/F3/F4/F7). A trailing, defaulted optional.
    var spread: Double?
    /// A discrete LEAN code (an `F4Lean.rawValue`) for a construct whose surfaced state is a
    /// hedged lean rather than an active/inactive latch (US-D14a F4). The hub forwards it on
    /// the `.constructStateChanged` event's `baselineDelta` (via `axis ?? leanCode`) so the
    /// cross-platform narrator can recover which lean to phrase — kept SEPARATE from `axis`
    /// so the coupled-meter contract (`axis`, `score == |axis|`, the one bipolar bar) stays
    /// intact and no coupled-bar UI fires for a leaning single-poled construct. `nil` for
    /// every non-leaning construct. A trailing, defaulted optional.
    var leanCode: Double?

    init(namedState: String? = nil,
         valence: Meter? = nil,
         arousal: Meter? = nil,
         contributions: [Channel: Double] = [:],
         confidence: Double = 0,
         score: Double = 0,
         evidence: [SignalRef] = [],
         separabilityLimited: Bool = false,
         axis: Double? = nil,
         spread: Double? = nil,
         leanCode: Double? = nil) {
        self.namedState = namedState
        self.valence = valence
        self.arousal = arousal
        self.contributions = contributions
        self.confidence = confidence
        self.score = score
        self.evidence = evidence
        self.separabilityLimited = separabilityLimited
        self.axis = axis
        self.spread = spread
        self.leanCode = leanCode
    }
}

// MARK: - FusionAvailability (the designed reason a mode is / isn't runnable)

/// Why a fusion mode is or isn't runnable right now — richer than a bool so the UI can
/// speak honestly (PRD §4.6 / §6.9): a required lens being OFF is a different, honest
/// state from a required lens being ON-but-STARVED (the designed low-signal state,
/// §4.2 F7). `nonisolated` value type so it can be produced and matched anywhere.
nonisolated enum FusionAvailability: Sendable, Equatable {
    /// Every required channel is enabled AND live — the mode runs.
    case available
    /// A required channel's lens is OFF or not wired — it must be enabled first.
    case requiresChannel(Channel)
    /// Every required lens is ON, but a required channel is enabled-yet-unavailable —
    /// the DESIGNED low-signal state (e.g. interaction starved in passive viewing,
    /// §4.2 F7). Never a fabricated read; the mode simply doesn't fire.
    case starved(Channel)

    /// True only for `.available`.
    var isAvailable: Bool { self == .available }
}

// MARK: - FusionModeState (the per-mode live state the UI observes)

/// One registered mode's live state for the UI (US-C9). Held per id in
/// `AffectHub.fusionStates`. `Equatable` so the hub republishes only on a real change.
nonisolated struct FusionModeState: Sendable, Equatable {
    /// The latest fused output while `.available` (drives the confidence chip +
    /// contributing-channel audit); `nil` when not runnable this tick.
    var output: FusionOutput?
    /// Whether the construct's hysteresis is currently LATCHED active (the surfaced
    /// named state) — never the same as "has some score."
    var isActive: Bool
    /// The designed availability reason (drives the honest greyed / "needs …" copy).
    var availability: FusionAvailability
}

// MARK: - FusionMode

/// A named fusion construct (PRD §7.3 shape). `@MainActor` so `isAvailable` can
/// read the hub, but every pure member — the metadata and `fuse` — is explicitly
/// `nonisolated` so the honesty copy and the (side-effect-free) fusion math stay
/// callable off the main actor. Deliberate isolation, per the project's
/// MainActor-default regime.
@MainActor
protocol FusionMode: Sendable {
    /// Stable id; backs the `fusion.<id>.enabled` toggle key.
    nonisolated var id: String { get }
    /// Human title (the toggle label).
    nonisolated var title: String { get }
    /// Channels this construct needs. MUST be non-empty (a fusion mode combines 2+).
    nonisolated var requires: Set<Channel> { get }
    /// The shown "why" — a one-paragraph mechanism. MUST be non-empty (PRD §6.7).
    nonisolated var rationale: String { get }
    /// The named confound this construct can't fully rule out (RationalePanel).
    nonisolated var confound: String { get }
    /// A citation chip for the mechanism (RationalePanel), if any.
    nonisolated var citation: String? { get }
    /// The confidence CEILING this construct may ever honestly claim (0…1).
    nonisolated var confidenceCeiling: Double { get }

    /// A FRESH named-state latch for this construct (US-C9). The hub owns the LIVE
    /// instance per mode and advances it each tick with `fuse(...).score`; this getter
    /// only supplies the construct's band + dwell (enter > exit; dwell in ~15 Hz ticks).
    nonisolated var hysteresis: ConstructHysteresis { get }

    /// A mode-specific availability gate BEYOND channel presence (default: none).
    /// The registry additionally enforces `requires ⊆ live channels`.
    func isAvailable(_ hub: AffectHub) -> Bool

    /// Fuse the current per-channel readings into an output, or `nil` if the
    /// required signals aren't present this tick. Pure over its inputs.
    nonisolated func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput?

    /// A construct-specific **disambiguation ladder** for the current live state
    /// (US-C10, §6.6) — the progressive-narrowing honesty stepper the UI renders under
    /// the row: each resolved rung lights, an unresolved fork stays ambiguous, and a
    /// ruled-out confound greys with a strikethrough. Pure over the published state.
    /// Default: `[]` — a construct with no ladder shows just its `RationalePanel`, so
    /// every existing mode keeps a clean nil path and can adopt a ladder later with no
    /// protocol rework.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep]
}

extension FusionMode {
    // RationalePanel enrichments default to "nothing extra" so a concrete mode only
    // MUST supply id / title / requires / rationale / fuse (the PRD §7.3 surface).
    nonisolated var confound: String { "" }
    nonisolated var citation: String? { nil }
    nonisolated var confidenceCeiling: Double { 1.0 }

    /// A trivial pass-through latch by default (activates on the first `≥ 0.5` tick).
    /// Real constructs override with a documented band + multi-second dwell.
    nonisolated var hysteresis: ConstructHysteresis {
        ConstructHysteresis(enter: 0.5, exit: 0.3, enterDwellTicks: 1, exitDwellTicks: 1)
    }

    /// No extra gate by default — availability is purely `requires ⊆ live channels`,
    /// which the registry enforces.
    func isAvailable(_ hub: AffectHub) -> Bool { true }

    /// No ladder by default — the clean nil path (an empty ladder renders nothing, so
    /// the row falls back to its `RationalePanel`). Concrete constructs override.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep] { [] }
}

// MARK: - CoupledFusionMode (the ONE-meter, two-pole refinement — US-C11)

/// A `FusionMode` whose reading is a single COUPLED axis that flips between two named
/// poles (PRD v2 §4.2 F3, "NEVER two meters — ONE coupled axis"). It supplies a
/// `CoupledPoleLatch` (config only; the hub owns the live instance) instead of the
/// single-pole `hysteresis`, and names each pole. The hub detects a coupled mode by an
/// `as? any CoupledFusionMode` cast in `evaluateFusion` and drives the two-pole latch,
/// surfacing the POLE as the `FusionOutput.namedState`. Refining (not folding into
/// `FusionMode`) keeps the base protocol's single-pole path untouched for F7/F1.
@MainActor
protocol CoupledFusionMode: FusionMode {
    /// A FRESH two-pole latch (band + dwell only; the hub owns the mutable instance and
    /// advances it each tick with the fused signed axis). Its `exitDwell < enterDwell`
    /// is what buys the neutral dead band between poles.
    nonisolated var coupledLatch: CoupledPoleLatch { get }

    /// The human, honesty-bounded label for the latched pole — `sign > 0` = positive,
    /// `sign < 0` = negative. Becomes the surfaced `namedState`. (`0`/unknown ⇒ nil ⇒ the
    /// hub falls back to `title`.)
    nonisolated func poleName(forSign sign: Int) -> String?
}

// MARK: - VarianceReportingFusionMode (the mean + variance refinement — US-D14a F2)

/// A `FusionMode` that reports a rolling VARIANCE of its activation score alongside the mean
/// (PRD v2 §4.2 F2 — "ship 'mean + variance' like Omnicept"). It supplies only the WINDOW
/// (seconds); the hub owns the live per-id sample buffer (a `RollingLoad`), advances it each
/// tick with the fused `score`, and writes the result into `FusionOutput.spread` AFTER
/// `fuse` — so the mode's `fuse` stays a pure function of its inputs (the variance is
/// inherently temporal state the hub already owns for latches). The hub detects it by an
/// `as? any VarianceReportingFusionMode` cast in `evaluateFusion`, mirroring the
/// `CoupledFusionMode` pattern, so the base protocol's path is untouched for every other mode.
@MainActor
protocol VarianceReportingFusionMode: FusionMode {
    /// The rolling window (seconds) over which the activation-score variance is computed.
    nonisolated var spreadWindow: TimeInterval { get }
}

// MARK: - FusionRegistry

/// Holds the registered fusion modes, gates each behind `fusion.<id>.enabled`
/// (default FALSE), and resolves availability as `requires ⊆ live channels` (plus
/// the mode's own gate). `@MainActor` because availability reads the hub. Accepts a
/// custom `UserDefaults` so tests can toggle in a throwaway suite.
///
/// This item registers NOTHING (later items add the constructs); the type exists so
/// the toggle + availability plumbing ships and is regression-tested now.
@MainActor
final class FusionRegistry {
    private(set) var modes: [any FusionMode] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Register a mode. Enforces the honesty contract at registration time: a fusion
    /// mode must combine channels (`requires` non-empty) and must explain itself
    /// (`rationale` non-empty). Re-registering an id replaces it in place.
    func register(_ mode: any FusionMode) {
        assert(!mode.requires.isEmpty, "FusionRegistry: mode '\(mode.id)' must declare required channels")
        assert(!mode.rationale.isEmpty, "FusionRegistry: mode '\(mode.id)' must carry a non-empty rationale")
        if let i = modes.firstIndex(where: { $0.id == mode.id }) {
            modes[i] = mode
        } else {
            modes.append(mode)
        }
    }

    // MARK: Toggle plumbing (fusion.<id>.enabled, default false)

    static func enabledKey(_ id: String) -> String { "fusion.\(id).enabled" }

    /// Whether a mode is switched on (default false — every mode is opt-in).
    func isEnabled(_ id: String) -> Bool {
        defaults.bool(forKey: Self.enabledKey(id))
    }

    /// Flip a mode's toggle.
    func setEnabled(_ id: String, _ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey(id))
    }

    // MARK: Availability (requires ⊆ live channels)

    /// The set of channels whose lens is switched ON (regardless of current signal
    /// density) — face is always on; every other lens gates on its own `isEnabled`. This is
    /// the "is the lens even turned on" half of availability; `liveChannels` is the "is it
    /// producing signal right now" half. CONTEXT is never here — it is a synthesized fusion
    /// modifier (§3.7), never a user-facing lens, so no construct declares it in `requires`.
    static func enabledChannels(in hub: AffectHub) -> Set<Channel> {
        var on: Set<Channel> = [.face]   // the always-on default lens
        if hub.eyes.isEnabled { on.insert(.eyes) }
        if hub.interaction.isEnabled { on.insert(.interaction) }
        // hands / head / voice landed (US-D13a/b, US-D12) — a construct requiring one of them
        // (F4 head, F6 voice, F8/F9/F10 head — US-D14b) resolves its availability against
        // these toggles, so they must join the enabled set the moment their lens is on.
        if hub.hands.isEnabled { on.insert(.hands) }
        if hub.head.isEnabled { on.insert(.head) }
        if hub.voice.isEnabled { on.insert(.voice) }
        return on
    }

    /// The set of channels currently producing a usable signal — the honest input to
    /// the `requires ⊆ live` test. Face is always live; eyes / interaction / hands / head /
    /// voice are live when enabled AND not `.unavailable`. A channel that is enabled but
    /// STARVED (interaction in passive viewing, hands with the aura closed) reports
    /// `.unavailable`, so it is enabled yet not live — the designed low-signal split (§4.2 F7).
    static func liveChannels(in hub: AffectHub) -> Set<Channel> {
        var live: Set<Channel> = []
        if hub.face.latest.availability != .unavailable { live.insert(.face) }
        if hub.eyes.isEnabled, hub.eyes.latest.availability != .unavailable { live.insert(.eyes) }
        if hub.interaction.isEnabled, hub.interaction.latest.availability != .unavailable { live.insert(.interaction) }
        // hands / head / voice landed (US-D13a/b, US-D12): each is live when its lens is ON and
        // its latest reading isn't `.unavailable` (a lens ON-but-STARVED — hands with the aura
        // closed, voice mid-silence — reports `.unavailable`, so it is enabled yet not live, the
        // designed low-signal split, §4.2). CONTEXT is deliberately NOT here: the hub SYNTHESIZES
        // a `.context` reading as a fusion INPUT only (the §3.7 modifier feeding F3's accrual),
        // never a user-facing lens, so no construct declares it in `requires`.
        if hub.hands.isEnabled, hub.hands.latest.availability != .unavailable { live.insert(.hands) }
        if hub.head.isEnabled, hub.head.latest.availability != .unavailable { live.insert(.head) }
        if hub.voice.isEnabled, hub.voice.latest.availability != .unavailable { live.insert(.voice) }
        return live
    }

    /// Resolve WHY a mode is / isn't runnable into the designed `FusionAvailability`
    /// (PRD §4.6 / §6.9). A required lens that is OFF ⇒ `.requiresChannel` (enable it);
    /// a required lens that is ON but not producing signal ⇒ `.starved` (the designed
    /// low-signal state — never a fabricated read); else `.available`. Required channels
    /// are checked in a stable order so the surfaced reason is deterministic.
    func resolveAvailability(_ mode: any FusionMode, hub: AffectHub) -> FusionAvailability {
        let enabled = Self.enabledChannels(in: hub)
        let live = Self.liveChannels(in: hub)
        let required = mode.requires.sorted { $0.rawValue < $1.rawValue }
        if let off = required.first(where: { !enabled.contains($0) }) {
            return .requiresChannel(off)
        }
        if let starved = required.first(where: { !live.contains($0) }) {
            return .starved(starved)
        }
        // The mode's own extra gate (default: always passes) — treat a failing gate as
        // "present but not ready" against its first required channel.
        guard mode.isAvailable(hub) else { return .starved(required.first ?? .face) }
        return .available
    }

    /// A mode is available iff every required channel is live AND its own gate passes.
    /// A required-but-dark channel ⇒ unavailable (never faked, PRD §4.6). Thin wrapper
    /// over `resolveAvailability` so callers that only need the bool stay simple.
    func isAvailable(_ mode: any FusionMode, hub: AffectHub) -> Bool {
        resolveAvailability(mode, hub: hub).isAvailable
    }
}

// MARK: - RationalePanel (the explanations-as-feature honesty component, PRD §6.7)

/// The expandable "why" panel a fusion toggle carries: mechanism paragraph + the
/// named confound it can't fully rule out + a citation chip + the confidence
/// ceiling + the honest "needs these channels" line. Ships now for the fusion
/// constructs that land in later items; not yet mounted in the running app.
struct RationalePanel: View {
    let mode: any FusionMode
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                // Mechanism paragraph.
                Text(mode.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // The named confound it can't fully rule out.
                if !mode.confound.isEmpty {
                    Label("Can't fully rule out: \(mode.confound)", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                // Needs-these-channels honesty line.
                Label("Needs " + requiresList, systemImage: "square.stack.3d.up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    if let cite = mode.citation {
                        Text(cite)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Text("Confidence ceiling \(Int((mode.confidenceCeiling * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            Label(mode.title, systemImage: "questionmark.circle")
                .font(.caption)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// "face + eyes" — the required channels, honestly named.
    private var requiresList: String {
        mode.requires
            .map { $0.rawValue }
            .sorted()
            .joined(separator: " + ")
    }
}

#endif
