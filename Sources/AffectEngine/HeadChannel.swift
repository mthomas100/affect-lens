//
//  HeadChannel.swift
//  AffectLens
//
//  The HEAD lens (US-D13b, PRD v2 §3.4 / §2.1 head row). A DUAL-SOURCE, `@MainActor
//  @Observable` channel that turns head pose + head motion into a DOMINANCE / APPROACH
//  + AROUSAL reading — NEVER valence (valence is the face's alone, §2 master law).
//
//  TWO SOURCES, ONE core (PRD §3.4 "face-pose windowed; 6DoF immersive"):
//    • WINDOWED — per-frame yaw/roll/pitch already on `FrameAnalysis` (the US-B5a
//      fan-out), from `VNFaceObservation`. Available whenever the face pipeline runs,
//      even in the plain window (no immersive space). ~15 Hz.
//    • IMMERSIVE — the full 6DoF device pose from `ImmersiveSensingCoordinator`'s
//      device-anchor poll (`WorldTrackingProvider.queryDeviceAnchor`), pushed at ~10 Hz
//      while the aura space is open. Higher fidelity than the in-image estimate.
//  SOURCE SELECTION: immersive is PREFERRED while a fresh 6DoF pose is arriving; the
//  windowed source is the fallback (and the only source in the plain window). Exactly
//  ONE source drives the pure core per moment, so the angular-motion window is never
//  fed two differently-noised streams at once.
//
//  UNITS / CONVENTION (documented, verified against the face pipeline). All angles are
//  radians. Both sources are mapped to ONE convention so a per-user delta is comparable
//  regardless of which is live:
//    • pitch: + = head BACK / chin up (looking up), − = head DOWN (chin toward chest).
//      This matches Vision's `VNFaceObservation.pitch` as the face pipeline already
//      reads it — `PitchCorrection.defaultDownSign == -1` (`ActionUnits.swift`), i.e.
//      head-down is a NEGATIVE pitch. The immersive extractor maps the device anchor to
//      the same sign (see `HeadPoseMath.pose(fromDeviceColumns:)`).
//    • yaw: signed head turn; only |Δyaw| ("turned away from your neutral facing") is used.
//    • roll: signed lateral tilt — the MOST over-claimed cue (Otta 1994; Torrance 2020),
//      sign-unstable, so it is a LOW-CONFIDENCE dimensional feature only, NO dictionary.
//
//  Honesty law (PRD §3.4 caveats — never soften). We read HEAD ORIENTATION, not gaze,
//  and not the torso — so the two innate displays (Tracy & Matsumoto 2008: head-back +
//  expanded → high-dominance/expansion; head-down + turned-away → withdrawal/submission)
//  surface only as a hedged `dominanceLean`, and the felt words "pride"/"shame" appear
//  ONLY as hedged glosses inside the copy. Pitch is GAZE-GATED and NON-MONOTONIC
//  (Witkower & Tracy 2019/2020): head-down with DIRECT gaze is concentration, not
//  withdrawal — and we cannot see gaze, so `dominanceLean`'s confidence is ALWAYS capped
//  low and the formula requires BOTH head-down AND turned-away before it reads withdrawal
//  (a straight look-down at content stays near neutral). NO nod/shake meanings (culture-
//  coded, refused list §5). Everything off-by-default except face: gated on
//  `lens.head.enabled` (default FALSE).
//

#if os(visionOS) || os(macOS)

import Foundation

// MARK: - HeadPose (the source-agnostic pose unit)

/// One head pose at an instant, in the documented radian convention (see the file
/// header). Source-agnostic: the windowed and immersive sources both produce this, so
/// the pure math never knows which sensor it came from.
nonisolated struct HeadPose: Sendable, Equatable {
    /// + = head back / chin up (looking up); − = head down.
    var pitch: Double
    /// Signed head turn (only |Δyaw| from neutral is used downstream).
    var yaw: Double
    /// Signed lateral tilt — LOW-CONFIDENCE only (no dictionary).
    var roll: Double
}

/// Which sensor produced the pose currently driving the reading.
nonisolated enum HeadPoseSource: String, Sendable, Equatable {
    /// The immersive device anchor (`WorldTrackingProvider`, 6DoF) — higher fidelity.
    case immersive6DoF
    /// The windowed in-image estimate (`VNFaceObservation`) — the plain-window fallback.
    case windowed
}

// MARK: - HeadPoseMath (the pure, testable core)

/// The head-pose math (US-D13b, PRD v2 §3.4). A `nonisolated` value type — pure and
/// self-testable off the main actor (the `HeadChannel` @Observable class wraps it), per
/// the project's MainActor-default regime. It accumulates a GAP-AWARE angular-motion
/// window (mirroring `HandKinematics`' philosophy for angular velocity) and exposes the
/// static delta / dominance-lean math the channel and the self-tests call directly.
///
/// It does NOT hold the per-user neutral pose or the resting-motion baseline — those
/// live in the shared `BaselineStore` (`.head` entry) and the `HeadChannel` measures the
/// deltas against them, exactly as `HandsChannel` measures hand-energy deltas against
/// its `.hands` baseline.
nonisolated struct HeadPoseMath {

    // MARK: Configuration (documented constants)

    /// GAP GUARD (the `HandKinematics.maxSampleDt` idiom for angular velocity). Angular
    /// speed is computed only between CONSECUTIVE poses whose Δt ≤ this; a larger gap (a
    /// tracking hole, a source switch, a look-away that drops the windowed pose) is
    /// SKIPPED — it contributes no motion energy rather than dividing a possibly-large
    /// angular jump by an unreliable Δt and spiking. 0.35 s ≈ 3.5× the ~100 ms immersive
    /// poll and ~5× the ~66 ms windowed cadence, so genuine consecutive samples always
    /// pass and only real holes drop.
    var maxSampleDt: TimeInterval = 0.35
    /// Rolling window for the mean angular speed (motion energy). ~2 s smooths per-sample
    /// jitter into a stable arousal level while still tracking a turn/nod onset.
    var motionWindow: TimeInterval = 2.0
    /// Hard cap on retained angular-speed samples (bounded memory regardless of session).
    var maxMotionSamples = 300
    /// A pose within this of `now` counts as "tracked right now" (else the head pose is
    /// stale — no fresh source — and the channel reads `.degraded`).
    var recency: TimeInterval = 0.5

    // MARK: State

    private struct MotionSample { var date: Date; var speed: Double }
    private var motionSamples: [MotionSample] = []
    /// The last pose fed in, for the gap-aware consecutive-pair angular velocity.
    private var lastPose: HeadPose?
    private var lastPoseDate: Date?

    private(set) var latestPose: HeadPose?
    private(set) var latestSource: HeadPoseSource?
    private(set) var lastTrackedDate: Date?
    private(set) var ingestCount = 0

    init() {}

    // MARK: Ingest one pose

    /// Fold one pose (from either source) into the angular-motion window. Gap-aware:
    /// an over-`maxSampleDt` interval contributes no motion sample (never a spike).
    mutating func ingest(_ pose: HeadPose, at date: Date, source: HeadPoseSource) {
        ingestCount += 1
        prune(now: date)

        if let prev = lastPose, let prevDate = lastPoseDate {
            let dt = date.timeIntervalSince(prevDate)
            if dt > 0, dt <= maxSampleDt {
                let speed = Self.angularSpeed(prev, pose, dt: dt)
                motionSamples.append(MotionSample(date: date, speed: speed))
                if motionSamples.count > maxMotionSamples {
                    motionSamples.removeFirst(motionSamples.count - maxMotionSamples)
                }
            }
            // dt > maxSampleDt ⇒ a gap: SKIP (no motion sample, no spike).
        }
        lastPose = pose
        lastPoseDate = date
        latestPose = pose
        latestSource = source
        lastTrackedDate = date
    }

    // MARK: Rolling reads (all take `now`, so they age between samples)

    /// Mean angular speed (rad/s) over the trailing `motionWindow` — the motion energy.
    /// 0 when no samples are in the window (head still, or no fresh pose).
    func angularMotionEnergy(now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-motionWindow)
        let xs = motionSamples.filter { $0.date >= cutoff && $0.date <= now }.map(\.speed)
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Angular-speed samples in the trailing window (density → the channel's maturity).
    func sampleCount(now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-motionWindow)
        return motionSamples.filter { $0.date >= cutoff && $0.date <= now }.count
    }

    /// A pose arrived within `recency` of `now`.
    func tracked(now: Date) -> Bool {
        lastTrackedDate.map { now.timeIntervalSince($0) <= recency } ?? false
    }

    /// Drop the gap-aware "last pose" so the next ingest starts a fresh pair (used on a
    /// source switch, so the first cross-source pair is gap-guarded, never a jump-spike).
    mutating func breakContinuity() {
        lastPose = nil
        lastPoseDate = nil
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-motionWindow)
        motionSamples.removeAll { $0.date < cutoff }
    }

    // MARK: Pure geometry (static → directly unit-tested)

    /// Combined angular speed between two poses (rad/s) = the Euclidean norm of the
    /// per-component angular deltas over Δt. A simple, cheap, monotone motion-energy
    /// proxy (NOT a geodesic on SO(3) — head Euler ranges are small enough that the
    /// approximation is fine for a rolling ENERGY, and it costs one sqrt). Yaw/roll
    /// deltas are angle-wrapped so a ±π wraparound never fakes a huge speed.
    static func angularSpeed(_ a: HeadPose, _ b: HeadPose, dt: TimeInterval) -> Double {
        guard dt > 0 else { return 0 }
        let dp = b.pitch - a.pitch
        let dy = wrap(b.yaw - a.yaw)
        let dr = wrap(b.roll - a.roll)
        return (dp * dp + dy * dy + dr * dr).squareRoot() / dt
    }

    /// Signed component-wise delta of `pose` from the per-user `neutral`, with yaw & roll
    /// angle-wrapped to [−π, π].
    static func delta(_ pose: HeadPose, from neutral: HeadPose) -> HeadPose {
        HeadPose(pitch: pose.pitch - neutral.pitch,
                 yaw: wrap(pose.yaw - neutral.yaw),
                 roll: wrap(pose.roll - neutral.roll))
    }

    /// THE dominance-lean formula (PRD v2 §3.4 — the two innate displays, gaze-gated).
    /// Maps a signed head-pose delta to `[−1, 1]`:
    ///   • POSITIVE = head-BACK + LEVEL ("expansion" / high-dominance display) —
    ///     driven by an up-pitch delta AND facing forward (turning away REDUCES it);
    ///   • NEGATIVE = head-DOWN + TURNED-AWAY ("withdrawal" / submission) — requires
    ///     BOTH a down-pitch delta AND a turn away from neutral.
    ///
    /// THE GAZE-GATE HEDGE (Witkower & Tracy — pitch is gaze-gated and non-monotonic, and
    /// we cannot see gaze): the withdrawal pole is `max(0, −pitch) × away`, a PRODUCT of
    /// both cues, so a straight look-DOWN at content (yaw ≈ neutral ⇒ `away` ≈ 0) yields
    /// ~0, i.e. NEUTRAL — NOT full withdrawal. Only head-down *combined with* turning
    /// away reads as withdrawal. The result feeds a FEATURE whose confidence contribution
    /// is always capped low (see `HeadChannel.dominanceConfidenceCeiling`).
    ///
    /// - Parameters:
    ///   - pitchDelta: signed pitch delta from neutral (rad; + up / − down).
    ///   - yawDelta: signed yaw delta from neutral (rad); only its magnitude is used.
    static func dominanceLean(pitchDelta: Double, yawDelta: Double,
                              pitchScale: Double, yawScale: Double) -> Double {
        let pitchTerm = clamp(pitchDelta / pitchScale, -1, 1)          // + up … − down
        let awayFrac = clamp(abs(yawDelta) / yawScale, 0, 1)           // 0 facing … 1 turned
        // Expansion needs head-back AND facing forward; turning away discounts it.
        let expansion = max(0, pitchTerm) * (1 - awayFrac)
        // Withdrawal needs head-DOWN AND turned-away (the product = the gaze-gate hedge).
        let withdrawal = max(0, -pitchTerm) * awayFrac
        return clamp(expansion - withdrawal, -1, 1)
    }

    /// Map a 4×4 device-anchor transform's rotation columns → a `HeadPose` in the file's
    /// convention. Passed as three world-space basis vectors so this stays ARKit-free and
    /// unit-testable (the coordinator supplies the columns of `originFromAnchorTransform`):
    ///   • `xAxis` = device local +X (right), `yAxis` = +Y (up), `zAxis` = +Z (backward).
    /// The device looks along −Z, so `forward = −zAxis`.
    ///   • pitch = asin(forward.y): + when the forward ray tilts UP (head back) — matches
    ///     the windowed sign convention.
    ///   • yaw = atan2(forward.x, −forward.z): signed heading (only Δ-from-neutral is used).
    ///   • roll = atan2(−xAxis.y, yAxis.y): 0 upright; grows as the head tilts laterally.
    ///     LOW-CONFIDENCE (gimbal-degenerate near straight up/down) — used dimensionally
    ///     only, never a dictionary.
    static func pose(fromDeviceColumns xAxis: SIMD3<Double>,
                     _ yAxis: SIMD3<Double>,
                     _ zAxis: SIMD3<Double>) -> HeadPose {
        let forward = SIMD3<Double>(-zAxis.x, -zAxis.y, -zAxis.z)
        let pitch = asin(clamp(forward.y, -1, 1))
        let yaw = atan2(forward.x, -forward.z)
        let roll = atan2(-xAxis.y, yAxis.y)
        return HeadPose(pitch: pitch, yaw: yaw, roll: roll)
    }

    // MARK: Small helpers

    /// Wrap an angle delta into [−π, π] so a wraparound never fakes a huge move.
    static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x < -.pi { x += 2 * .pi }
        return x
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
}

// MARK: - HeadChannel (the @Observable lens)

/// The head affect lens. `@MainActor @Observable` to match the other channel objects and
/// so the head lens view + K3 HUD observe it directly. It wraps the pure `HeadPoseMath`,
/// selects the active source (immersive-preferred, windowed fallback), layers on per-user
/// baselining (the shared `BaselineStore` `.head` entry), availability / quality, and the
/// honesty-bounded (dominance/approach + arousal, NEVER valence) `ChannelReading`.
@MainActor
@Observable
final class HeadChannel: AffectChannel {

    // MARK: Enablement (off by default — PRD law)

    /// `UserDefaults` key backing `isEnabled` (default FALSE; every lens but face is opt-in).
    static let enabledKey = "lens.head.enabled"
    /// Stable id for the hub's analysis-consumer registry (the windowed source).
    static let consumerID = "head"

    /// Whether the lens is switched on. Reads the flag directly so it always agrees with
    /// the `@AppStorage` toggle in the UI.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // MARK: Typed unavailable reasons (surfaced on the lens)

    /// Why the head channel isn't producing a reading right now — richer than a bool so
    /// the lens speaks honestly (never a faked value).
    nonisolated enum Unavailable: Equatable, Sendable {
        /// The head lens is switched off.
        case disabled
        /// Enabled, but no usable head pose yet (no face in the window, immersive closed).
        case noPose
        /// Aux sensing paused to shed heat (the thermal governor, §8.1) — honest + typed.
        case thermal
    }

    // MARK: BaselineStore feature keys (the .head entry)

    /// The per-user NEUTRAL head pose lives under `.head` / headPitch|headYaw|headRoll
    /// (robust medians, slow-retracked during verified stillness). The published
    /// headPitch/Yaw/Roll FEATURES are DELTAS from these.
    private static let neutralPitchKey = FeatureKey.headPitch.rawValue
    private static let neutralYawKey = FeatureKey.headYaw.rawValue
    private static let neutralRollKey = FeatureKey.headRoll.rawValue
    /// The per-user resting head-motion energy lives under `.head` / headMotionEnergy.
    private static let energyKey = FeatureKey.headMotionEnergy.rawValue

    // MARK: Tunables (documented; PROVISIONAL until on-device K3 tuning)

    /// Literature-default resting head angular speed (rad/s) used to SEED the per-user
    /// motion baseline until it matures — a resting head sits near-still (tracking jitter
    /// ~0.02–0.1 rad/s), so this small seed plus a slow retrack toward the user's actual
    /// resting floor is honest.
    static let literatureRestingEnergy: Double = 0.05
    /// |angular-motion-energy Δ| (rad/s) above resting that maps to a full-magnitude (±1)
    /// arousal read. A brisk head turn/nod reaches past this; provisional until K3.
    static let energyDeltaScale: Double = 1.0
    /// pitch Δ (rad, ~20°) that saturates the dominance-lean pitch term.
    static let dominancePitchScale: Double = 0.35
    /// |yaw Δ| (rad, ~34°) that saturates the dominance-lean "turned away" term.
    static let dominanceYawScale: Double = 0.6
    /// Deliberately modest confidence ceiling for the head arousal meter — head-motion
    /// affect is a coarse arousal proxy, so it never speaks with high confidence.
    static let arousalMaxConfidence: Double = 0.45
    /// The ALWAYS-LOW ceiling on the dominance-lean's confidence (the Witkower gaze-gate
    /// caveat — head orientation is not gaze, so this cue stays low-confidence forever).
    static let dominanceConfidenceCeiling: Double = 0.3
    /// Angular motion below this (rad/s) counts as "head roughly still" — only then does
    /// the NEUTRAL pose slow-retrack (so a sustained turn never corrupts your neutral).
    static let stillnessThreshold: Double = 0.15
    /// Angular-speed samples in the window for a dense `.live` (vs `.degraded`-sparse) read.
    static let liveSampleMin = 6
    /// Prefer the immersive 6DoF source while one arrived within this of now; otherwise
    /// fall back to the windowed source (or degrade if neither is fresh).
    static let immersiveRecency: TimeInterval = 0.5
    /// Slow EMA for learning the per-user resting-energy + neutral-pose baselines.
    private static let baselineAlpha: Double = 0.02
    /// Tracked samples for the session maturity to read fully "mature".
    static let maturityTarget: Double = 120
    /// Persist the shared baselines at most this often (avoid UserDefaults thrash).
    private static let saveInterval: TimeInterval = 15

    // MARK: Wiring

    /// The hub owns this channel (`let head`); the weak back-reference gives access to the
    /// shared `BaselineStore` (per-user baselining + persistence) and the event bus.
    @ObservationIgnored
    private weak var hub: AffectHub?

    /// The pure math core (observation-ignored — it mutates every sample; the UI observes
    /// the derived scalars below, not the struct).
    @ObservationIgnored
    private var math = HeadPoseMath()

    // MARK: Published state

    /// The channel-generic reading (published to fusion + congruence + the HUD). Starts unavailable.
    private(set) var reading: ChannelReading

    // Convenience observable scalars for the lens UI + K3 HUD.
    private(set) var availability: ChannelAvailability = .unavailable
    /// The typed reason while `.unavailable`; `nil` while `.live` / `.degraded`.
    private(set) var unavailableReason: Unavailable? = .disabled
    private(set) var quality: Double = 0
    /// The live pose in the file's convention (nil until a source produces one).
    private(set) var pose: HeadPose?
    /// Which source is currently driving the reading (nil while unavailable).
    private(set) var activeSource: HeadPoseSource?
    /// Signed deltas from the per-user neutral pose (rad), for the FEATURES strata.
    private(set) var pitchDelta: Double = 0
    private(set) var yawDelta: Double = 0
    private(set) var rollDelta: Double = 0
    private(set) var motionEnergy: Double = 0
    private(set) var restingEnergy: Double = HeadChannel.literatureRestingEnergy
    private(set) var restingLearned = false
    private(set) var neutralLearned = false
    /// The hedged dominance-lean ∈ [−1, 1] (+ expansion / − withdrawal). Always low-confidence.
    private(set) var dominanceLean: Double = 0
    private(set) var tracked = false
    /// True while aux sensing is paused by the thermal governor.
    private(set) var thermalPaused = false

    // MARK: Transient bookkeeping (observation-ignored)

    @ObservationIgnored private var motionSampleCount = 0
    @ObservationIgnored private var lastImmersiveDate: Date?
    /// Seeded to construction time (app launch) — NOT `.distantPast` — so the save throttle
    /// applies from the first pose (the `InteractionChannel` guard): in the app the first
    /// real save lands within `saveInterval` of live data; in the DEBUG self-tests
    /// (synthetic past timestamps) it means a throwaway hub NEVER persists synthetic
    /// baselines — including a mid-gesture "neutral pose" — into the real per-user store.
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var lastActiveSource: HeadPoseSource?

    // MARK: AffectChannel

    var id: Channel { .head }

    /// The most recent reading, in the channel-generic form fusion consumes. Short-circuits
    /// to `.unavailable` while the lens is off.
    var latest: ChannelReading {
        isEnabled ? reading : Self.unavailableReading(at: reading.date)
    }

    /// The SIGNED, [−1, 1]-normalized motion-energy arousal delta for CROSS-channel
    /// consensus (US-C10a, PRD v2 §4.4). Positive = moving MORE than your resting head,
    /// negative = calmer; magnitude is |Δ| squashed by the SAME `energyDeltaScale` the
    /// published arousal `Meter` uses. `nil` when there's no usable arousal read (off /
    /// warming / unavailable), so it doesn't vote. The published arousal `Meter` value
    /// stays magnitude-only (max(0, ·)); the sign is honest only in cross-channel consensus.
    var signedArousalDelta: Double? {
        guard isEnabled, reading.availability != .unavailable,
              let raw = reading.features[.headMotionEnergy] else { return nil }
        return max(-1, min(1, raw / Self.energyDeltaScale))
    }

    /// Drop transient per-channel state WITHOUT touching persisted calibration.
    func reset() {
        math = HeadPoseMath()
        motionSampleCount = 0
        lastImmersiveDate = nil
        lastActiveSource = nil
        publishUnavailable(isEnabled ? .noPose : .disabled)
    }

    // MARK: Init / hub wiring

    init() {
        reading = Self.unavailableReading(at: Date())
    }

    /// Called once by `AffectHub.init` after all hub properties exist. Wires the
    /// back-reference and seeds the resting-energy + neutral-pose references from any
    /// persisted per-user baseline.
    func connect(hub: AffectHub) {
        self.hub = hub
        if let s = hub.baselines.stat(.head, Self.energyKey) {
            restingEnergy = s.median
            restingLearned = s.mad > 1e-6
        }
        neutralLearned = (hub.baselines.stat(.head, Self.neutralPitchKey)?.mad ?? 0) > 1e-6
        publishUnavailable(isEnabled ? .noPose : .disabled)
    }

    /// Prepare for a fresh activation (the hub calls this before registering the windowed
    /// consumer): clear transient state so turning the lens on starts clean.
    func prepareForActivation() {
        math = HeadPoseMath()
        motionSampleCount = 0
        lastImmersiveDate = nil
        lastActiveSource = nil
    }

    /// The hub calls this when the lens is switched off (its windowed consumer is also
    /// removed, so no more fan-out frames arrive).
    func deactivate() {
        publishUnavailable(.disabled)
    }

    /// The UI toggle calls this after flipping `enabledKey`; re-registers (or unregisters)
    /// the windowed source on the hub's fan-out.
    func refreshEnabled() {
        hub?.refreshRegistration()
    }

    // MARK: Thermal governor gate (US-D13b, §8.1)

    /// The hub calls this when the thermal governor pauses / resumes aux sensing. While
    /// paused the channel publishes an honest `.unavailable(.thermal)` reading and its
    /// ingest paths short-circuit; on resume, the next pose republishes it live.
    func setThermalPaused(_ paused: Bool) {
        guard paused != thermalPaused else { return }
        thermalPaused = paused
        if paused {
            publishUnavailable(isEnabled ? .thermal : .disabled)
        } else if isEnabled {
            publishUnavailable(.noPose)   // honest until the next pose arrives
        }
    }

    // MARK: Windowed source (the fan-out consumer)

    /// Consume one processed `FrameAnalysis` from the hub's fan-out (the WINDOWED source).
    /// Ignored while the immersive 6DoF source is fresh (it is preferred). A usable pose
    /// needs pitch AND yaw (roll defaults to 0 — it is low-confidence anyway).
    func ingest(_ analysis: FrameAnalysis) {
        guard isEnabled, !thermalPaused else { return }
        // Immersive is preferred while fresh — drop the windowed frame for pose purposes.
        if let last = lastImmersiveDate, analysis.date.timeIntervalSince(last) < Self.immersiveRecency {
            return
        }
        guard analysis.facePresent, let pitch = analysis.pitch, let yaw = analysis.yaw else {
            // Enabled but no usable pose this frame — degrade (widen uncertainty, never drop).
            markDegradedNoPose(at: analysis.date)
            return
        }
        let pose = HeadPose(pitch: pitch, yaw: yaw, roll: analysis.roll ?? 0)
        apply(pose, at: analysis.date, source: .windowed)
    }

    // MARK: Immersive source (pushed by the coordinator's device-anchor poll)

    /// The `ImmersiveSensingCoordinator` calls this (~10 Hz while the aura space is open)
    /// with the full 6DoF device pose (the PREFERRED source). Marks immersive fresh so the
    /// windowed source steps aside, then folds the pose in.
    func applyImmersive(pose: HeadPose, at date: Date) {
        guard isEnabled, !thermalPaused else { return }
        lastImmersiveDate = date
        apply(pose, at: date, source: .immersive6DoF)
    }

    /// The coordinator calls this when the immersive space closes: the 6DoF source is gone,
    /// so the windowed source (if a face is in the window) takes back over on its next
    /// frame. Clears the immersive-fresh marker; never flips the lens off (windowed still works).
    func immersiveSourceEnded() {
        lastImmersiveDate = nil
        math.breakContinuity()
    }

    // MARK: Core apply (shared by both sources)

    private func apply(_ pose: HeadPose, at date: Date, source: HeadPoseSource) {
        // A source switch breaks the gap-aware pair so the first cross-source interval is
        // gap-guarded rather than read as one big angular jump.
        if let last = lastActiveSource, last != source { math.breakContinuity() }
        lastActiveSource = source

        math.ingest(pose, at: date, source: source)
        motionSampleCount += 1

        let energy = math.angularMotionEnergy(now: date)
        motionEnergy = energy

        // NEUTRAL pose baseline: seed-if-absent to the FIRST observed pose (a reasonable
        // neutral — the user typically faces forward when a source starts), then slow-
        // retrack toward observed ONLY while the head is roughly still (verified stillness),
        // so a sustained turn/nod never drags your neutral. (The `EyeChannel.observeBaseline`
        // seed-then-retrack idiom, gated on stillness the way blink gates on clearly-open.)
        seedNeutralIfAbsent(pose)
        if energy < Self.stillnessThreshold {
            retrackNeutral(pose)
        }
        // RESTING-energy baseline: seed to the literature default, slow-retrack toward
        // observed each tracked frame (normal use is mostly low-motion, so the median
        // settles near your resting floor).
        accrueRestingEnergy(energy)

        // Read the freshest baselines back.
        let neutral = neutralPose()
        restingEnergy = hub?.baselines.stat(.head, Self.energyKey)?.median ?? Self.literatureRestingEnergy
        restingLearned = (hub?.baselines.stat(.head, Self.energyKey)?.mad ?? 0) > 1e-6
        neutralLearned = (hub?.baselines.stat(.head, Self.neutralPitchKey)?.mad ?? 0) > 1e-6

        // Signed pose deltas from neutral.
        let d = HeadPoseMath.delta(pose, from: neutral)
        pitchDelta = d.pitch
        yawDelta = d.yaw
        rollDelta = d.roll

        // The hedged dominance-lean (BOTH pitch and yaw-away → the gaze-gate hedge).
        dominanceLean = HeadPoseMath.dominanceLean(
            pitchDelta: d.pitch, yawDelta: d.yaw,
            pitchScale: Self.dominancePitchScale, yawScale: Self.dominanceYawScale)

        self.pose = pose
        self.activeSource = source

        // Availability: dense + fresh ⇒ live; else degraded (sparse / warming).
        let dense = math.sampleCount(now: date) >= Self.liveSampleMin
        let live = math.tracked(now: date) && dense
        let availability: ChannelAvailability = live ? .live : .degraded
        self.tracked = math.tracked(now: date)

        // Signed motion-energy delta from resting. Upward = arousal.
        let energyDelta = energy - restingEnergy
        let magnitude = max(0, min(1, energyDelta / Self.energyDeltaScale))

        // Maturity / confidence — discounted while the baseline is immature and while
        // degraded (honest immaturity; head never speaks with high confidence anyway).
        let sessionMaturity = min(1, Double(motionSampleCount) / Self.maturityTarget)
        let maturity = max(sessionMaturity, restingLearned ? 0.7 : 0)
        let availFactor = availability == .live ? 1.0 : 0.5
        let restingFactor = restingLearned ? 1.0 : 0.5
        let arousalConfidence = Self.arousalMaxConfidence * maturity * availFactor * restingFactor

        self.availability = availability
        self.unavailableReason = nil
        self.quality = maturity * availFactor

        reading = ChannelReading(
            channel: .head,
            date: date,
            availability: availability,
            quality: quality,
            valence: nil,                                   // head NEVER carries valence (§2 master law)
            arousal: Meter(value: magnitude, confidence: arousalConfidence),
            intensity: magnitude,
            features: [
                .headMotionEnergy: energyDelta,             // signed rad/s Δ (F1 proxy + congruence vote)
                .headPitch: d.pitch,                        // signed Δ from neutral (rad)
                .headYaw: d.yaw,
                .headRoll: d.roll,                          // LOW-CONFIDENCE (no dictionary)
                .dominanceLean: dominanceLean               // hedged [−1,1]; confidence capped low
            ],
            posterior: nil                                  // non-face law
        )

        maybeSave(now: date)
    }

    // MARK: Reading assembly (off states)

    /// Enabled but no usable pose this frame (face turned away in the window, immersive
    /// closed) — a designed `.degraded` state, never a fabricated pose.
    private func markDegradedNoPose(at date: Date) {
        tracked = false
        availability = .degraded
        unavailableReason = nil
        quality = 0
        reading = ChannelReading(
            channel: .head, date: date, availability: .degraded, quality: 0,
            valence: nil, arousal: nil, intensity: 0, features: [:], posterior: nil)
    }

    private func publishUnavailable(_ reason: Unavailable) {
        availability = .unavailable
        unavailableReason = reason
        quality = 0
        pose = nil
        activeSource = nil
        tracked = false
        motionEnergy = 0
        dominanceLean = 0
        pitchDelta = 0; yawDelta = 0; rollDelta = 0
        reading = Self.unavailableReading(at: Date())
    }

    /// A minimal, honest `.unavailable` head reading (no arousal, no features).
    private static func unavailableReading(at date: Date) -> ChannelReading {
        ChannelReading(
            channel: .head,
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

    /// The current per-user neutral pose (persisted medians), or a level zero pose until seeded.
    private func neutralPose() -> HeadPose {
        HeadPose(pitch: hub?.baselines.stat(.head, Self.neutralPitchKey)?.median ?? 0,
                 yaw: hub?.baselines.stat(.head, Self.neutralYawKey)?.median ?? 0,
                 roll: hub?.baselines.stat(.head, Self.neutralRollKey)?.median ?? 0)
    }

    /// Seed the neutral-pose baseline to the first observed pose if absent (mirrors
    /// `EyeChannel`'s first-observation seeding — the first pose is a reasonable neutral).
    private func seedNeutralIfAbsent(_ pose: HeadPose) {
        guard let hub else { return }
        guard hub.baselines.stat(.head, Self.neutralPitchKey) == nil else { return }
        var entry = hub.baselines.channels[.head] ?? .empty
        entry[Self.neutralPitchKey] = RobustStat(median: pose.pitch, mad: RobustStat.unknownMAD)
        entry[Self.neutralYawKey] = RobustStat(median: pose.yaw, mad: RobustStat.unknownMAD)
        entry[Self.neutralRollKey] = RobustStat(median: pose.roll, mad: RobustStat.unknownMAD)
        hub.baselines.channels[.head] = entry
    }

    /// Slow-retrack the neutral-pose medians toward the observed pose (only called while
    /// the head is roughly still — see `stillnessThreshold`).
    private func retrackNeutral(_ pose: HeadPose) {
        guard let hub else { return }
        hub.baselines.retrack(channel: .head, feature: Self.neutralPitchKey, observed: pose.pitch, alpha: Self.baselineAlpha)
        hub.baselines.retrack(channel: .head, feature: Self.neutralYawKey, observed: pose.yaw, alpha: Self.baselineAlpha)
        hub.baselines.retrack(channel: .head, feature: Self.neutralRollKey, observed: pose.roll, alpha: Self.baselineAlpha)
    }

    /// Seed-if-absent (to the literature resting default, NOT the first observation, which
    /// may be mid-turn) then slow-retrack toward observed (mirrors `HandsChannel`).
    private func accrueRestingEnergy(_ energy: Double) {
        guard let hub else { return }
        if hub.baselines.stat(.head, Self.energyKey) == nil {
            var entry = hub.baselines.channels[.head] ?? .empty
            entry[Self.energyKey] = RobustStat(median: Self.literatureRestingEnergy, mad: RobustStat.unknownMAD)
            hub.baselines.channels[.head] = entry
        }
        hub.baselines.retrack(channel: .head, feature: Self.energyKey, observed: energy, alpha: Self.baselineAlpha)
    }

    private func maybeSave(now: Date) {
        guard now.timeIntervalSince(lastSave) >= Self.saveInterval else { return }
        lastSave = now
        hub?.baselines.save()
    }
}

#endif
