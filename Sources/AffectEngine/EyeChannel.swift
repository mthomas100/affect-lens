//
//  EyeChannel.swift
//  AffectLens
//
//  The EYES / BLINK lens (US-B5, PRD v2 §3.2 / §2.1 eyes row). A pure CONSUMER of
//  the face pipeline's per-frame `FrameAnalysis` fan-out (US-B5a) — it does NO
//  camera or Vision work of its own; it reads the already-extracted
//  `eyeOpenLeft/Right` openness the face lens hands it and turns it into blink
//  statistics. Zero face-pipeline change: this file adds a channel, it never
//  touches `EmotionEngine` / `FaceAnalyzer` / `CameraFeed`.
//
//  Honesty bar (PRD law, §0.3 / §3.2): eyes own the **attention / fatigue** axis
//  and, weakly, **arousal via blink RATE** — and NOTHING else. No valence (eyes
//  NEVER carry valence), no discrete-emotion posterior (the non-face law), and no
//  gaze direction anywhere (gaze is refused, §4.5 #2 — US-B5 also DELETES the
//  legacy gaze booleans). Blink is directionally ambiguous alone (low = engaged OR
//  early-task; high = fatigue OR anxiety OR mind-wandering; Maffei & Angrilli 2018;
//  Wierwille 1994), so the arousal it emits is magnitude-only and carries a
//  deliberately modest confidence that also shrinks while the per-user baseline is
//  still immature.
//
//  Everything off-by-default except face (PRD law): the lens is gated on the
//  `UserDefaults` key `lens.eyes.enabled`, default FALSE, and is only registered
//  on the hub's fan-out while enabled.
//

#if os(visionOS) || os(macOS)

import Foundation

// MARK: - BlinkDetector (the pure, testable core)

/// The blink-detection math, factored out as a `nonisolated` value type so it is
/// pure and unit-testable off the main actor (the `EyeChannel` @Observable class
/// wraps it). It implements the adaptive-EAR idiom of Soukupová & Čech 2016: a
/// closure threshold expressed as a FRACTION of a per-user open-eye baseline
/// (scale-invariant — the app's openness metric is an IOD-normalized palpebral
/// fissure height with no universal absolute value), N-consecutive-frame
/// confirmation, and a refractory guard.
///
/// **Timing budget (justifies N and the refractory).** The face pipeline runs at
/// ~15 Hz (`EmotionEngine.minProcessInterval = 1/15`), i.e. ~66 ms per analysis. A
/// human blink lasts ~100–400 ms, so it spans ~2–6 analyses. Therefore:
/// - `framesToConfirm = 2` is the floor that still catches the FASTEST (~130 ms)
///   blink while rejecting a single-frame openness dropout (a Vision hiccup).
/// - `refractory = 0.2 s` (~3 analyses) suppresses the reopen/settle jitter of ONE
///   blink from being recounted, while staying well under the typical inter-blink
///   gap (blinks rarely recur < ~300 ms apart).
/// - A closure sustained past `prolongedThreshold = 1 s` is a PROLONGED CLOSURE
///   (PERCLOS / AU43 semantics), NOT a blink — a normal blink never lasts a second.
///
/// A blink is counted on the REOPENING edge of a short closure (a run of ≥ N
/// closed frames that ends before it becomes prolonged). Counting on reopen — not
/// on the Nth closed frame — is what lets a prolonged closure be flagged WITHOUT
/// also being miscounted as a blink (a closure that never reopens short never
/// counts).
nonisolated struct BlinkDetector {

    // MARK: Configuration (documented constants; see the type doc for the timing budget)

    /// A frame counts as "closed" when openness < `closedFraction` × open-eye
    /// baseline. 0.5 = halfway between fully open and shut — well below a partial
    /// squint (attention/anger hover ~0.6–0.8 of baseline) yet safely above the
    /// near-zero openness of a true blink.
    var closedFraction: Double = 0.5
    /// N: consecutive closed analyses required to confirm a blink (see timing budget).
    var framesToConfirm: Int = 2
    /// Refractory after a counted blink; a reopen within this window can't recount.
    var refractory: TimeInterval = 0.2
    /// Closure duration beyond which the run is a PROLONGED closure (AU43/PERCLOS),
    /// not a blink.
    var prolongedThreshold: TimeInterval = 1.0
    /// Rolling window for blinks/min and openness variance.
    var windowDuration: TimeInterval = 60
    /// EMA rate at which the in-memory open-eye baseline tracks observed openness —
    /// matches `BaselineStore.retrack`'s alpha (0.02) so the fast in-memory copy and
    /// the persisted robust median stay in step.
    var baselineAlpha: Double = 0.02
    /// Only frames at ≥ this fraction of the baseline update the open-eye baseline,
    /// so squints and blink dips can never erode "open."
    var clearlyOpenFraction: Double = 0.8

    // MARK: State

    private struct Sample { var date: Date; var value: Double }

    /// The current estimate of the user's open-eye openness. `nil` until the first
    /// sample seeds it (or `seed(openBaseline:)` restores it from persistence).
    private(set) var openBaseline: Double?
    private var consecutiveClosed = 0
    private var closureStart: Date?
    /// Did the CURRENT closure run already cross `prolongedThreshold`?
    private var currentRunProlonged = false
    private var refractoryUntil: Date?
    private var blinkTimestamps: [Date] = []
    private var opennessSamples: [Sample] = []
    /// True while a prolonged (AU43/PERCLOS) closure is in progress.
    private(set) var prolongedClosure = false

    /// A discrete detection emitted by one `ingest`, if any.
    enum Event: Equatable, Sendable {
        case blink
        case prolongedClosureBegan
        case prolongedClosureEnded
    }

    /// All stored properties are defaulted; the explicit init keeps `BlinkDetector()`
    /// available at internal access despite the `private` state (a synthesized
    /// memberwise init would inherit `private`).
    init() {}

    // MARK: Rolling outputs

    /// Blinks per minute = the number of counted blinks inside the rolling 60 s
    /// window. `ingest` / `markAbsent` prune the window first, so this is the count
    /// as of the most recent frame.
    var blinksPerMinute: Double { Double(blinkTimestamps.count) }

    /// Variance of raw openness across the rolling window (blink dips included —
    /// a K2 instrument, not a de-blinked signal). 0 with < 2 samples.
    var eyeOpennessVariance: Double {
        guard opennessSamples.count > 1 else { return 0 }
        let xs = opennessSamples.map(\.value)
        let mean = xs.reduce(0, +) / Double(xs.count)
        let sq = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sq / Double(xs.count)
    }

    // MARK: Seeding

    /// Restore the open-eye baseline from a persisted per-user value (so a returning
    /// user detects blinks from frame 1 instead of re-bootstrapping). No-op once a
    /// baseline already exists.
    mutating func seed(openBaseline value: Double) {
        if openBaseline == nil { openBaseline = value }
    }

    // MARK: Ingest

    /// Fold one openness observation (mean of the two eyes) into the detector.
    /// Returns a discrete `Event` on a blink or a prolonged-closure transition.
    mutating func ingest(openness: Double, date: Date) -> Event? {
        prune(now: date)
        opennessSamples.append(Sample(date: date, value: openness))

        // Bootstrap the baseline from the first observation.
        guard let baseline = openBaseline else {
            openBaseline = openness
            return nil
        }

        let threshold = closedFraction * baseline

        if openness < threshold {
            // Closed this frame — extend (or start) the closure run.
            if closureStart == nil {
                closureStart = date
                consecutiveClosed = 0
                currentRunProlonged = false
            }
            consecutiveClosed += 1
            if !currentRunProlonged,
               let start = closureStart,
               date.timeIntervalSince(start) >= prolongedThreshold {
                currentRunProlonged = true
                prolongedClosure = true
                return .prolongedClosureBegan
            }
            return nil
        }

        // Open this frame — close out any run that was in progress.
        var event: Event?
        if closureStart != nil {
            if currentRunProlonged {
                // A prolonged closure just ended — NEVER a blink.
                prolongedClosure = false
                event = .prolongedClosureEnded
            } else if consecutiveClosed >= framesToConfirm {
                // A short, confirmed closure → a blink, unless within the refractory.
                let blocked = refractoryUntil.map { date < $0 } ?? false
                if !blocked {
                    blinkTimestamps.append(date)
                    refractoryUntil = date.addingTimeInterval(refractory)
                    event = .blink
                }
            }
            closureStart = nil
            consecutiveClosed = 0
            currentRunProlonged = false
        }

        // Track the open-eye baseline, but only from CLEARLY-open frames.
        if openness >= clearlyOpenFraction * baseline {
            openBaseline = baseline * (1 - baselineAlpha) + openness * baselineAlpha
        }
        return event
    }

    /// The eye-openness signal is unavailable this frame (face gone, or a
    /// face-turned-away frame with no usable eye geometry). Abandon any in-progress
    /// closure WITHOUT counting a blink and clear the prolonged flag — a face gap is
    /// never a blink and never a closure (PRD §3.2). Blink/openness history in the
    /// rolling window is preserved (and pruned by age).
    mutating func markAbsent(at date: Date) {
        prune(now: date)
        closureStart = nil
        consecutiveClosed = 0
        currentRunProlonged = false
        prolongedClosure = false
    }

    /// Drop transient run state but keep the learned open-eye baseline. Used when the
    /// lens is (re)enabled so it starts from a clean slate.
    mutating func clearTransient() {
        consecutiveClosed = 0
        closureStart = nil
        currentRunProlonged = false
        refractoryUntil = nil
        prolongedClosure = false
        blinkTimestamps.removeAll()
        opennessSamples.removeAll()
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-windowDuration)
        blinkTimestamps.removeAll { $0 < cutoff }
        opennessSamples.removeAll { $0.date < cutoff }
    }
}

// MARK: - EyeChannel (the @Observable lens)

/// The eyes/blink affect lens. `@MainActor @Observable` to match the other channel
/// objects and so the K2 HUD observes it directly; it wraps the pure
/// `BlinkDetector` and layers on the per-user baselines (via the shared
/// `BaselineStore`), availability/quality, and the honesty-bounded `ChannelReading`.
@MainActor
@Observable
final class EyeChannel: AffectChannel {

    // MARK: Enablement (off by default — PRD law)

    /// `UserDefaults` key backing `isEnabled`. Default FALSE: every lens except
    /// face is opt-in.
    static let enabledKey = "lens.eyes.enabled"
    /// Stable id for the hub's analysis-consumer registry.
    static let consumerID = "eyes"

    /// Whether the lens is switched on. Reads the `UserDefaults` flag directly so it
    /// always agrees with the HUD's `@AppStorage` toggle (default false).
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // MARK: BaselineStore feature keys

    /// The open-eye openness baseline lives under the `.eyes` entry with this
    /// feature key (a robust median + MAD, retracked at alpha 0.02 and persisted).
    private static let opennessKey = FeatureKey.eyeOpenness.rawValue
    /// The per-user resting blink RATE lives under `.eyes` / `blinkRate`.
    private static let restingRateKey = FeatureKey.blinkRate.rawValue

    // MARK: Tunables (channel-level; detector timing lives on `BlinkDetector`)

    /// Literature resting spontaneous blink rate, ~15–20/min (Jongkees & Colzato
    /// 2016). Used as the resting-rate default until a per-user rate is learned.
    static let literatureRestingBlinkRate: Double = 17
    /// Slow EMA rate for learning the per-user resting blink rate.
    private static let restingAlpha = 0.05
    /// Throttle: fold at most one resting-rate sample this often.
    private static let restingLearnInterval: TimeInterval = 3
    /// Need at least this many seconds of continuous face-live data before the
    /// windowed rate is trustworthy enough to teach the resting rate.
    private static let restingWindowMinSeconds: TimeInterval = 20
    /// Clearly-open frames needed for the SESSION openness baseline to read "mature"
    /// (~6 s at 15 Hz). A persisted, previously-retracked baseline counts as mature
    /// on its own (see `quality`).
    private static let opennessMaturityTarget = 90.0
    /// Face absent < this ⇒ `.degraded` (a brief look-away); ≥ this ⇒ `.unavailable`.
    private static let absenceGraceDegraded: TimeInterval = 2
    /// Deliberately modest confidence ceiling for the eyes' arousal meter — blink is
    /// directionally ambiguous alone, so it never speaks with high confidence.
    private static let arousalMaxConfidence = 0.35
    /// Speech gate factor (US-D12, PRD §3.5 honesty law): while the voice lens reports the
    /// user is SPEAKING, blinks are speech-driven, so the blink→arousal read is less
    /// honest. We keep COUNTING blinks (the raw display is unchanged) but multiply the
    /// arousal meter's CONFIDENCE down by this factor so the discounted read is visibly
    /// less trusted. 0.5 halves it — a strong hedge without zeroing a real (if noisier) cue.
    static let speechGateConfidenceFactor = 0.5
    /// |blink-rate Δ| (per minute) that maps to a full-magnitude arousal reading.
    private static let arousalDeltaScale = 12.0
    /// Persist the shared baselines at most this often (avoid UserDefaults thrash).
    private static let saveInterval: TimeInterval = 15

    // MARK: Wiring

    /// The hub owns this channel (`let eyes`); the back-reference (weak, no cycle)
    /// gives access to the shared `BaselineStore` for per-user baselining + persistence.
    @ObservationIgnored
    private weak var hub: AffectHub?

    // MARK: Detector + published state

    /// Observation-ignored: the pure detector mutates every frame; the HUD observes
    /// the derived scalars below, not the struct itself.
    @ObservationIgnored
    private var detector = BlinkDetector()

    /// The channel-generic reading (published to fusion + the HUD). Starts unavailable.
    private(set) var reading: ChannelReading

    // Convenience observable scalars for the K2 HUD (richer than the single
    // published feature; e.g. the HUD shows the RAW rate while `features[.blinkRate]`
    // carries the Δ-from-resting).
    private(set) var availability: ChannelAvailability = .unavailable
    private(set) var quality: Double = 0
    private(set) var blinksPerMinute: Double = 0
    private(set) var restingBlinkRate: Double = EyeChannel.literatureRestingBlinkRate
    private(set) var restingLearned = false
    private(set) var currentOpenness: Double?
    private(set) var openBaseline: Double?
    private(set) var eyeOpennessVariance: Double = 0
    private(set) var prolongedClosure = false
    /// Running count of blinks counted this session (drives the HUD "ticks").
    private(set) var sessionBlinkCount = 0
    /// True while the arousal confidence is being discounted by the voice speech gate
    /// (US-D12) — surfaced so the UI can note "discounted during speech".
    private(set) var speechGated = false
    /// True while the thermal governor (US-D13b, §8.1) has paused aux sensing to shed heat.
    private(set) var thermalPaused = false

    // MARK: Speech gate input (set by the hub, NOT observed — an input flag, not display)

    /// The live voice speech gate (PRD §3.5): the hub sets this from the voice snapshot
    /// BEFORE eye ingestion each tick. While true (voice live AND voiced), `publish`
    /// discounts the arousal meter's confidence by `speechGateConfidenceFactor` — blinks
    /// are still counted, only the arousal read is hedged. `@ObservationIgnored` so the
    /// per-tick set never churns SwiftUI; the effect reaches the UI through `reading`.
    @ObservationIgnored
    var speechGateActive = false

    // MARK: Transient bookkeeping (observation-ignored — internal, not HUD state)

    @ObservationIgnored private var lastDate = Date()
    @ObservationIgnored private var faceAbsentSince: Date?
    @ObservationIgnored private var liveSince: Date?
    @ObservationIgnored private var opennessSampleCount = 0
    @ObservationIgnored private var lastRestingLearn = Date.distantPast
    /// Seeded to construction time (app launch) — NOT `.distantPast` — so the save throttle
    /// applies from the first observation (the `InteractionChannel` guard): in the app the
    /// first real save lands within `saveInterval` of live data; in the DEBUG self-tests
    /// (synthetic past timestamps) it means a throwaway hub NEVER persists synthetic
    /// baselines into the real per-user store.
    @ObservationIgnored private var lastSave = Date()

    // MARK: AffectChannel

    var id: Channel { .eyes }

    /// The most recent reading, in the channel-generic form fusion consumes. Short-
    /// circuits to `.unavailable` while the lens is off (it isn't even registered on
    /// the hub then, so `reading` would be stale).
    var latest: ChannelReading {
        isEnabled ? reading : Self.unavailableReading(at: lastDate)
    }

    /// The SIGNED, [−1, 1]-normalized blink-rate arousal delta for CROSS-channel
    /// consensus (US-C10a, PRD v2 §4.4). Positive = blinking FASTER than the per-user
    /// resting rate, negative = slower; the magnitude is |Δ| squashed by the SAME
    /// `arousalDeltaScale` the published arousal `Meter` uses, so this is exactly that
    /// meter's magnitude carrying the sign of the raw (signed) blink-rate delta. `nil`
    /// when the lens has no usable arousal reading (off / warming / unavailable), so it
    /// is not counted as a vote.
    ///
    /// The published arousal `Meter` stays MAGNITUDE-ONLY on purpose — blink is
    /// directionally ambiguous ALONE (§3.2), so a lone eyes lens must not imply a
    /// direction. The sign is honest ONLY in cross-channel consensus, which is the one
    /// place it is used.
    var signedArousalDelta: Double? {
        guard isEnabled,
              reading.availability != .unavailable,
              let magnitude = reading.arousal?.value,
              let signedDelta = reading.features[.blinkRate]
        else { return nil }
        return signedDelta < 0 ? -magnitude : magnitude
    }

    /// Drop transient per-channel state (rolling window, closure run, session count)
    /// WITHOUT touching persisted calibration — the non-destructive channel reset.
    func reset() {
        detector.clearTransient()
        opennessSampleCount = 0
        sessionBlinkCount = 0
        faceAbsentSince = nil
        liveSince = nil
        publishUnavailable(at: lastDate)
    }

    // MARK: Init / hub wiring

    init() {
        reading = Self.unavailableReading(at: Date())
    }

    /// Called once by `AffectHub.init` after all hub properties exist. Wires the
    /// back-reference and seeds the detector + resting rate from any persisted
    /// per-user baseline.
    func connect(hub: AffectHub) {
        self.hub = hub
        if let median = hub.baselines.stat(.eyes, Self.opennessKey)?.median {
            detector.seed(openBaseline: median)
            openBaseline = median
        }
        if let s = hub.baselines.stat(.eyes, Self.restingRateKey) {
            restingBlinkRate = s.median
            restingLearned = s.mad > 1e-6
        }
    }

    /// Prepare for a fresh activation (the hub calls this before registering the
    /// consumer): clear transient detection state so turning the lens on starts clean.
    func prepareForActivation() {
        detector.clearTransient()
        opennessSampleCount = 0
        sessionBlinkCount = 0
        faceAbsentSince = nil
        liveSince = nil
    }

    /// The hub calls this when the lens is switched off: publish an unavailable
    /// reading (the consumer is also removed, so no more frames arrive).
    func deactivate() {
        publishUnavailable(at: lastDate)
    }

    /// The HUD toggle calls this after flipping `enabledKey`; re-registers (or
    /// unregisters) this lens on the hub's fan-out.
    func refreshEnabled() {
        hub?.refreshRegistration()
    }

    /// The hub calls this when the thermal governor pauses / resumes aux sensing
    /// (US-D13b, §8.1). While paused, `ingest` short-circuits and the lens reads honestly
    /// `.degraded`; on resume, the next fan-out frame republishes it live.
    func setThermalPaused(_ paused: Bool) {
        guard paused != thermalPaused else { return }
        thermalPaused = paused
        if paused, isEnabled { publish(now: lastDate, availability: .degraded) }
    }

    // MARK: Ingest (the fan-out consumer)

    /// Consume one processed `FrameAnalysis` from the hub's fan-out. Runs the blink
    /// detector on the mean eye openness, seeds/refines the per-user baselines, and
    /// republishes the reading. Absence is a first-class signal, never a fabricated blink.
    func ingest(_ analysis: FrameAnalysis) {
        guard isEnabled, !thermalPaused else { return }
        let now = analysis.date
        lastDate = now

        // No face → suspend detection; brief absence = degraded, sustained = unavailable.
        guard analysis.facePresent else {
            detector.markAbsent(at: now)
            liveSince = nil
            let since = faceAbsentSince ?? now
            faceAbsentSince = since
            let gap = now.timeIntervalSince(since)
            publish(now: now, availability: gap < Self.absenceGraceDegraded ? .degraded : .unavailable)
            return
        }
        faceAbsentSince = nil

        // Face present but no usable eye geometry (turned too far) → degraded, no blink.
        guard let l = analysis.eyeOpenLeft, let r = analysis.eyeOpenRight else {
            detector.markAbsent(at: now)
            liveSince = nil
            publish(now: now, availability: .degraded)
            return
        }

        if liveSince == nil { liveSince = now }
        let openness = (l + r) / 2
        currentOpenness = openness

        let event = detector.ingest(openness: openness, date: now)
        if event == .blink { sessionBlinkCount += 1 }

        // Passive per-user baseline seeding: only from clearly-open frames, so blinks
        // and squints never drag the open-eye baseline down. (The very first frame
        // seeds the detector baseline to its own value, so it clears this gate and is
        // mirrored into the store too.)
        if let base = detector.openBaseline, openness >= detector.clearlyOpenFraction * base {
            observeBaseline(Self.opennessKey, value: openness)
            opennessSampleCount += 1
        }

        learnRestingRateIfDue(now: now)

        // Warming up: baseline still bootstrapping ⇒ degrade (widen uncertainty).
        let warming = detector.openBaseline == nil
        publish(now: now, availability: warming ? .degraded : .live)

        maybeSaveBaselines(now: now)
    }

    // MARK: Per-user baseline plumbing (shared BaselineStore)

    /// Seed-if-absent then slow-retrack a `.eyes` feature baseline in the shared
    /// store. `BaselineStore.retrack` intentionally no-ops on an unbaselined feature
    /// (it only refines), so a windowed lens — which never runs the face's 36-sample
    /// ritual — bootstraps the entry here on first observation.
    private func observeBaseline(_ feature: String, value: Double, alpha: Double = 0.02) {
        guard let hub else { return }
        if hub.baselines.stat(.eyes, feature) == nil {
            var entry = hub.baselines.channels[.eyes] ?? .empty
            entry[feature] = RobustStat(median: value, mad: RobustStat.unknownMAD)
            hub.baselines.channels[.eyes] = entry
        } else {
            hub.baselines.retrack(channel: .eyes, feature: feature, observed: value, alpha: alpha)
        }
    }

    /// Learn the per-user resting blink rate as a slow median toward the current
    /// windowed rate — but only once ≥ `restingWindowMinSeconds` of CONTINUOUS live
    /// data backs the window, and throttled to `restingLearnInterval`.
    private func learnRestingRateIfDue(now: Date) {
        guard let liveSince else { return }
        guard now.timeIntervalSince(liveSince) >= Self.restingWindowMinSeconds else { return }
        guard now.timeIntervalSince(lastRestingLearn) >= Self.restingLearnInterval else { return }
        lastRestingLearn = now
        observeBaseline(Self.restingRateKey, value: detector.blinksPerMinute, alpha: Self.restingAlpha)
        if let s = hub?.baselines.stat(.eyes, Self.restingRateKey) {
            restingBlinkRate = s.median
            restingLearned = s.mad > 1e-6
        }
    }

    private func maybeSaveBaselines(now: Date) {
        guard now.timeIntervalSince(lastSave) >= Self.saveInterval else { return }
        lastSave = now
        hub?.baselines.save()
    }

    // MARK: Reading assembly

    private func publish(now: Date, availability: ChannelAvailability) {
        // Mirror the detector's rolling outputs to the observable scalars.
        blinksPerMinute = detector.blinksPerMinute
        openBaseline = detector.openBaseline
        eyeOpennessVariance = detector.eyeOpennessVariance
        prolongedClosure = detector.prolongedClosure
        self.availability = availability

        // Quality from baseline maturity: a persisted, previously-retracked baseline
        // (MAD > 0) is mature on its own; otherwise ramp with this session's samples.
        let persistedMature = (hub?.baselines.stat(.eyes, Self.opennessKey)?.mad ?? 0) > 1e-6
        let sessionMaturity = min(1, Double(opennessSampleCount) / Self.opennessMaturityTarget)
        let maturity = max(sessionMaturity, persistedMature ? 0.7 : 0)
        quality = maturity

        guard availability != .unavailable else {
            publishUnavailable(at: now)
            return
        }

        // Weak arousal from |blink-rate Δ| — magnitude only (directionally ambiguous),
        // confidence shrunk by maturity, availability, and resting-rate readiness.
        let delta = blinksPerMinute - restingBlinkRate
        let magnitude = min(1, abs(delta) / Self.arousalDeltaScale)
        let availFactor = availability == .live ? 1.0 : 0.5
        let restingFactor = restingLearned ? 1.0 : 0.5
        // Voice speech gate (US-D12, PRD §3.5): while the user is speaking, blinks are
        // speech-driven, so discount the arousal CONFIDENCE. Magnitude (and the raw blink
        // count) are untouched — only the trust in the read is hedged.
        speechGated = speechGateActive
        let gateFactor = speechGated ? Self.speechGateConfidenceFactor : 1.0
        let arousalConfidence = Self.arousalMaxConfidence * maturity * availFactor * restingFactor * gateFactor

        reading = ChannelReading(
            channel: .eyes,
            date: now,
            availability: availability,
            quality: maturity,
            valence: nil,                                   // eyes NEVER carry valence
            arousal: Meter(value: magnitude, confidence: arousalConfidence),
            intensity: magnitude,
            features: [
                .blinkRate: delta,                          // Δ from resting (delta-from-baseline contract)
                .eyeOpenVariance: eyeOpennessVariance,
                .prolongedClosure: prolongedClosure ? 1 : 0
            ],
            posterior: nil                                  // non-face law
        )
    }

    private func publishUnavailable(at date: Date) {
        availability = .unavailable
        speechGated = false
        reading = Self.unavailableReading(at: date)
    }

    /// A minimal, honest `.unavailable` eyes reading (no arousal, no features).
    private static func unavailableReading(at date: Date) -> ChannelReading {
        ChannelReading(
            channel: .eyes,
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
}

#endif
