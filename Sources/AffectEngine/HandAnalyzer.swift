//
//  HandAnalyzer.swift
//  AffectLens
//
//  The HANDS channel's off-main core (US-D13a, PRD v2 §3.3 / §2.1 hands row). Two
//  types, both ARKit-FREE so they compile + unit-test without a device or the
//  simulator's (absent) hand-tracking providers:
//
//    • `nonisolated struct HandKinematics` — the PURE, testable math. Given per-hand
//      joint positions (world-space) + timestamps (+ an optional head position) it
//      derives the window features the hands lens owns (PRD §2 master law: hands own
//      AROUSAL / agitation / load — NEVER valence):
//        – mean joint SPEED over a window = motion ENERGY → arousal, with GAP-AWARE
//          velocity (a tracking hole must NOT spike speed);
//        – hand APERTURE (thumb-tip↔index-tip, normalized by a hand-scale reference) —
//          a tension FEATURE only, never valence;
//        – SELF-TOUCH detection (min any-joint↔head distance, with dwell + refractory)
//          → an EVENT, whose rolling rate is `selfTouchRate` (read as a RATE, never a
//          single touch — Grunwald 2014 / Mohiyeddini & Semple 2013);
//        – GESTURE-burst detection (a motion spike over a threshold) → a rate =
//          engagement.
//    • `actor HandAnalyzer` — ingests the 90–120 Hz anchor samples off-main and hands
//      the channel throttled (~10 Hz) `HandKinematicsSnapshot`s.
//
//  Chua et al. 2024 (Motion-as-Emotion, N=22): hand-only affect classified 50–87 %
//  WITHIN-user but collapsed to chance leave-one-user-out — the empirical proof that
//  per-user baselining is mandatory and hand motion carries no population label. So this
//  core reports RAW deltas/rates; the `HandsChannel` measures them against the user's own
//  `BaselineStore` resting hand baseline and gates confidence on its maturity. There is
//  NO gesture dictionary anywhere: a "gesture burst" is a motion-energy spike, never a
//  named pose (refused list §4.5 #10).
//

#if os(visionOS) || os(macOS)

import Foundation

// MARK: - Sample model (ARKit-free — the coordinator maps HandAnchor → this)

/// Which hand a sample is from. Our own enum so the pure core never imports ARKit
/// (the coordinator maps `HandAnchor.Chirality` → this).
nonisolated enum HandSide: Sendable, Hashable { case left, right }

/// The small set of joints the kinematics needs — fingertips + wrist for motion &
/// self-touch coverage, plus the middle-finger knuckle as the hand-scale reference.
/// A compact set (7 joints) keeps the per-sample math cheap at 90–120 Hz.
nonisolated enum HandJoint: Int, CaseIterable, Sendable {
    case wrist
    case thumbTip
    case indexTip
    case middleTip
    case ringTip
    case littleTip
    /// Metacarpophalangeal ("knuckle") of the middle finger — paired with the wrist as
    /// the per-hand length scale that normalizes the aperture (scale-invariant across
    /// hand sizes).
    case middleKnuckle
}

/// One hand's joints in WORLD space at an instant — the ARKit-free unit the analyzer
/// consumes. Positions are metres. `isTracked` false ⇒ the anchor was present but the
/// hand isn't currently tracked (out of frustum): the sample ages the windows without
/// contributing motion (never a fabricated velocity).
nonisolated struct HandJointsSample: Sendable {
    var side: HandSide
    var date: Date
    var positions: [HandJoint: SIMD3<Double>]
    var isTracked: Bool
}

// MARK: - Snapshot (the throttled, Sendable read the channel consumes)

/// A throttled (~10 Hz) snapshot of the kinematics for the `HandsChannel`. `nonisolated`
/// Sendable so it crosses the actor → MainActor hop cleanly. `newSelfTouchEvents` /
/// `newGestureBursts` are the counts SINCE the previous `snapshot()` — so the channel
/// emits exactly the newly-detected events (bounded by the dwell/refractory) without the
/// actor and channel sharing mutable state.
nonisolated struct HandKinematicsSnapshot: Sendable {
    var date: Date
    /// Any sample ever ingested (vs a fresh, never-run analyzer).
    var hasData: Bool
    /// A tracked hand sample arrived within the recency window (vs out-of-frustum).
    var tracked: Bool
    /// Mean joint speed over the window (m/s) = motion energy → arousal.
    var meanJointSpeed: Double
    /// Thumb-tip↔index-tip distance / hand-scale reference; `nil` when not computable.
    var handAperture: Double?
    /// Self-touch events per minute over the rolling window.
    var selfTouchRate: Double
    /// Gesture-burst events per minute over the rolling window.
    var gestureRate: Double
    /// New self-touch events detected since the previous snapshot.
    var newSelfTouchEvents: Int
    /// New gesture bursts detected since the previous snapshot.
    var newGestureBursts: Int
    /// Velocity samples in the window (density → the channel's quality/maturity).
    var sampleCount: Int
    /// A head position is known (so self-touch is computable).
    var headSeen: Bool
    /// Total anchor samples ingested (the K1 HUD derives the hands update Hz from deltas).
    var ingestCount: Int
}

// MARK: - HandKinematics (the pure, testable core)

/// The hand-kinematics math (US-D13a, PRD v2 §3.3). A `nonisolated` value type — pure and
/// self-testable off the main actor (the `HandAnalyzer` actor and `HandsChannel` wrap it),
/// per the project's MainActor-default regime. All reads take an explicit `now` so the
/// windows age correctly BETWEEN samples (a hand out of frustum stops delivering samples).
nonisolated struct HandKinematics {

    // MARK: Configuration (documented constants)

    /// GAP GUARD. Velocity is computed only between CONSECUTIVE tracked samples of the
    /// SAME hand whose Δt ≤ this. A tracking hole yields a large-Δt pair (or a large
    /// position jump when tracking resumes); dividing that by the true Δt is unreliable
    /// and, if the app mis-stamps time, spikes — so an over-`maxSampleDt` interval is
    /// SKIPPED entirely (it contributes no motion energy) rather than fabricating a value.
    /// 0.2 s ≈ 3× the 66 ms face cadence and ~20× the 90–120 Hz hand cadence, so genuine
    /// consecutive samples always pass and only real gaps are dropped.
    var maxSampleDt: TimeInterval = 0.2
    /// Rolling window for the mean joint speed (motion energy). ~2 s smooths the 90–120 Hz
    /// jitter into a stable arousal level while still tracking onsets within a gesture.
    var speedWindow: TimeInterval = 2.0
    /// Hard cap on retained velocity samples (bounded memory regardless of session length).
    var maxSpeedSamples = 600

    /// SELF-TOUCH threshold: any hand joint within this of the head position counts as
    /// proximity. 0.12 m (~12 cm) brackets hand-to-face / hand-to-head contact while
    /// staying clear of normal gesticulation in front of the face.
    var selfTouchDistance: Double = 0.12
    /// Proximity must PERSIST this long before it counts as a self-touch (a fleeting
    /// pass-through of the head region is not a self-touch).
    var selfTouchDwell: TimeInterval = 0.3
    /// After a counted self-touch, ignore further detections for this long, so ONE
    /// sustained touch is not recounted (self-touch is a RATE, never a single touch —
    /// §3.3). A distinct later touch (proximity released then re-entered past this) counts.
    var selfTouchRefractory: TimeInterval = 2.0

    /// GESTURE burst: an instantaneous hand speed at/above this is a motion burst. 0.5 m/s
    /// is a brisk gesture (well above resting hand jitter, ~0.02–0.05 m/s).
    var burstSpeed: Double = 0.5
    /// After a burst, suppress re-triggering for this long so one continuous wave is ONE
    /// burst, not many.
    var burstRefractory: TimeInterval = 0.6

    /// Rolling window for the self-touch / gesture RATES. 60 s ⇒ a count in the window IS
    /// the per-minute rate (the `EyeChannel.blinksPerMinute` convention).
    var rateWindow: TimeInterval = 60
    /// A sample within this of `now` counts as "tracked right now" (else the hands are
    /// out of frustum and the channel reads `.degraded`).
    var recency: TimeInterval = 0.5

    // MARK: State

    private struct SpeedSample { var date: Date; var speed: Double }
    private var speedSamples: [SpeedSample] = []
    /// Last TRACKED sample per hand, for the gap-aware consecutive-pair velocity.
    private var lastTrackedByHand: [HandSide: HandJointsSample] = [:]
    private var latestAperture: Double?

    private var headPos: SIMD3<Double>?
    private(set) var headSeen = false

    /// When proximity (any joint < threshold) began, PER hand; nil while not near.
    private var proximitySince: [HandSide: Date] = [:]
    private var selfTouchRefractoryUntil: Date?
    private var selfTouchTimes: [Date] = []
    private(set) var selfTouchTotal = 0

    private var burstRefractoryUntil: Date?
    private var gestureTimes: [Date] = []
    private(set) var gestureBurstTotal = 0

    private(set) var lastSampleDate: Date?
    private(set) var lastTrackedDate: Date?
    private(set) var ingestCount = 0

    init() {}

    // MARK: Head position (for self-touch distance)

    /// Update the head (device-anchor) world position used for the self-touch distance.
    mutating func ingestHead(_ position: SIMD3<Double>, at date: Date) {
        headPos = position
        headSeen = true
    }

    // MARK: Ingest one hand sample

    /// Fold one hand-joints sample into the windows. Gap-aware velocity, aperture,
    /// self-touch dwell/refractory, and gesture-burst detection all update here.
    mutating func ingest(_ sample: HandJointsSample) {
        ingestCount += 1
        lastSampleDate = sample.date
        prune(now: sample.date)

        guard sample.isTracked else {
            // Present but untracked (out of frustum): don't advance velocity or touch
            // state, and drop the stale per-hand "last" so the next tracked sample is
            // treated as a fresh start (its first pair is gap-guarded, never a jump-spike).
            lastTrackedByHand[sample.side] = nil
            proximitySince[sample.side] = nil
            return
        }
        lastTrackedDate = sample.date

        // (1) Motion energy — gap-aware consecutive-pair mean joint speed.
        if let prev = lastTrackedByHand[sample.side] {
            let dt = sample.date.timeIntervalSince(prev.date)
            if dt > 0, dt <= maxSampleDt {
                if let speed = Self.meanJointSpeed(prev.positions, sample.positions, dt: dt) {
                    speedSamples.append(SpeedSample(date: sample.date, speed: speed))
                    if speedSamples.count > maxSpeedSamples {
                        speedSamples.removeFirst(speedSamples.count - maxSpeedSamples)
                    }
                    // Gesture burst on a motion spike (with a refractory so one wave = one burst).
                    if speed >= burstSpeed {
                        let blocked = burstRefractoryUntil.map { sample.date < $0 } ?? false
                        if !blocked {
                            gestureTimes.append(sample.date)
                            gestureBurstTotal += 1
                            burstRefractoryUntil = sample.date.addingTimeInterval(burstRefractory)
                        }
                    }
                }
            }
            // dt > maxSampleDt ⇒ a gap: SKIP (no motion sample, no spike).
        }
        lastTrackedByHand[sample.side] = sample

        // (2) Aperture (a tension feature — never valence).
        if let aperture = Self.aperture(sample.positions) {
            latestAperture = aperture
        }

        // (3) Self-touch — min any-joint↔head distance, with dwell + refractory.
        if let head = headPos {
            let near = Self.minDistance(sample.positions, to: head).map { $0 < selfTouchDistance } ?? false
            if near {
                let since = proximitySince[sample.side] ?? sample.date
                proximitySince[sample.side] = since
                let dwellMet = sample.date.timeIntervalSince(since) >= selfTouchDwell
                let refractoryOK = selfTouchRefractoryUntil.map { sample.date >= $0 } ?? true
                if dwellMet, refractoryOK {
                    selfTouchTimes.append(sample.date)
                    selfTouchTotal += 1
                    selfTouchRefractoryUntil = sample.date.addingTimeInterval(selfTouchRefractory)
                }
            } else {
                proximitySince[sample.side] = nil
            }
        }
    }

    // MARK: Rolling reads (all take `now`, so they age between samples)

    /// Mean joint speed over the trailing `speedWindow` (m/s) — the motion energy. 0 when
    /// no velocity samples are in the window (hands still, or out of frustum).
    func meanJointSpeed(now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-speedWindow)
        let xs = speedSamples.filter { $0.date >= cutoff && $0.date <= now }.map(\.speed)
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Velocity samples in the trailing `speedWindow` — density → the channel's maturity.
    func sampleCount(now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-speedWindow)
        return speedSamples.filter { $0.date >= cutoff && $0.date <= now }.count
    }

    /// Latest hand aperture (thumb↔index / hand scale); `nil` until one is computable.
    var handAperture: Double? { latestAperture }

    /// Self-touch events per minute over the trailing `rateWindow`.
    func selfTouchRate(now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-rateWindow)
        return Double(selfTouchTimes.filter { $0 >= cutoff && $0 <= now }.count)
    }

    /// Gesture bursts per minute over the trailing `rateWindow`.
    func gestureRate(now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-rateWindow)
        return Double(gestureTimes.filter { $0 >= cutoff && $0 <= now }.count)
    }

    /// A tracked hand sample arrived within `recency` of `now`.
    func tracked(now: Date) -> Bool {
        lastTrackedDate.map { now.timeIntervalSince($0) <= recency } ?? false
    }

    // MARK: Window maintenance

    private mutating func prune(now: Date) {
        let speedCutoff = now.addingTimeInterval(-speedWindow)
        speedSamples.removeAll { $0.date < speedCutoff }
        let rateCutoff = now.addingTimeInterval(-rateWindow)
        selfTouchTimes.removeAll { $0 < rateCutoff }
        gestureTimes.removeAll { $0 < rateCutoff }
    }

    // MARK: Pure geometry (static → directly unit-tested)

    /// Mean per-joint displacement / Δt over the joints present in BOTH samples (m/s).
    /// `nil` when the samples share no joint.
    static func meanJointSpeed(_ a: [HandJoint: SIMD3<Double>],
                               _ b: [HandJoint: SIMD3<Double>],
                               dt: TimeInterval) -> Double? {
        guard dt > 0 else { return nil }
        var sum = 0.0
        var n = 0
        for joint in HandJoint.allCases {
            if let p = a[joint], let q = b[joint] {
                sum += distance(p, q)
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return (sum / Double(n)) / dt
    }

    /// Hand aperture = thumb-tip↔index-tip distance normalized by the wrist↔middle-knuckle
    /// hand length (scale-invariant). `nil` when the required joints or a positive scale
    /// aren't present.
    static func aperture(_ p: [HandJoint: SIMD3<Double>]) -> Double? {
        guard let thumb = p[.thumbTip], let index = p[.indexTip],
              let wrist = p[.wrist], let knuckle = p[.middleKnuckle] else { return nil }
        let scale = distance(wrist, knuckle)
        guard scale > 1e-4 else { return nil }
        return distance(thumb, index) / scale
    }

    /// Minimum distance from any present joint to `head`; `nil` if the sample has no joints.
    static func minDistance(_ p: [HandJoint: SIMD3<Double>], to head: SIMD3<Double>) -> Double? {
        var best: Double?
        for pos in p.values {
            let d = distance(pos, head)
            if best == nil || d < best! { best = d }
        }
        return best
    }

    /// Euclidean distance between two world points (stdlib SIMD arithmetic — no `simd`
    /// free functions, so the pure core stays dependency-light).
    static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }
}

// MARK: - HandAnalyzer (the off-main actor)

/// The hands off-main aggregator (US-D13a, PRD v2 §2.1 hands row: 90–120 Hz). An `actor`
/// (the `FaceAnalyzer` idiom) so the high-rate anchor ingestion never touches the main
/// actor; it wraps the pure `HandKinematics` and vends throttled (~10 Hz) snapshots to the
/// `HandsChannel`. ARKit-free by design — the `ImmersiveSensingCoordinator` maps
/// `HandAnchor` → `HandJointsSample` and feeds them here, so this stays deterministic and
/// unit-testable.
actor HandAnalyzer {

    private var kinematics = HandKinematics()
    /// How many self-touch / gesture events have already been reported via a snapshot, so
    /// each `snapshot()` returns only the NEWLY-detected events.
    private var reportedSelfTouch = 0
    private var reportedGesture = 0

    init() {}

    /// Ingest one hand sample (called at 90–120 Hz from the coordinator's anchor task).
    func ingest(_ sample: HandJointsSample) {
        kinematics.ingest(sample)
    }

    /// Update the head (device-anchor) position used for the self-touch distance.
    func ingestHead(_ position: SIMD3<Double>, at date: Date) {
        kinematics.ingestHead(position, at: date)
    }

    /// Drop all transient state (called on immersive-space close).
    func reset() {
        kinematics = HandKinematics()
        reportedSelfTouch = 0
        reportedGesture = 0
    }

    /// A throttled snapshot for the channel. Returns the newly-detected event counts since
    /// the previous call, so the channel emits exactly the fresh self-touch / gesture events.
    func snapshot(at now: Date = Date()) -> HandKinematicsSnapshot {
        let newSelfTouch = max(0, kinematics.selfTouchTotal - reportedSelfTouch)
        let newGesture = max(0, kinematics.gestureBurstTotal - reportedGesture)
        reportedSelfTouch = kinematics.selfTouchTotal
        reportedGesture = kinematics.gestureBurstTotal
        return HandKinematicsSnapshot(
            date: now,
            hasData: kinematics.lastSampleDate != nil,
            tracked: kinematics.tracked(now: now),
            meanJointSpeed: kinematics.meanJointSpeed(now: now),
            handAperture: kinematics.handAperture,
            selfTouchRate: kinematics.selfTouchRate(now: now),
            gestureRate: kinematics.gestureRate(now: now),
            newSelfTouchEvents: newSelfTouch,
            newGestureBursts: newGesture,
            sampleCount: kinematics.sampleCount(now: now),
            headSeen: kinematics.headSeen,
            ingestCount: kinematics.ingestCount
        )
    }
}

#endif
