//
//  HandsChannel.swift
//  AffectLens
//
//  The HANDS affect lens (US-D13a, PRD v2 §3.3 / §2.1 hands row). A `@MainActor
//  @Observable` channel that receives throttled `HandKinematicsSnapshot`s (pushed by the
//  `ImmersiveSensingCoordinator`, which owns the ARKit session + `HandAnalyzer` actor) and
//  turns hand kinematics into an AROUSAL reading plus self-touch / gesture events.
//
//  Honesty law (PRD §2 master law, §3.3): hands own AROUSAL / agitation / load — and
//  NOTHING else. The published `ChannelReading` therefore ALWAYS has `valence: nil` and
//  `posterior: nil` (there is no valence Meter from hands; hand aperture is a tension
//  FEATURE only). Self-touch is read as a RATE, never a single touch. There is NO gesture
//  dictionary — a "gesture burst" is a motion-energy spike, never a named pose (refused
//  list §4.5 #10; the banlist traps "anxiety" regardless).
//
//  Availability is a first-class, THREE-state design (never faked): `.unavailable` with a
//  TYPED reason (immersive space closed / hand-tracking auth denied / provider unsupported
//  / lens disabled / session error), `.degraded` (immersive open but hands out of frustum —
//  sparse recent data), and `.live` (hand data flowing).
//
//  SANCTIONED DEVIATION (mirrors voice/eyes): PRD §3.3 sketches an
//  emteq-style max-intensity ritual; this wave ships PASSIVE baseline accrual instead — a
//  literature-default resting-speed mapping + slow retrack toward the user's own resting
//  hand motion, with quality reflecting that immaturity honestly. Chua et al. 2024's
//  within-user-only finding is exactly why the per-user baseline (never a population scale)
//  is mandatory.
//
//  Everything off-by-default except face (PRD law): gated on `lens.hands.enabled`
//  (default FALSE). Even while the immersive space is open, a disabled lens reads
//  `.unavailable(.disabled)` and emits nothing.
//

#if os(visionOS) || os(macOS)

import Foundation

/// The hands affect lens. `@MainActor @Observable` to match the other channel objects and
/// so the hands lens view + K1 HUD observe it directly; it consumes the off-main
/// `HandAnalyzer` snapshots (via the coordinator) and layers on per-user baselining (the
/// shared `BaselineStore`), availability / quality, self-touch / gesture events, and the
/// honesty-bounded (arousal-only) `ChannelReading`.
@MainActor
@Observable
final class HandsChannel: AffectChannel {

    // MARK: Enablement (off by default — PRD law)

    /// `UserDefaults` key backing `isEnabled` (default FALSE; every lens but face is opt-in).
    static let enabledKey = "lens.hands.enabled"

    /// Whether the lens is switched on. Reads the flag directly so it always agrees with the
    /// `@AppStorage` toggle in the UI.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // MARK: Typed unavailable reasons (surfaced on the lens + the K1 HUD)

    /// Why the hands channel isn't producing a reading right now — richer than a bool so the
    /// lens card / K1 HUD speak honestly (never a faked value).
    nonisolated enum Unavailable: Equatable, Sendable {
        /// The hands lens is switched off.
        case disabled
        /// The immersive aura space is closed (hand tracking only runs while it's open).
        case immersiveClosed
        /// ARKit hand-tracking authorization was denied.
        case authDenied
        /// `HandTrackingProvider` isn't supported here (e.g. the simulator).
        case providerUnsupported
        /// The ARKit session failed to start.
        case sessionError(String)
    }

    // MARK: BaselineStore feature key (the .hands entry)

    /// The per-user resting hand-motion-energy baseline lives under `.hands` / `gestureEnergy`.
    private static let energyKey = FeatureKey.gestureEnergy.rawValue

    // MARK: Tunables (documented; PROVISIONAL — the sanctioned literature-default deviation)

    /// Literature-default resting hand speed (m/s) used to SEED the per-user baseline until
    /// it matures — resting hands sit near zero motion (tracking jitter ~0.02–0.05 m/s), so
    /// this small seed plus a slow retrack toward the user's actual resting floor is honest.
    static let literatureRestingSpeed: Double = 0.03
    /// |motion-energy Δ| (m/s) above resting that maps to a full-magnitude (±1) arousal read.
    /// A brisk gesture reaches well past this; provisional until on-device tuning (K1).
    static let energyDeltaScale: Double = 0.5
    /// Self-touch RATE (events/min) that maps to full self-touch load in fusion. Resting
    /// self-touch is ~0/min, so the raw rate IS the delta from the resting floor.
    static let selfTouchRateScale: Double = 3.0
    /// Deliberately modest confidence ceiling for the hands arousal meter — hand-only affect
    /// is within-user-only (Chua 2024), so it never speaks with high confidence.
    static let arousalMaxConfidence: Double = 0.4
    /// Velocity samples in the window for a dense `.live` (vs `.degraded`-sparse) read.
    static let liveSampleMin = 8
    /// Slow EMA for learning the per-user resting hand speed.
    private static let baselineAlpha: Double = 0.02
    /// Tracked motion samples for the session maturity to read fully "mature".
    static let maturityTarget: Double = 120
    /// Persist the shared baselines at most this often (avoid UserDefaults thrash).
    private static let saveInterval: TimeInterval = 15
    /// Rate-limit the NARRATED insight for self-touch / gesture events (the bus still gets
    /// every event; only the insight-feed narration is throttled, so it can't spam).
    static let insightGap: TimeInterval = 8

    // MARK: Wiring

    /// The hub owns this channel (`let hands`); the weak back-reference gives access to the
    /// shared `BaselineStore` (per-user baselining + persistence) and the event bus.
    @ObservationIgnored
    private weak var hub: AffectHub?

    // MARK: Published state

    /// The channel-generic reading (published to fusion + congruence + the HUD). Starts unavailable.
    private(set) var reading: ChannelReading

    // Convenience observable scalars for the lens UI + K1 HUD.
    private(set) var availability: ChannelAvailability = .unavailable
    /// The typed reason while `.unavailable`; `nil` while `.live` / `.degraded`.
    private(set) var unavailableReason: Unavailable? = .immersiveClosed
    private(set) var quality: Double = 0
    private(set) var meanJointSpeed: Double = 0
    private(set) var restingSpeed: Double = HandsChannel.literatureRestingSpeed
    private(set) var restingLearned = false
    private(set) var handAperture: Double?
    private(set) var selfTouchRate: Double = 0
    private(set) var gestureRate: Double = 0
    private(set) var tracked = false
    private(set) var sessionSelfTouchCount = 0
    private(set) var sessionGestureBurstCount = 0
    /// True while the thermal governor (US-D13b, §8.1) has paused aux sensing to shed heat.
    private(set) var thermalPaused = false

    // MARK: Transient bookkeeping (observation-ignored)

    @ObservationIgnored private var motionSampleCount = 0
    /// Seeded to construction time (app launch) — NOT `.distantPast` — so the save throttle
    /// applies from the first snapshot (the `InteractionChannel` guard): in the app the
    /// first real save lands within `saveInterval` of live data; in the DEBUG self-tests
    /// (synthetic past timestamps) it means a throwaway hub NEVER persists synthetic
    /// baselines into the real per-user store.
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var lastSelfTouchInsight = Date.distantPast
    @ObservationIgnored private var lastGestureInsight = Date.distantPast

    // MARK: AffectChannel

    var id: Channel { .hands }

    /// The most recent reading, in the channel-generic form fusion consumes. Short-circuits
    /// to `.unavailable` while the lens is off.
    var latest: ChannelReading {
        isEnabled ? reading : Self.unavailableReading(at: reading.date)
    }

    /// The SIGNED, [−1, 1]-normalized motion-energy arousal delta for CROSS-channel consensus
    /// (US-C10a, PRD v2 §4.4). Positive = moving MORE than the user's resting hands, negative =
    /// calmer; magnitude is |Δ| squashed by the SAME `energyDeltaScale` the published arousal
    /// `Meter` uses. `nil` when there's no usable arousal read (off / warming / unavailable), so
    /// it doesn't vote. The published arousal `Meter` value stays magnitude-only (max(0, ·)); the
    /// sign is honest only in cross-channel consensus — the one place it is used.
    var signedArousalDelta: Double? {
        guard isEnabled, reading.availability != .unavailable,
              let raw = reading.features[.gestureEnergy] else { return nil }
        return max(-1, min(1, raw / Self.energyDeltaScale))
    }

    /// Drop transient per-channel state WITHOUT touching persisted calibration.
    func reset() {
        motionSampleCount = 0
        sessionSelfTouchCount = 0
        sessionGestureBurstCount = 0
        publishUnavailable(isEnabled ? .immersiveClosed : .disabled)
    }

    // MARK: Init / hub wiring

    init() {
        reading = Self.unavailableReading(at: Date())
    }

    /// Called once by `AffectHub.init` after all hub properties exist. Wires the
    /// back-reference, seeds the resting-speed reference from any persisted baseline, and
    /// reflects the initial (space-closed) state honestly.
    func connect(hub: AffectHub) {
        self.hub = hub
        if let s = hub.baselines.stat(.hands, Self.energyKey) {
            restingSpeed = s.median
            restingLearned = s.mad > 1e-6
        }
        publishUnavailable(isEnabled ? .immersiveClosed : .disabled)
    }

    /// The UI toggle calls this after flipping `enabledKey`. Enabling while the immersive
    /// space is open lets the next pushed snapshot make the lens live; enabling while it's
    /// closed shows the honest "needs the immersive space" state; disabling clears it.
    func refreshEnabled() {
        if !isEnabled {
            publishUnavailable(.disabled)
        } else if availability == .unavailable {
            publishUnavailable(.immersiveClosed)
        }
        // Enabled while already live/degraded: leave it — the next snapshot refreshes it.
    }

    // MARK: Coordinator interface

    /// The coordinator calls this (~10 Hz) with a fresh `HandKinematicsSnapshot`. Off ⇒
    /// publish `.unavailable(.disabled)` and emit nothing (privacy-by-default). On ⇒ derive
    /// the arousal reading + features, accrue the per-user resting baseline, publish, and
    /// emit any newly-detected self-touch / gesture events.
    func apply(_ snap: HandKinematicsSnapshot) {
        guard isEnabled else { publishUnavailable(.disabled); return }
        guard !thermalPaused else { return }   // aux sensing paused to shed heat (§8.1)

        meanJointSpeed = snap.meanJointSpeed
        handAperture = snap.handAperture
        selfTouchRate = snap.selfTouchRate
        gestureRate = snap.gestureRate
        tracked = snap.tracked

        // Passive resting-speed baseline: seed to the literature default, then slow-retrack
        // toward observed on tracked frames. Normal use is mostly low-motion, so the median
        // settles near the user's resting floor and brief gestures barely move it.
        if snap.tracked {
            motionSampleCount += 1
            accrueRestingBaseline(snap.meanJointSpeed)
        }
        let restingMedian = hub?.baselines.stat(.hands, Self.energyKey)?.median ?? Self.literatureRestingSpeed
        restingSpeed = restingMedian
        restingLearned = (hub?.baselines.stat(.hands, Self.energyKey)?.mad ?? 0) > 1e-6

        // Availability (three designed states): tracked + dense ⇒ live; else degraded (hands
        // out of frustum / still warming). The coordinator only pushes while running, so
        // `.unavailable` is reached solely via `markUnavailable` / `refreshEnabled` (off /
        // space closed / auth denied / provider unsupported / session error).
        let dense = snap.sampleCount >= Self.liveSampleMin
        let availability: ChannelAvailability = (snap.tracked && dense) ? .live : .degraded

        // Signed motion-energy delta from the user's resting baseline. Upward = arousal.
        let energyDelta = snap.meanJointSpeed - restingMedian
        let magnitude = max(0, min(1, energyDelta / Self.energyDeltaScale))

        // Maturity / confidence — discounted while the baseline is still immature and while
        // degraded (honest immaturity; hands never speak with high confidence anyway).
        let sessionMaturity = min(1, Double(motionSampleCount) / Self.maturityTarget)
        let maturity = max(sessionMaturity, restingLearned ? 0.7 : 0)
        let availFactor = availability == .live ? 1.0 : 0.5
        let restingFactor = restingLearned ? 1.0 : 0.5
        let arousalConfidence = Self.arousalMaxConfidence * maturity * availFactor * restingFactor

        self.availability = availability
        self.unavailableReason = nil
        self.quality = maturity * availFactor

        reading = ChannelReading(
            channel: .hands,
            date: snap.date,
            availability: availability,
            quality: quality,
            valence: nil,                                   // hands NEVER carry valence (§2 master law)
            arousal: Meter(value: magnitude, confidence: arousalConfidence),
            intensity: magnitude,
            features: [
                .gestureEnergy: energyDelta,                // signed m/s Δ from resting (F1 proxy + congruence vote)
                .gestureRate: snap.gestureRate,             // bursts/min → engagement
                .selfTouchRate: snap.selfTouchRate,         // events/min → load (a RATE, never a single touch)
                .handAperture: snap.handAperture ?? 0       // tension FEATURE only — never valence
            ],
            posterior: nil                                  // non-face law
        )

        // Newly-detected events → the bus (always) + a rate-limited insight (never spammy).
        if snap.newSelfTouchEvents > 0 {
            sessionSelfTouchCount += snap.newSelfTouchEvents
            emitEvent(.selfTouch, evidence: [.selfTouchRate],
                      magnitude: min(1, snap.selfTouchRate / Self.selfTouchRateScale),
                      rate: snap.selfTouchRate, confidence: arousalConfidence,
                      at: snap.date, lastInsight: &lastSelfTouchInsight)
        }
        if snap.newGestureBursts > 0 {
            sessionGestureBurstCount += snap.newGestureBursts
            emitEvent(.gestureBurst, evidence: [.gestureEnergy],
                      magnitude: magnitude,
                      rate: snap.gestureRate, confidence: arousalConfidence,
                      at: snap.date, lastInsight: &lastGestureInsight)
        }

        maybeSave(now: snap.date)
    }

    /// The coordinator calls this to flip the channel to an honest typed-`.unavailable` state
    /// (space closed / auth denied / provider unsupported / session error). A disabled lens
    /// always reports `.disabled` regardless of the coordinator's reason.
    func markUnavailable(_ reason: Unavailable) {
        publishUnavailable(isEnabled ? reason : .disabled)
    }

    /// The hub calls this when the thermal governor pauses / resumes aux sensing (US-D13b,
    /// §8.1). While paused, `apply` short-circuits and the lens reads honestly `.degraded`;
    /// on resume, the next pushed snapshot republishes it live.
    func setThermalPaused(_ paused: Bool) {
        guard paused != thermalPaused else { return }
        thermalPaused = paused
        if paused, isEnabled {
            availability = .degraded
            unavailableReason = nil
            quality = 0
            tracked = false
            reading = ChannelReading(channel: .hands, date: Date(), availability: .degraded,
                                     quality: 0, valence: nil, arousal: nil, intensity: 0,
                                     features: [:], posterior: nil)
        }
    }

    // MARK: Events (bus always; insight rate-limited)

    private func emitEvent(_ kind: EventKind, evidence: [SignalRef], magnitude: Double,
                           rate: Double, confidence: Double, at date: Date,
                           lastInsight: inout Date) {
        guard let hub else { return }
        let event = AffectEvent(
            t: date, channel: .hands, kind: kind,
            magnitude: max(0, min(1, magnitude)), confidence: confidence,
            evidence: evidence, baselineDelta: rate
        )
        if date.timeIntervalSince(lastInsight) >= Self.insightGap {
            lastInsight = date
            hub.emitChannelEvent(event)     // bus + narrated insight
        } else {
            hub.emit(event)                 // bus only (the insight is rate-limited)
        }
    }

    // MARK: Reading assembly

    private func publishUnavailable(_ reason: Unavailable) {
        availability = .unavailable
        unavailableReason = reason
        quality = 0
        meanJointSpeed = 0
        handAperture = nil
        selfTouchRate = 0
        gestureRate = 0
        tracked = false
        reading = Self.unavailableReading(at: Date())
    }

    /// A minimal, honest `.unavailable` hands reading (no arousal, no features).
    private static func unavailableReading(at date: Date) -> ChannelReading {
        ChannelReading(
            channel: .hands,
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

    /// Seed-if-absent (to the literature resting default, NOT the first observation, which may
    /// be mid-gesture) then slow-retrack toward observed (mirrors `EyeChannel.observeBaseline`,
    /// with the literature seed instead of the first value).
    private func accrueRestingBaseline(_ speed: Double) {
        guard let hub else { return }
        if hub.baselines.stat(.hands, Self.energyKey) == nil {
            var entry = hub.baselines.channels[.hands] ?? .empty
            entry[Self.energyKey] = RobustStat(median: Self.literatureRestingSpeed, mad: RobustStat.unknownMAD)
            hub.baselines.channels[.hands] = entry
        }
        hub.baselines.retrack(channel: .hands, feature: Self.energyKey, observed: speed, alpha: Self.baselineAlpha)
    }

    private func maybeSave(now: Date) {
        guard now.timeIntervalSince(lastSave) >= Self.saveInterval else { return }
        lastSave = now
        hub?.baselines.save()
    }
}

#endif
