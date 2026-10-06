//
//  InteractionChannel.swift
//  AffectLens
//
//  The INTERACTION-DYNAMICS lens (US-B8, PRD v2 §3.6 / §2.1 interaction row). The
//  cheapest new lens: ZERO permission, ZERO sensor, fully windowed. It reads how
//  the user manipulates THIS app's own controls — lens-card pinches, toggles,
//  scrubbers, calibration flows — off SwiftUI's `SpatialEventGesture` (the view
//  side lives in `InteractionLensView`), and turns that into an EFFORT / ENGAGEMENT
//  load signal.
//
//  Honesty bar (PRD law, §3.6 science note — Doherty-Sneddon & Phelps 2005):
//  effort ≠ affect. This lens speaks in "effort / load / engagement" ONLY, NEVER
//  "stress", and NEVER asserts "frustration" as a state (F7 Frustration is the
//  LATER fusion construct that marries this to the face; the lens alone shows load).
//  Per the §2 master law, interaction owns the effort/engagement axis and NOT the
//  circumplex — so its `ChannelReading` carries `valence: nil` and `arousal: nil`;
//  the load lives entirely in the delta-from-baseline FEATURES. No discrete-emotion
//  posterior (the non-face law), no valence, ever.
//
//  The DESIGNED starvation state (PRD §4.2 F7 signal-density caveat): the signal is
//  USE-dependent. Passive viewing ⇒ little manipulation ⇒ the lens honestly reports
//  `.unavailable` + low confidence — a designed low-signal state, NEVER a fabricated
//  read. Everything off-by-default except face (PRD law): gated on the `UserDefaults`
//  key `lens.interaction.enabled`, default FALSE; collection runs ONLY while enabled.
//

#if os(visionOS) || os(macOS)

import Foundation

// MARK: - InteractionEvent (the abstract, honest input model)

/// One abstract manipulation of the app's controls, decoupled from the raw
/// `SpatialEventCollection.Event` the view captures (which the modifier translates
/// into these). The minimal honest model: a pinch/tap has a `began` and then a
/// resolution (`ended` normally, or `cancelled` — the phase F7 leans on); a control
/// `toggle` carries its id + new value so rapid flip-backs power churn detection.
nonisolated struct InteractionEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// A manipulation started (a pinch/tap entered its active phase).
        case began
        /// A manipulation completed normally.
        case ended
        /// A manipulation was cancelled (the `SpatialEventCollection.Event` cancelled
        /// phase) — a correction signal, counted against the cancel rate.
        case cancelled
        /// A control toggle flipped to `isOn`; `id` identifies the control so a
        /// flip-back within the churn window reads as a correction.
        case toggle(id: String, isOn: Bool)
    }

    /// When it happened (wall-clock; the view stamps `Date()` at the phase edge).
    var t: Date
    /// What happened.
    var kind: Kind
    /// Press / hold duration for a resolved manipulation (`.ended` / `.cancelled`);
    /// `nil` for `.began` and `.toggle`.
    var duration: TimeInterval?

    init(_ kind: Kind, at t: Date, duration: TimeInterval? = nil) {
        self.kind = kind
        self.t = t
        self.duration = duration
    }
}

// MARK: - InteractionDynamics (the pure, testable core)

/// The interaction-feature math, factored out as a `nonisolated` value type so it is
/// pure and unit-testable off the main actor (the `InteractionChannel` @Observable
/// class wraps it). It keeps a rolling window of abstract `InteractionEvent`s and
/// derives per-window features.
///
/// **Windows (documented).** All events are retained for `featureWindow` (~120 s):
/// cancel-rate, toggle-churn and press-duration draw on the full 120 s for more
/// samples. `inputTempo` is deliberately a trailing-`tempoWindow` (60 s) count — a
/// per-minute rate expressed the same way `EyeChannel.blinksPerMinute` is (a count
/// inside a 60 s window IS the per-minute rate), which keeps the tempo responsive
/// while the slower rates stay stable.
///
/// **Starvation.** Fewer than `minEventsForSignal` events in the window is too
/// sparse to derive a trustworthy rate, so `isStarved` is `true` — which the channel
/// maps to `.unavailable` + low confidence (the DESIGNED passive-viewing state, PRD
/// §4.2 F7). All reads take an explicit `now` so the window ages correctly BETWEEN
/// events (no timer needed — the view refreshes on a clock and passes `context.date`).
nonisolated struct InteractionDynamics {

    // MARK: Configuration (documented constants)

    /// Rolling memory for cancel-rate / churn / press-duration.
    static let featureWindow: TimeInterval = 120
    /// Trailing window for the per-minute `inputTempo` count (mirrors `EyeChannel`).
    static let tempoWindow: TimeInterval = 60
    /// A toggle for the same control reversed within this window is a CORRECTION
    /// (documented: on→off — or off→on — inside ~5 s reads as churn).
    static let churnFlipBackWindow: TimeInterval = 5
    /// Below this many events in the feature window the signal is too sparse to read
    /// (the DESIGNED starvation threshold — passive viewing lands here).
    static let minEventsForSignal = 6

    // MARK: State

    private var events: [InteractionEvent] = []
    /// Timestamps of detected toggle corrections (flip-backs), pruned with the window.
    private var churnMarks: [Date] = []
    /// The most recent toggle per control id, to detect a rapid flip-back.
    private var lastToggle: [String: (t: Date, isOn: Bool)] = [:]

    init() {}

    // MARK: Ingest (the only mutating entry point)

    /// Fold one abstract interaction event into the window. Detects a toggle
    /// flip-back (a correction) at ingest time, then prunes the window to the
    /// feature horizon (memory hygiene — reads also filter by age, so pruning is not
    /// required for correctness).
    mutating func note(_ event: InteractionEvent) {
        events.append(event)

        if case let .toggle(id, isOn) = event.kind {
            if let prev = lastToggle[id],
               prev.isOn != isOn,
               event.t >= prev.t,
               event.t.timeIntervalSince(prev.t) <= Self.churnFlipBackWindow {
                churnMarks.append(event.t)
            }
            lastToggle[id] = (event.t, isOn)
        }

        prune(now: event.t)
    }

    private mutating func prune(now: Date) {
        let featureCutoff = now.addingTimeInterval(-Self.featureWindow)
        events.removeAll { $0.t < featureCutoff }
        churnMarks.removeAll { $0 < featureCutoff }
        // A toggle older than the flip-back window can never form a correction with a
        // future toggle, so drop its per-id memory.
        let toggleCutoff = now.addingTimeInterval(-Self.churnFlipBackWindow)
        lastToggle = lastToggle.filter { $0.value.t >= toggleCutoff }
    }

    /// Reset session state — used when the lens is (re)enabled so it starts clean.
    mutating func clear() {
        events.removeAll()
        churnMarks.removeAll()
        lastToggle.removeAll()
    }

    // MARK: Rolling reads (all take `now`, so they age between events)

    private func inWindow(_ window: TimeInterval, now: Date) -> [InteractionEvent] {
        let cutoff = now.addingTimeInterval(-window)
        return events.filter { $0.t >= cutoff && $0.t <= now }
    }

    private func isInitiation(_ kind: InteractionEvent.Kind) -> Bool {
        switch kind {
        case .began, .toggle: return true
        case .ended, .cancelled: return false
        }
    }

    /// Total events in the feature window — the density measure behind starvation.
    func eventCount(now: Date) -> Int { inWindow(Self.featureWindow, now: now).count }

    /// `true` when the window is too sparse to derive a trustworthy rate.
    func isStarved(now: Date) -> Bool { eventCount(now: now) < Self.minEventsForSignal }

    /// Initiations (a new pinch/tap or a toggle) per minute — a trailing-60 s count,
    /// the same per-minute convention as `EyeChannel.blinksPerMinute`.
    func inputTempo(now: Date) -> Double {
        Double(inWindow(Self.tempoWindow, now: now).filter { isInitiation($0.kind) }.count)
    }

    /// cancelled / (ended + cancelled) over the feature window; `nil` if nothing has
    /// resolved yet (no ended or cancelled events to form a rate).
    func cancelRate(now: Date) -> Double? {
        var ended = 0, cancelled = 0
        for e in inWindow(Self.featureWindow, now: now) {
            switch e.kind {
            case .ended: ended += 1
            case .cancelled: cancelled += 1
            default: break
            }
        }
        let resolved = ended + cancelled
        guard resolved > 0 else { return nil }
        return Double(cancelled) / Double(resolved)
    }

    /// Count of toggle corrections (rapid flip-backs) in the feature window.
    func toggleCorrections(now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Self.featureWindow)
        return churnMarks.filter { $0 >= cutoff && $0 <= now }.count
    }

    /// Median press/hold duration of resolved manipulations in the window; `nil` if
    /// none carry a duration.
    func pressDurationMedian(now: Date) -> Double? {
        let ds: [Double] = inWindow(Self.featureWindow, now: now).compactMap { e in
            switch e.kind {
            case .ended, .cancelled: return e.duration
            default: return nil
            }
        }
        guard !ds.isEmpty else { return nil }
        let sorted = ds.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// The most recent events (newest first), for the RAW event-tick strata.
    func recent(limit: Int, now: Date) -> [InteractionEvent] {
        Array(inWindow(Self.featureWindow, now: now).suffix(limit).reversed())
    }
}

// MARK: - InteractionReadout (a pure snapshot the view + fusion consume)

/// A pure, timestamp-parameterized snapshot of the lens. Computed by
/// `InteractionChannel.snapshot(at:)` so the view can render a FRESH, aging value
/// each clock tick (via `TimelineView`) without any channel-side timer, and so the
/// same math backs the observed `reading`.
nonisolated struct InteractionReadout: Sendable {
    var availability: ChannelAvailability
    var quality: Double
    /// Aleatoric effort/load magnitude (0…1) — how much manipulation load is showing.
    var effort: Double
    var inputTempo: Double
    var inputTempoDelta: Double
    var cancelRate: Double
    var cancelRateDelta: Double
    var pressDurationMedian: Double?
    var toggleCorrections: Int
    var eventCount: Int
    var isStarved: Bool
    var baselineLearned: Bool
    var reading: ChannelReading
}

// MARK: - InteractionChannel (the @Observable lens)

/// The interaction-dynamics affect lens. `@MainActor @Observable` to match the other
/// channel objects; it wraps the pure `InteractionDynamics`, layers on the per-user
/// interaction baseline (via the shared `BaselineStore` — tempo + cancel-rate
/// medians, accrued PASSIVELY from use with NO calibration ritual, mirroring the eyes
/// idiom), availability/quality, and the honesty-bounded `ChannelReading`.
@MainActor
@Observable
final class InteractionChannel: AffectChannel {

    // MARK: Enablement (off by default — PRD law)

    /// `UserDefaults` key backing `isEnabled`. Default FALSE (every lens but face is
    /// opt-in), and — the privacy posture — collection runs ONLY while this is on.
    static let enabledKey = "lens.interaction.enabled"

    /// Whether the lens is switched on. Reads the flag directly so it always agrees
    /// with the `@AppStorage` toggle in the UI.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // MARK: BaselineStore feature keys (the .interaction entry)

    /// The per-user resting input tempo lives under `.interaction` / `inputTempo`.
    private static let tempoKey = FeatureKey.inputTempo.rawValue
    /// The per-user resting cancel rate lives under `.interaction` / `cancelRate`.
    private static let cancelKey = FeatureKey.cancelRate.rawValue

    // MARK: Tunables (channel-level; window math lives on `InteractionDynamics`)

    /// Events in the window for `quality` to read fully "dense". Below it, quality
    /// ramps up with the event count.
    static let densityTarget = 20.0
    /// A comfortable event count for a `.live` (vs `.degraded`-sparse) read.
    static let comfortableEvents = 12
    /// |tempo Δ| (per minute) that maps to full effort magnitude.
    static let tempoDeltaScale = 20.0
    /// Cancel rate that maps to full effort magnitude (50% cancels = maxed).
    static let cancelRateFull = 0.5
    /// Slow EMA rate for learning the per-user tempo / cancel-rate baselines.
    private static let baselineAlpha = 0.05
    /// Throttle: fold at most one baseline sample this often.
    private static let accrualThrottle: TimeInterval = 3
    /// Persist the shared baselines at most this often (avoid UserDefaults thrash).
    private static let saveInterval: TimeInterval = 15

    // MARK: Wiring

    /// The hub owns this channel (`let interaction`); the weak back-reference gives
    /// access to the shared `BaselineStore` for per-user baselining + persistence.
    @ObservationIgnored
    private weak var hub: AffectHub?

    /// The pure detector; observation-ignored (the HUD observes the derived scalars).
    @ObservationIgnored
    private var dynamics = InteractionDynamics()

    // MARK: Published state

    /// The channel-generic reading (published to fusion + the HUD). Starts unavailable.
    private(set) var reading: ChannelReading

    // Convenience observable scalars for the lens UI (updated on every `note`).
    private(set) var availability: ChannelAvailability = .unavailable
    private(set) var quality: Double = 0
    private(set) var effort: Double = 0
    private(set) var inputTempo: Double = 0
    private(set) var inputTempoDelta: Double = 0
    private(set) var cancelRate: Double = 0
    private(set) var cancelRateDelta: Double = 0
    private(set) var pressDurationMedian: Double?
    private(set) var toggleCorrections: Int = 0
    private(set) var eventCount: Int = 0
    private(set) var isStarved: Bool = true
    private(set) var baselineLearned = false

    // MARK: Transient bookkeeping (observation-ignored)

    @ObservationIgnored private var lastNoteDate = Date()
    @ObservationIgnored private var lastAccrue = Date.distantPast
    /// Seeded to construction time (app launch) — NOT `.distantPast` — so the throttle
    /// applies from the first note. In the app, construction long precedes any real
    /// interaction, so the first interaction still persists promptly; in the self-tests
    /// (synthetic past timestamps) it means `note` never writes to `UserDefaults`.
    @ObservationIgnored private var lastSave = Date()

    // MARK: AffectChannel

    var id: Channel { .interaction }

    /// The most recent reading, in the channel-generic form fusion consumes. Short-
    /// circuits to `.unavailable` while the lens is off (privacy-by-default), and
    /// otherwise recomputes FRESH against the current time so a stale "live" read can
    /// never outlive the interaction that produced it.
    var latest: ChannelReading {
        isEnabled ? snapshot(at: Date()).reading : Self.unavailableReading(at: lastNoteDate)
    }

    /// Drop transient per-channel state WITHOUT touching persisted calibration.
    func reset() {
        dynamics.clear()
        publishUnavailable(at: lastNoteDate)
    }

    // MARK: Init / hub wiring

    init() {
        reading = Self.unavailableReading(at: Date())
    }

    /// Called once by `AffectHub.init` after all hub properties exist. Wires the
    /// back-reference and reflects the initial enable + baseline state.
    func connect(hub: AffectHub) {
        self.hub = hub
        if isEnabled {
            recompute(now: Date())
        } else {
            publishUnavailable(at: Date())
        }
    }

    /// Prepare for a fresh activation: clear transient window state so turning the
    /// lens on starts clean, and reset the accrual throttle.
    func prepareForActivation() {
        dynamics.clear()
        lastAccrue = .distantPast
        recompute(now: Date())
    }

    /// The lens was switched off: clear the window and publish an unavailable reading
    /// (zero collection while off — `note` also guards on `isEnabled`).
    func deactivate() {
        dynamics.clear()
        publishUnavailable(at: Date())
    }

    /// The UI toggle calls this after flipping `enabledKey`; activate or deactivate
    /// accordingly. Unlike the eyes lens this needs no hub fan-out (interaction has no
    /// per-frame consumer — it is fed by the view's `SpatialEventGesture`).
    func refreshEnabled() {
        if isEnabled { prepareForActivation() } else { deactivate() }
    }

    // MARK: Ingest (the view calls this)

    /// Fold one abstract interaction event into the lens. No-op while disabled (the
    /// privacy posture: zero collection when off). Updates the per-user baseline
    /// (throttled) and republishes the reading.
    func note(_ event: InteractionEvent) {
        guard isEnabled else { return }
        lastNoteDate = event.t
        dynamics.note(event)
        accrueBaselineIfDue(now: event.t)
        recompute(now: event.t)
        maybeSaveBaselines(now: event.t)
    }

    /// View-driven refresh so the window AGES between interactions (no channel-side
    /// timer): the lens views call this — or read `snapshot(at:)` — on a 1 Hz clock.
    func refresh(now: Date = Date()) {
        guard isEnabled else { publishUnavailable(at: now); return }
        recompute(now: now)
    }

    // MARK: Snapshot (pure — the single source of the reading math)

    /// Compute a fresh readout for `now` WITHOUT mutating anything. Used by `latest`
    /// (fusion-facing, `now` = `Date()`), by `recompute` (the observed mirror), and by
    /// the lens views inside a `TimelineView` (`now` = `context.date`, for live aging).
    func snapshot(at now: Date) -> InteractionReadout {
        let count = dynamics.eventCount(now: now)
        let starved = count < InteractionDynamics.minEventsForSignal
        let tempo = dynamics.inputTempo(now: now)
        let cancel = dynamics.cancelRate(now: now) ?? 0
        let press = dynamics.pressDurationMedian(now: now)
        let churn = dynamics.toggleCorrections(now: now)

        // Delta-from-baseline (nil baseline ⇒ 0 delta — we can't claim a deviation
        // before a per-user baseline exists; the reading degrades until it does).
        let tempoStat = hub?.baselines.stat(.interaction, Self.tempoKey)
        let cancelStat = hub?.baselines.stat(.interaction, Self.cancelKey)
        let learned = (tempoStat?.mad ?? 0) > 1e-6
        let tempoDelta = tempoStat.map { tempo - $0.median } ?? 0
        let cancelDelta = cancelStat.map { cancel - $0.median } ?? 0

        // Availability (the three designed states): starved ⇒ unavailable (the F7
        // passive-viewing state); sparse OR immature baseline ⇒ degraded; else live.
        let availability: ChannelAvailability
        if starved {
            availability = .unavailable
        } else if count < Self.comfortableEvents || !learned {
            availability = .degraded
        } else {
            availability = .live
        }

        // Quality (epistemic) from density × baseline maturity; starved ⇒ very low.
        let density = min(1, Double(count) / Self.densityTarget)
        let maturity = learned ? 1.0 : 0.6
        let quality = starved ? density * 0.2 : density * maturity

        // Effort (aleatoric magnitude): cancel rate dominates, tempo deviation adds.
        let tempoMag = min(1, abs(tempoDelta) / Self.tempoDeltaScale)
        let cancelMag = min(1, cancel / Self.cancelRateFull)
        let effort = starved ? 0 : min(1, 0.6 * cancelMag + 0.4 * tempoMag)

        let reading = ChannelReading(
            channel: .interaction,
            date: now,
            availability: availability,
            quality: quality,
            valence: nil,   // interaction owns the EFFORT/ENGAGEMENT axis, NOT the
            arousal: nil,   // circumplex (§2 master law) — the load lives in features.
            intensity: effort,
            features: [
                .inputTempo: tempoDelta,       // Δ from the per-user tempo baseline
                .cancelRate: cancelDelta,      // Δ from the per-user cancel-rate baseline
                // Published under `.responseLatency` (the nearest existing FeatureKey):
                // semantically this is press-DURATION median — how long manipulations
                // are held, an honest dwell/effort proxy — NOT stimulus→response
                // latency, which is unmeasurable without stimulus timing we don't have.
                .responseLatency: press ?? 0
            ],
            posterior: nil   // non-face law
        )

        return InteractionReadout(
            availability: availability, quality: quality, effort: effort,
            inputTempo: tempo, inputTempoDelta: tempoDelta,
            cancelRate: cancel, cancelRateDelta: cancelDelta,
            pressDurationMedian: press, toggleCorrections: churn,
            eventCount: count, isStarved: starved, baselineLearned: learned,
            reading: reading
        )
    }

    /// The most recent events (newest first) for the RAW strata.
    func recentEvents(now: Date, limit: Int = 12) -> [InteractionEvent] {
        dynamics.recent(limit: limit, now: now)
    }

    // MARK: Reading assembly

    private func recompute(now: Date) {
        let s = snapshot(at: now)
        availability = s.availability
        quality = s.quality
        effort = s.effort
        inputTempo = s.inputTempo
        inputTempoDelta = s.inputTempoDelta
        cancelRate = s.cancelRate
        cancelRateDelta = s.cancelRateDelta
        pressDurationMedian = s.pressDurationMedian
        toggleCorrections = s.toggleCorrections
        eventCount = s.eventCount
        isStarved = s.isStarved
        baselineLearned = s.baselineLearned
        reading = s.reading
    }

    private func publishUnavailable(at date: Date) {
        availability = .unavailable
        quality = 0
        effort = 0
        inputTempo = 0
        inputTempoDelta = 0
        cancelRate = 0
        cancelRateDelta = 0
        pressDurationMedian = nil
        toggleCorrections = 0
        eventCount = 0
        isStarved = true
        baselineLearned = (hub?.baselines.stat(.interaction, Self.tempoKey)?.mad ?? 0) > 1e-6
        reading = Self.unavailableReading(at: date)
    }

    private static func unavailableReading(at date: Date) -> ChannelReading {
        ChannelReading(
            channel: .interaction,
            date: date,
            availability: .unavailable,
            quality: 0,
            valence: nil,
            arousal: nil,
            intensity: 0,
            features: [:],
            posterior: nil
        )
    }

    // MARK: Per-user baseline plumbing (shared BaselineStore)

    /// Passively accrue the per-user tempo + cancel-rate baselines: seed-if-absent
    /// then slow-retrack — NO calibration ritual (PRD §3.6: the interaction baseline
    /// accrues from first use). Gated on sufficient signal + a throttle so a burst of
    /// events doesn't over-fit the baseline.
    private func accrueBaselineIfDue(now: Date) {
        guard hub != nil else { return }
        guard dynamics.eventCount(now: now) >= InteractionDynamics.minEventsForSignal else { return }
        guard now.timeIntervalSince(lastAccrue) >= Self.accrualThrottle else { return }
        lastAccrue = now
        observeBaseline(Self.tempoKey, value: dynamics.inputTempo(now: now), alpha: Self.baselineAlpha)
        if let cancel = dynamics.cancelRate(now: now) {
            observeBaseline(Self.cancelKey, value: cancel, alpha: Self.baselineAlpha)
        }
        baselineLearned = (hub?.baselines.stat(.interaction, Self.tempoKey)?.mad ?? 0) > 1e-6
    }

    /// Seed-if-absent then slow-retrack a `.interaction` feature baseline in the
    /// shared store (mirrors `EyeChannel.observeBaseline`: `BaselineStore.retrack`
    /// only refines an EXISTING entry, so a windowed lens bootstraps the entry here).
    private func observeBaseline(_ feature: String, value: Double, alpha: Double) {
        guard let hub else { return }
        if hub.baselines.stat(.interaction, feature) == nil {
            var entry = hub.baselines.channels[.interaction] ?? .empty
            entry[feature] = RobustStat(median: value, mad: RobustStat.unknownMAD)
            hub.baselines.channels[.interaction] = entry
        } else {
            hub.baselines.retrack(channel: .interaction, feature: feature, observed: value, alpha: alpha)
        }
    }

    private func maybeSaveBaselines(now: Date) {
        guard now.timeIntervalSince(lastSave) >= Self.saveInterval else { return }
        lastSave = now
        hub?.baselines.save()
    }
}

#endif
