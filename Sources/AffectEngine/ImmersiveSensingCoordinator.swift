//
//  ImmersiveSensingCoordinator.swift
//  AffectLens
//
//  The immersive-space sensing lifecycle (US-D13a, PRD v2 §7.4 point 5). Owned by the
//  `AffectHub` (so it composes with the hub's channels + event bus), driven by
//  `ImmersiveView.onAppear` / `.onDisappear` — the aura space is the ONE surface where
//  ARKit hand / world tracking runs, so its open/close IS this coordinator's start/stop.
//
//  This is the K1 KEYSTONE instrument (PRD §8.0 K1): `HandTrackingProvider` running
//  ALONGSIDE the Persona camera. It runs an `ARKitSession` with `HandTrackingProvider` +
//  `WorldTrackingProvider`, consumes `handTracking.anchorUpdates` OFF the main actor into
//  the `HandAnalyzer` actor, polls the device anchor for the head POSITION (self-touch
//  distance only — the head channel proper is a later item), and pushes throttled
//  snapshots into the `HandsChannel`. The K1 HUD reads `status` + `handsUpdateHz` here
//  against `EmotionEngine.processedFPS`.
//
//  Defensive by construction (the simulator has NO hand-tracking provider; a device may
//  deny auth): provider-unsupported / auth-denied / session-error each map to a TYPED
//  `.unavailable` reason surfaced on the hands channel + the K1 HUD. It NEVER crashes and
//  NEVER touches the face pipeline. ARKit is consumed ONLY here (visionOS-gated), so
//  everything else compiles for the simulator and degrades typed-unavailable at runtime.
//
//  Consent: opening the immersive space is itself user-initiated, and the FIRST run this
//  launch requests ARKit hand-tracking authorization (`ARKitSession.requestAuthorization`),
//  whose system prompt is the consent gate; the grant is surfaced through `Permissions`.
//

#if os(visionOS)

import Foundation
import ARKit
import QuartzCore   // CACurrentMediaTime for queryDeviceAnchor

/// Runs the immersive-space ARKit sensing and feeds the `HandsChannel`. `@MainActor
/// @Observable` so `ImmersiveView` drives its lifecycle and the K1 HUD observes `status` /
/// `handsUpdateHz` directly; the high-rate anchor consumption happens off-main (a detached
/// task into the `HandAnalyzer` actor).
@MainActor
@Observable
final class ImmersiveSensingCoordinator {

    /// The coordinator's lifecycle / health — the K1 HUD status line and the source of the
    /// hands channel's typed unavailable reason.
    nonisolated enum Status: Equatable, Sendable {
        /// Not started (immersive space closed).
        case idle
        /// Starting up (auth + provider run in flight).
        case starting
        /// Running — hand tracking is live alongside the camera (the K1 pass state).
        case running
        /// `HandTrackingProvider` isn't supported here (e.g. the simulator).
        case unsupported
        /// ARKit hand-tracking authorization was denied.
        case authDenied
        /// The ARKit session failed to start (message for the HUD).
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "idle — immersive space closed"
            case .starting: return "starting…"
            case .running: return "running · hands + camera coexisting"
            case .unsupported: return "hand tracking unsupported here (e.g. simulator)"
            case .authDenied: return "hand tracking denied — allow it in Settings"
            case .failed(let m): return "failed — \(m)"
            }
        }
    }

    private(set) var status: Status = .idle
    /// Measured hand anchor-update rate (updates/s), derived from `HandAnalyzer` ingest
    /// deltas across the poll cadence — the K1 evidence that hand tracking coexists with the
    /// ~15 Hz face pipeline.
    private(set) var handsUpdateHz: Double = 0
    /// Whether a device (head) anchor has been queried this session (self-touch is only
    /// computable once true).
    private(set) var deviceAnchorSeen = false

    // MARK: Wiring

    @ObservationIgnored private weak var hub: AffectHub?
    @ObservationIgnored private let analyzer = HandAnalyzer()
    @ObservationIgnored private var session: ARKitSession?
    @ObservationIgnored private var anchorTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Guards re-entrancy (both scenes can drive onAppear paths). True from `startIfNeeded`
    /// until `stop`.
    @ObservationIgnored private var running = false
    @ObservationIgnored private var lastIngestCount = 0
    @ObservationIgnored private var lastHzSample = Date()

    /// Snapshot / head-poll cadence (~10 Hz) — prosody-slow relative to the 90–120 Hz hands.
    /// A `var` (not static) so the thermal governor (US-D13b, §8.1) can slow it: 10 Hz
    /// nominal → 5 (serious) → 2 (critical). The running loop reads `self.pollInterval` each
    /// pass, so a change takes effect on the next iteration.
    @ObservationIgnored private var pollInterval: Duration = .milliseconds(100)

    init() {}

    /// The thermal governor sets the device-anchor poll rate (US-D13b, §8.1). Clamped to a
    /// sane floor/ceiling so the loop never busy-spins or stalls; takes effect next iteration.
    func setPollHz(_ hz: Double) {
        let clamped = min(30, max(1, hz))
        pollInterval = .milliseconds(Int((1000.0 / clamped).rounded()))
    }

    /// The `HandAnalyzer` this coordinator feeds — exposed so the hands lens's RAW strata can
    /// (later) read it directly; today the coordinator pushes snapshots into the channel.
    var handAnalyzer: HandAnalyzer { analyzer }

    /// Called once by `AffectHub.init`.
    func connect(hub: AffectHub) {
        self.hub = hub
    }

    // MARK: Lifecycle (driven by ImmersiveView.onAppear / .onDisappear)

    /// Start ARKit sensing when the immersive space opens. Idempotent (a re-entrant open is a
    /// no-op while already running). Runs entirely in a `Task` because ARKit auth + run are
    /// async; every failure path degrades to a typed `.unavailable` on the hands channel.
    func startIfNeeded() {
        guard !running else { return }
        running = true
        Task { await start() }
    }

    /// Stop ARKit sensing when the immersive space closes: cancel the tasks, stop the session,
    /// reset the analyzer, and flip the hands channel to `.unavailable(.immersiveClosed)` (the
    /// future head channel flips here too). Safe to call repeatedly.
    func stop() {
        running = false
        anchorTask?.cancel(); anchorTask = nil
        pollTask?.cancel(); pollTask = nil
        session?.stop()
        session = nil
        status = .idle
        handsUpdateHz = 0
        deviceAnchorSeen = false
        lastIngestCount = 0
        let analyzer = self.analyzer
        Task { await analyzer.reset() }
        hub?.hands.markUnavailable(.immersiveClosed)
        // The 6DoF head source is gone; the windowed source (if a face is in the window)
        // takes back over. Never flips the head lens off — windowed head still works.
        hub?.head.immersiveSourceEnded()
    }

    // MARK: Start (async — auth + provider run + off-main anchor consumption)

    private func start() async {
        status = .starting

        // Provider support first — the simulator has no hand tracking, so bail cleanly
        // BEFORE requesting auth (no spurious prompt, no hang on an empty anchor stream).
        guard HandTrackingProvider.isSupported else {
            status = .unsupported
            hub?.hands.markUnavailable(.providerUnsupported)
            running = false
            return
        }

        let session = ARKitSession()
        self.session = session

        // ARKit hand-tracking auth is requested HERE, at immersive open (not in `Permissions`);
        // the grant is surfaced through `Permissions` for one status view.
        let auth = await session.requestAuthorization(for: [.handTracking])
        let handAuthorized = auth[.handTracking] == .allowed
        Permissions.handTrackingAuthorized = handAuthorized
        guard running else { return }   // stopped during the await
        guard handAuthorized else {
            status = .authDenied
            hub?.hands.markUnavailable(.authDenied)
            running = false
            return
        }

        let hand = HandTrackingProvider()
        // World tracking (device anchor → head position) is best-effort: run it only if
        // supported; without it, self-touch is simply unavailable (headSeen stays false) and
        // motion energy + gestures still work.
        let world: WorldTrackingProvider? = WorldTrackingProvider.isSupported ? WorldTrackingProvider() : nil
        var providers: [any DataProvider] = [hand]
        if let world { providers.append(world) }

        do {
            try await session.run(providers)
        } catch {
            status = .failed("\(error)")
            hub?.hands.markUnavailable(.sessionError("\(error)"))
            running = false
            return
        }
        guard running else { return }
        status = .running
        lastIngestCount = 0
        lastHzSample = Date()

        // Consume hand anchor updates OFF the main actor into the analyzer actor (a detached
        // task, so the 90–120 Hz loop never rides the MainActor). `hand` + `analyzer` are both
        // Sendable; the ARKit → sample mapping is a pure `nonisolated static`.
        let analyzer = self.analyzer
        anchorTask = Task.detached {
            for await update in hand.anchorUpdates {
                guard let sample = Self.sample(from: update.anchor) else { continue }
                await analyzer.ingest(sample)
            }
        }

        // Poll loop on the MAIN actor: query the device anchor for the head position, pull a
        // snapshot, feed the channel, and measure the hands update Hz for the K1 HUD.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.running else { return }
                if let world {
                    if let device = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                        let m = device.originFromAnchorTransform
                        let pos = SIMD3<Double>(Double(m.columns.3.x),
                                                Double(m.columns.3.y),
                                                Double(m.columns.3.z))
                        self.deviceAnchorSeen = true
                        await self.analyzer.ingestHead(pos, at: Date())
                        // US-D13b: the SAME device anchor yields the head channel's 6DoF
                        // orientation (the PREFERRED head-pose source). Extract the rotation
                        // basis columns and push a pose; a disabled head lens ignores it.
                        let xA = SIMD3<Double>(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z))
                        let yA = SIMD3<Double>(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z))
                        let zA = SIMD3<Double>(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z))
                        let pose = HeadPoseMath.pose(fromDeviceColumns: xA, yA, zA)
                        self.hub?.head.applyImmersive(pose: pose, at: Date())
                    }
                }
                let now = Date()
                let snap = await self.analyzer.snapshot(at: now)
                self.updateHz(ingestCount: snap.ingestCount, at: now)
                self.hub?.hands.apply(snap)
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    /// Update the measured hands update rate from the analyzer's cumulative ingest count.
    private func updateHz(ingestCount: Int, at now: Date) {
        let dt = now.timeIntervalSince(lastHzSample)
        guard dt >= 0.25 else { return }   // smooth over ~¼ s so the readout is legible
        let delta = max(0, ingestCount - lastIngestCount)
        handsUpdateHz = Double(delta) / dt
        lastIngestCount = ingestCount
        lastHzSample = now
    }

    // MARK: ARKit → sample mapping (pure, nonisolated — ARKit types confined to this file)

    /// Map one `HandAnchor` → an ARKit-free `HandJointsSample` in WORLD space. `nonisolated`
    /// so the off-main anchor task can call it (ARKit anchor types are Sendable). Untracked or
    /// skeleton-less anchors yield an `isTracked: false` sample (which ages the windows without
    /// contributing motion — never a fabricated velocity).
    private nonisolated static func sample(from anchor: HandAnchor) -> HandJointsSample? {
        // The joints the kinematics needs, mapped to their ARKit `HandSkeleton.JointName`s.
        // Local (not a static property) so it carries no actor isolation.
        let jointMap: [(HandJoint, HandSkeleton.JointName)] = [
            (.wrist, .wrist),
            (.thumbTip, .thumbTip),
            (.indexTip, .indexFingerTip),
            (.middleTip, .middleFingerTip),
            (.ringTip, .ringFingerTip),
            (.littleTip, .littleFingerTip),
            (.middleKnuckle, .middleFingerKnuckle)
        ]
        let side: HandSide = anchor.chirality == .left ? .left : .right
        let now = Date()
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            return HandJointsSample(side: side, date: now, positions: [:], isTracked: false)
        }
        let origin = anchor.originFromAnchorTransform
        var positions: [HandJoint: SIMD3<Double>] = [:]
        for (kind, name) in jointMap {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { continue }
            let world = origin * joint.anchorFromJointTransform
            let c = world.columns.3
            positions[kind] = SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))
        }
        return HandJointsSample(side: side, date: now, positions: positions, isTracked: true)
    }
}

#endif
