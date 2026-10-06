//
//  VoiceChannel.swift
//  AffectLens
//
//  The VOICE affect lens (US-D12, PRD v2 §3.5 / §2.1 voice row / §8.0 K6). A
//  `@MainActor @Observable` channel that owns a `VoiceAnalyzer` actor (the mic tap +
//  prosody + SoundAnalysis) and polls its `ProsodySnapshot` at a slow cadence,
//  turning on-device prosody into an AROUSAL reading.
//
//  Honesty law (PRD §3.5, Juslin & Laukka 2003 — arousal robust in prosody, valence
//  markedly inconsistent): voice carries AROUSAL ONLY. The published `ChannelReading`
//  therefore has `valence: nil` and `posterior: nil` ALWAYS — never a valence, never a
//  discrete-emotion label, never transcription. Everything off-by-default except face:
//  gated on `lens.voice.enabled` (default FALSE); the mic is requested on enable and
//  FULLY released on disable / background (foreground-only).
//
//  SANCTIONED DEVIATION: PRD §6.8 sketches a ~1-min voice
//  calibration ritual; this wave ships PASSIVE baseline accrual instead (the eyes /
//  interaction idiom) — a literature-default arousal mapping until the per-user
//  voiced-F0 / intensity baselines mature via slow retrack on VOICED frames only. The
//  reading's quality / confidence reflect that immaturity honestly; the ritual UX may
//  come later.
//
//  Speech gate (PRD honesty law, §3.5): while this lens is live AND currently voiced,
//  the hub discounts the eyes lens's blink→arousal evidence (speech drives blinks). The
//  hub reads `speechGateActive` each tick — this channel owns only that flag.
//

#if os(visionOS) || os(macOS)

import Foundation

/// The voice affect lens. `@MainActor @Observable` to match the other channel objects
/// and so the lens view + K6 HUD observe it directly; it owns the off-main
/// `VoiceAnalyzer` actor and layers on per-user baselining (via the shared
/// `BaselineStore`), availability / quality, laughter corroboration, and the
/// honesty-bounded (arousal-only) `ChannelReading`.
@MainActor
@Observable
final class VoiceChannel: AffectChannel {

    // MARK: Enablement (off by default — PRD law)

    /// `UserDefaults` key backing `isEnabled` (default FALSE; every lens but face is opt-in).
    static let enabledKey = "lens.voice.enabled"

    /// Whether the lens is switched on. Reads the flag directly so it always agrees with
    /// the `@AppStorage` toggle in the UI.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // MARK: BaselineStore feature keys (the .voice entry)

    /// The per-user resting voiced-F0 median lives under `.voice` / `vocalF0`.
    private static let f0Key = FeatureKey.vocalF0.rawValue
    /// The per-user resting voiced-intensity median lives under `.voice` / `vocalIntensity`.
    private static let intensityKey = FeatureKey.vocalIntensity.rawValue

    // MARK: Tunables (documented; the prosody math lives on `ProsodyMath`)

    /// Literature-default reference voiced F0 (Hz) used UNTIL the per-user baseline
    /// matures — a rough adult conversational mean (individuals vary hugely, ~85–255 Hz),
    /// so any reading built on it is deliberately LOW confidence (see `referenceFactor`).
    static let literatureF0: Double = 165
    /// Literature-default reference voiced intensity (RMS) until the baseline matures.
    static let literatureIntensity: Double = 0.05
    /// |F0 Δ| (Hz) above your baseline that maps to full activation.
    static let f0DeltaScale: Double = 60
    /// |intensity Δ| (RMS) above your baseline that maps to full activation.
    static let intensityDeltaScale: Double = 0.08
    /// Voice→arousal is a robust cue (Juslin & Laukka), but DIY prosody + a passively
    /// accrued baseline cap the confidence below certainty.
    static let arousalMaxConfidence: Double = 0.5
    /// Slow EMA for learning the per-user voiced-F0 / intensity baselines.
    private static let baselineAlpha: Double = 0.03
    /// Voiced samples for the session baseline to read fully "mature".
    static let maturityTarget: Double = 40
    /// Minimum voiced frames in the window for a `.live` (vs `.degraded`-sparse) read.
    static let liveVoicedMin = 3
    /// No voiced frame in this long ⇒ nothing to read right now ⇒ `.degraded` (mic still
    /// on — never silently unavailable; PRD "widen uncertainty, never drop").
    static let silenceGrace: TimeInterval = 6
    /// Snapshot poll cadence — prosody is slow, so ~3 Hz is plenty (and cheap).
    private static let pollInterval: Duration = .milliseconds(333)
    /// Persist the shared baselines at most this often (avoid UserDefaults thrash).
    private static let saveInterval: TimeInterval = 15
    /// The rolling window (seconds) over which a fired laughter event still counts as
    /// "recent" for F6 corroboration (US-D14b). The published `recentLaughter` feature is
    /// 1 at the instant of a laugh and decays LINEARLY to 0 across this window, so F6 reads
    /// a recency-weighted corroboration, not a stale one. 30 s is a generous conversational
    /// window (laughter and the positive expression it echoes are seconds apart, not frames).
    static let laughterRecencyWindow: TimeInterval = 30

    /// The recency weight ∈ [0, 1] of the last laughter event as of `now` — 1 at the event,
    /// ramping linearly to 0 at `laughterRecencyWindow`, and 0 with no laughter yet (never a
    /// fabricated corroboration). Pure + static so F6's math and the self-tests can call it.
    static func laughterRecency(lastLaughter: Date?, now: Date) -> Double {
        guard let last = lastLaughter else { return 0 }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed >= 0, elapsed <= laughterRecencyWindow else { return 0 }
        return 1 - elapsed / laughterRecencyWindow
    }

    // MARK: Wiring

    /// The hub owns this channel (`let voice`); the weak back-reference gives access to
    /// the shared `BaselineStore` (per-user baselining + persistence) and the event bus.
    @ObservationIgnored
    private weak var hub: AffectHub?

    /// The off-main analyzer actor (mic tap + prosody + SoundAnalysis). Created inert;
    /// started only on enable.
    @ObservationIgnored
    private let analyzer = VoiceAnalyzer()

    /// The MainActor poll loop pulling snapshots at `pollInterval`; nil while stopped.
    @ObservationIgnored
    private var pollTask: Task<Void, Never>?

    // MARK: Published state

    /// The channel-generic reading (published to fusion + the HUD). Starts unavailable.
    private(set) var reading: ChannelReading

    // Convenience observable scalars for the lens UI + K6 HUD.
    private(set) var availability: ChannelAvailability = .unavailable
    private(set) var quality: Double = 0
    private(set) var micDenied = false
    private(set) var engineRunning = false
    /// A typed reason the engine isn't running (session/engine/no-input/backgrounded), for
    /// the K6 HUD's engine-status line.
    private(set) var startFailureReason: String?
    private(set) var isSpeaking = false
    private(set) var currentLevel: Double = 0
    private(set) var f0Median: Double?
    private(set) var latestVoicedF0: Double?
    private(set) var f0Variance: Double = 0
    private(set) var intensityMedian: Double = 0
    private(set) var voicedFraction: Double = 0
    private(set) var onsetRate: Double = 0
    private(set) var arousal: Meter?
    private(set) var baselineLearned = false
    private(set) var voicedSampleCount = 0
    /// Running count of laughter ticks this session (drives the K6 HUD counter).
    private(set) var laughterCount = 0
    /// True while the thermal governor (US-D13b, §8.1) has paused aux sensing to shed heat.
    private(set) var thermalPaused = false

    // MARK: Transient bookkeeping (observation-ignored)

    @ObservationIgnored private var backgrounded = false
    @ObservationIgnored private var lastVoicedDate: Date?
    /// When the last on-device laughter event fired — backs the recency-weighted
    /// `recentLaughter` feature F6 corroborates on (US-D14b). Session-scoped, never persisted.
    @ObservationIgnored private var lastLaughterDate: Date?
    /// Seeded to construction time (app launch) — NOT `.distantPast` — so the save throttle
    /// applies from the first snapshot (the `InteractionChannel` guard): in the app the
    /// first real save lands within `saveInterval` of live data; in the DEBUG self-tests
    /// (synthetic past timestamps) it means a throwaway hub NEVER persists synthetic
    /// baselines into the real per-user store.
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var lastReferenceF0 = VoiceChannel.literatureF0
    @ObservationIgnored private var lastReferenceIntensity = VoiceChannel.literatureIntensity

    // MARK: AffectChannel

    var id: Channel { .voice }

    /// The most recent reading, in the channel-generic form fusion consumes. Short-
    /// circuits to `.unavailable` while the lens is off.
    var latest: ChannelReading {
        isEnabled ? reading : Self.unavailableReading(at: reading.date)
    }

    /// The live speech gate for the eyes lens (PRD honesty law, §3.5): true ONLY while the
    /// voice lens is live AND currently voiced. The hub reads this each tick and sets
    /// `eyes.speechGateActive` BEFORE eye ingestion, so the blink→arousal read is
    /// discounted while the user is speaking (speech drives blinks).
    var speechGateActive: Bool {
        isEnabled && availability == .live && isSpeaking
    }

    /// Recover the SIGNED activation ∈ [−1, 1] behind a published voice arousal `Meter`.
    /// `ProsodyMath.arousal` encodes `value = 0.5 + 0.5 × activation` (activation = the
    /// scale-normalized F0 + intensity delta blend), so this inverts that mapping — one
    /// shared formula for the live congruence vote, the trace replayer, and the self-tests
    /// (no literal drift). `nonisolated` + pure so nonisolated callers (`TraceReplayer`)
    /// can use it.
    nonisolated static func signedActivation(from meter: Meter) -> Double {
        max(-1, min(1, (meter.value - 0.5) * 2))
    }

    /// The SIGNED, [−1, 1]-normalized prosody arousal delta for CROSS-channel consensus
    /// (US-C10a, PRD v2 §4.4 — voice OWNS arousal, §3.5). Positive = pitch/loudness above
    /// your own voiced baseline, negative = below; recovered from the SAME
    /// `ProsodyMath.arousal` meter the lens publishes (see `signedActivation`). `nil` when
    /// there's no usable arousal read (off / silent / unavailable / thermally paused), so
    /// it doesn't vote. The published `Meter` value stays a 0.5-centred magnitude display;
    /// the sign is honest only in cross-channel consensus — the one place it is used.
    var signedArousalDelta: Double? {
        guard isEnabled, reading.availability != .unavailable,
              let meter = reading.arousal else { return nil }
        return Self.signedActivation(from: meter)
    }

    /// Drop transient per-channel display state WITHOUT touching persisted baselines.
    func reset() {
        voicedSampleCount = 0
        laughterCount = 0
        lastVoicedDate = nil
        lastLaughterDate = nil
        publishUnavailable(reason: startFailureReason)
    }

    // MARK: Init / hub wiring

    init() {
        reading = Self.unavailableReading(at: Date())
    }

    /// Called once by `AffectHub.init` after all hub properties exist. Wires the back-
    /// reference and seeds the per-user baseline references.
    ///
    /// Privacy-first (US-D12): the mic NEVER auto-arms on launch. Unlike the
    /// zero-permission eyes / interaction lenses (which auto-resume across launches), voice
    /// starts DISARMED every session — we reset the enabled flag here so the toggle is off,
    /// the engine is stopped, and no mic indicator appears until the user explicitly opts in
    /// this session. This also guarantees a throwaway hub (e.g. the DEBUG self-tests) can
    /// never trigger a surprise mic start.
    func connect(hub: AffectHub) {
        self.hub = hub
        refreshReferences()
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
    }

    // MARK: Enable lifecycle (self-managed — voice is NOT on the analysis fan-out)

    /// The UI toggle calls this after flipping `enabledKey`. Enabling requests the mic,
    /// starts the analyzer + poll loop; disabling stops everything and fully releases the
    /// mic. Both run on a `Task` because the analyzer start is async (permission + engine).
    func refreshEnabled() {
        if isEnabled {
            Task { await enableFlow() }
        } else {
            Task { await disableFlow() }
        }
    }

    /// The hub calls this when the thermal governor pauses / resumes aux sensing (US-D13b,
    /// §8.1). While paused, `apply` short-circuits (the mic session is left to the voice
    /// lifecycle — the governor only halts the prosody→arousal PROCESSING) and the lens
    /// reads honestly `.degraded`; on resume, the next poll republishes it.
    func setThermalPaused(_ paused: Bool) {
        guard paused != thermalPaused else { return }
        thermalPaused = paused
        if paused, isEnabled {
            availability = .degraded
            arousal = nil
            quality = 0
            isSpeaking = false
            reading = ChannelReading(channel: .voice, date: Date(), availability: .degraded,
                                     quality: 0, valence: nil, arousal: nil, intensity: 0,
                                     features: [:], posterior: nil)
        }
    }

    /// scenePhase → background/foreground. Foreground-only: background releases the mic
    /// fully (keeping `enabledKey`), foreground re-starts it if still enabled.
    func handleScenePhase(background: Bool) {
        if background {
            backgrounded = true
            Task { await suspendForBackground() }
        } else if backgrounded {
            backgrounded = false
            if isEnabled { Task { await enableFlow() } }
        }
    }

    private func enableFlow() async {
        backgrounded = false
        micDenied = false
        // Publish a "warming" degraded state immediately so the card/lens isn't blank.
        availability = .degraded
        startFailureReason = nil

        let granted = await Permissions.requestMicIfNeeded()
        guard granted else {
            micDenied = true
            engineRunning = false
            publishUnavailable(reason: "Microphone access is off")
            return
        }
        // The user may have toggled off / backgrounded during the permission await.
        guard isEnabled, !backgrounded else { return }

        do {
            try await analyzer.start()
            engineRunning = true
            startFailureReason = nil
            startPolling()
        } catch {
            engineRunning = false
            publishUnavailable(reason: "\(error)")
        }
    }

    private func disableFlow() async {
        stopPolling()
        await analyzer.stop()
        engineRunning = false
        isSpeaking = false
        publishUnavailable(reason: nil)
    }

    private func suspendForBackground() async {
        stopPolling()
        await analyzer.stop()
        engineRunning = false
        isSpeaking = false
        publishUnavailable(reason: "Paused in background")
    }

    // MARK: Polling (MainActor loop over the actor snapshot)

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snap = await self.analyzer.snapshot()
                self.apply(snap)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Apply a snapshot

    /// Fold one `ProsodySnapshot` into the published state: mirror the raw scalars, surface
    /// laughter corroboration, accrue the per-user baseline on VOICED frames, and republish
    /// the arousal-only reading. Internal (not private) so the DEBUG self-tests can drive
    /// the channel with synthetic snapshots — the exact `HandsChannel.apply` idiom.
    func apply(_ snap: ProsodySnapshot) {
        guard isEnabled, !thermalPaused else { return }   // aux sensing paused to shed heat (§8.1)
        engineRunning = snap.engineRunning
        guard snap.engineRunning else {
            publishUnavailable(reason: snap.unavailableReason)
            return
        }

        currentLevel = snap.currentLevel
        isSpeaking = snap.isSpeaking
        f0Median = snap.f0Median
        latestVoicedF0 = snap.latestVoicedF0
        f0Variance = snap.f0Variance
        intensityMedian = snap.intensityMedian
        voicedFraction = snap.voicedFraction
        onsetRate = snap.onsetRate

        // On-device laughter → the bus + a corroboration insight (F6 later). NEVER a verdict.
        if snap.laughter { emitLaughterEvent(at: snap.date) }

        // Passive per-user baseline accrual — ONLY on voiced frames, so silence/noise never
        // drags the resting prosody. Seed-if-absent then slow-retrack (the eyes/interaction
        // idiom: `BaselineStore.retrack` no-ops on an unbaselined feature).
        if snap.isSpeaking, let f0 = snap.latestVoicedF0 {
            lastVoicedDate = snap.date
            voicedSampleCount += 1
            observeBaseline(Self.f0Key, value: f0)
            if snap.voicedIntensityMedian > 0 {
                observeBaseline(Self.intensityKey, value: snap.voicedIntensityMedian)
            }
        }
        refreshReferences()
        publishReading(from: snap)
        maybeSave(now: snap.date)
    }

    // MARK: Reading assembly

    private func publishReading(from snap: ProsodySnapshot) {
        let hasVoiced = snap.voicedCount > 0
        let silentFor = lastVoicedDate.map { snap.date.timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        // References: the per-user baseline median if present, else the literature default.
        let f0Ref = lastReferenceF0
        let intRef = lastReferenceIntensity

        // Deltas — windowed voiced medians vs the SLOW baseline (a fast rise reads as
        // arousal; the baseline catches up over seconds). No voiced data ⇒ 0 delta.
        let f0Delta = (snap.f0Median ?? f0Ref) - f0Ref
        let intDelta = hasVoiced ? (snap.voicedIntensityMedian - intRef) : 0

        // Maturity from voiced-sample density (a persisted, previously-learned baseline is
        // mature on its own).
        let sessionMaturity = min(1, Double(voicedSampleCount) / Self.maturityTarget)
        let maturity = max(sessionMaturity, baselineLearned ? 0.7 : 0)

        // Availability (three designed states): silent / no voiced ⇒ degraded (mic on,
        // nothing to read); sparse voiced ⇒ degraded; else live. An immature baseline
        // discounts CONFIDENCE (below), not availability.
        let availability: ChannelAvailability
        if !hasVoiced || silentFor > Self.silenceGrace || snap.voicedCount < Self.liveVoicedMin {
            availability = .degraded
        } else {
            availability = .live
        }

        // Confidence is discounted while the baseline is still the literature default
        // (referenceFactor) and while degraded (availFactor) — honest immaturity.
        let referenceFactor = baselineLearned ? 1.0 : 0.5
        let availFactor = (availability == .live ? 1.0 : 0.5) * referenceFactor
        let meter: Meter? = hasVoiced
            ? ProsodyMath.arousal(f0Delta: f0Delta, intensityDelta: intDelta,
                                  f0Scale: Self.f0DeltaScale, intensityScale: Self.intensityDeltaScale,
                                  maturity: maturity, availability: availFactor,
                                  maxConfidence: Self.arousalMaxConfidence)
            : nil

        self.availability = availability
        self.quality = maturity
        self.arousal = meter
        reading = ChannelReading(
            channel: .voice,
            date: snap.date,
            availability: availability,
            quality: maturity,
            valence: nil,                       // voice NEVER carries valence (§3.5)
            arousal: meter,                     // arousal ONLY
            intensity: meter?.value ?? 0,
            features: [
                .vocalF0: f0Delta,              // Δ from the per-user voiced-F0 baseline
                .vocalIntensity: intDelta,      // Δ from the per-user voiced-intensity baseline
                .vocalTempo: snap.onsetRate,    // raw onset-rate proxy (no per-user tempo baseline yet)
                // Recency-weighted "a laugh registered recently" (US-D14b F6). Decays over
                // `laughterRecencyWindow`, so F6's PURE fuse reads the corroborating laughter
                // without touching the event bus — a sound-EVENT recency, never a valence.
                .recentLaughter: Self.laughterRecency(lastLaughter: lastLaughterDate, now: snap.date)
            ],
            posterior: nil                      // non-face law
        )
    }

    private func publishUnavailable(reason: String?) {
        availability = .unavailable
        quality = 0
        arousal = nil
        isSpeaking = false
        currentLevel = 0
        startFailureReason = reason
        reading = Self.unavailableReading(at: Date())
    }

    /// A minimal, honest `.unavailable` voice reading (no arousal, no features).
    private static func unavailableReading(at date: Date) -> ChannelReading {
        ChannelReading(
            channel: .voice,
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

    // MARK: Laughter corroboration (bus + insight, never a verdict)

    private func emitLaughterEvent(at date: Date) {
        laughterCount += 1
        lastLaughterDate = date          // seed the recency-weighted `recentLaughter` feature (F6)
        guard let hub else { return }
        let event = AffectEvent(
            t: date,
            channel: .voice,
            kind: .vocalEvent,
            magnitude: 0.6,
            confidence: 0.5,
            evidence: [.vocalIntensity],
            baselineDelta: nil
        )
        hub.emitChannelEvent(event)
    }

    // MARK: Per-user baseline plumbing (shared BaselineStore)

    /// Seed-if-absent then slow-retrack a `.voice` feature baseline (mirrors
    /// `EyeChannel.observeBaseline`).
    private func observeBaseline(_ feature: String, value: Double) {
        guard let hub else { return }
        if hub.baselines.stat(.voice, feature) == nil {
            var entry = hub.baselines.channels[.voice] ?? .empty
            entry[feature] = RobustStat(median: value, mad: RobustStat.unknownMAD)
            hub.baselines.channels[.voice] = entry
        } else {
            hub.baselines.retrack(channel: .voice, feature: feature, observed: value, alpha: Self.baselineAlpha)
        }
    }

    private func refreshReferences() {
        guard let hub else { return }
        if let s = hub.baselines.stat(.voice, Self.f0Key) {
            lastReferenceF0 = s.median
            baselineLearned = s.mad > 1e-6
        }
        if let s = hub.baselines.stat(.voice, Self.intensityKey) {
            lastReferenceIntensity = s.median
        }
    }

    private func maybeSave(now: Date) {
        guard now.timeIntervalSince(lastSave) >= Self.saveInterval else { return }
        lastSave = now
        hub?.baselines.save()
    }
}

#endif
