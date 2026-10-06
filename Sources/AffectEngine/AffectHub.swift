//
//  AffectHub.swift
//  AffectLens
//
//  The affect-sensing composition root (US-A3, PRD v2 §7.3) — a SEPARATE object
//  that COMPOSES the per-channel lenses rather than growing them into one god
//  engine. PRD §5.2 explicitly REJECTS "growing `EmotionEngine` into the hub"
//  (it would bloat the face pipeline with ARKit/audio concerns and risk the
//  face regression); the hub is that separate composition root.
//
//  Today the hub owns exactly one channel — the always-on face lens — so an
//  "empty" hub IS the current app: with nothing else enabled, everything routes
//  to `face` and behavior is byte-identical to before the hub existed. Later
//  items add the eyes/hands/head/voice/interaction channels, a `fusion` output,
//  and an auditable `events` log.
//

#if os(visionOS) || os(macOS)

import Foundation

/// The composition root for multi-channel affect sensing (PRD v2 §7.3).
///
/// Owns the face lens today; later items grow it with the other channels plus
/// fusion + events. `@MainActor @Observable` to match the channel objects it
/// holds and so SwiftUI can observe it directly once it publishes fused state.
@MainActor
@Observable
final class AffectHub {
    /// The face lens — today's `EmotionEngine`, the always-on default channel
    /// and (per PRD law) the only one that reads the Persona avatar and carries
    /// a discrete-emotion posterior. The hub OWNS it: construct the hub and you
    /// get the engine, deterministically.
    let face: EmotionEngine

    /// The generalized per-channel baseline layer (US-A4, PRD v2 §5.4). Holds
    /// robust median + MAD stats per `Channel`, migrated from the v1 face
    /// `NeutralBaseline` on first load. Consumed by the windowed channels
    /// (`EyeChannel` today; hands / head / voice / interaction later) for their own
    /// per-Persona baselining and low-expresser confidence-widening; the face engine
    /// keeps using its own `NeutralBaseline` unchanged (zero face regression).
    ///
    /// A `var` because channels slow-retrack their entries in place (alpha 0.02) and
    /// persist through `save()`; `@ObservationIgnored` because those per-frame
    /// retracks must not churn SwiftUI observation (nothing observes the store — the
    /// channels publish their own readings).
    @ObservationIgnored
    var baselines: BaselineStore

    /// The eyes / blink lens (US-B5, PRD v2 §3.2). A pure consumer of the analysis
    /// fan-out — off by default (`lens.eyes.enabled`), registered only while enabled
    /// (see `refreshRegistration`). Owns no camera/Vision work.
    let eyes: EyeChannel

    /// The interaction-dynamics lens (US-B8, PRD v2 §3.6). Zero-permission, fully
    /// windowed — off by default (`lens.interaction.enabled`). It is NOT on the
    /// analysis fan-out (it has no per-frame consumer): it is fed by the Emotion tab's
    /// `SpatialEventGesture` (`.interactionSensing`) + explicit toggle hooks, and
    /// manages its own activate/deactivate via `refreshEnabled`. Owns no sensor.
    let interaction: InteractionChannel

    /// The voice lens (US-D12, PRD v2 §3.5). Arousal-ONLY, foreground-only, mic-gated —
    /// off by default (`lens.voice.enabled`). Like `interaction` it is NOT on the analysis
    /// fan-out: it owns a `VoiceAnalyzer` actor (mic tap + prosody + SoundAnalysis) and
    /// polls it, managing its own enable/background lifecycle. The hub reads its
    /// `speechGateActive` each tick to gate the eyes lens's blink→arousal read.
    let voice: VoiceChannel

    /// The hands lens (US-D13a, PRD v2 §3.3). Immersive-only — off by default
    /// (`lens.hands.enabled`). Like `voice` it is NOT on the analysis fan-out: the
    /// `immersiveSensing` coordinator (which owns the ARKit session + `HandAnalyzer` actor)
    /// pushes throttled snapshots into it while the immersive space is open, and flips it
    /// `.unavailable` on close. Hands own AROUSAL / agitation / load — never valence.
    let hands: HandsChannel

    /// The head lens (US-D13b, PRD v2 §3.4). DUAL-SOURCE: the windowed `VNFaceObservation`
    /// pose rides the analysis fan-out (so it works in the plain window), and the immersive
    /// coordinator pushes the higher-fidelity 6DoF device pose while the aura is open. Head
    /// owns DOMINANCE / APPROACH + AROUSAL — never valence. Off by default
    /// (`lens.head.enabled`); registered on the fan-out only while enabled (`refreshRegistration`).
    let head: HeadChannel

    /// The immersive-space sensing lifecycle (US-D13a, PRD v2 §7.4 point 5). Owned HERE (so
    /// it composes with the channels + event bus) and driven by `ImmersiveView.onAppear` /
    /// `.onDisappear`. Runs `HandTrackingProvider` + `WorldTrackingProvider` alongside the
    /// Persona camera (the K1 keystone), feeding `hands` and the head channel's 6DoF source.
    /// Inert until `startIfNeeded()`, so a throwaway hub (the DEBUG self-tests, the simulator)
    /// never touches ARKit.
    let immersiveSensing: ImmersiveSensingCoordinator

    /// The sensing governor (US-D13b, PRD v2 §8.1 / §8.5) — the thermal state as a real
    /// scheduler. Owned HERE; observes `ProcessInfo.thermalState` and applies a
    /// `SensingPolicy` (face cadence, FER+ enable, immersive poll rate, aux-channel gating)
    /// as the device warms. Connected LAST in `init` (all channels + engine exist), and inert
    /// at `.nominal` — the default policy changes nothing (byte-identical).
    let thermalGovernor: ThermalGovernor

    /// The golden-trace flight recorder (US-E15, PRD v2 §5.7). INERT until `start()`;
    /// while recording it rides the same analysis fan-out (registered LAST, so engine
    /// + eyes + events state is already consistent for the frame) and appends a
    /// JSONL `TraceTick` per frame — features & events ONLY, never pixels. The hub
    /// owns it; it holds a weak back-reference.
    let traceRecorder: TraceRecorder

    /// The fusion-mode registry (US-B6 scaffold, first construct US-C9). Holds the
    /// off-by-default named constructs and gates each behind `fusion.<id>.enabled`.
    /// The hub OWNS it and evaluates its enabled+available modes each tick (see
    /// `evaluateFusion`). Registers F7 Frustration today; later constructs join here.
    let fusionRegistry = FusionRegistry()

    /// The ESM ground-truth store (US-E17, PRD v2 §5.7). Append-only local JSONL of the
    /// user's 1-tap self-reports (the honest inferred-vs-felt pairing), loaded on init.
    /// The single source of truth for the per-user CCC AND the non-neutral conformal set.
    let esm = EsmStore()

    /// The runtime-checked Health writer (US-E17). Attempts an `HKStateOfMind` write per
    /// report; degrades to `.localOnly(reason)` when Health is unavailable/unauthorized —
    /// never blocks the app. Owned here so `submitSelfReport` can orchestrate local-first.
    let healthWriter = HealthWriter()

    /// The live split-conformal status (US-E17, PRD §5.4). Recomputed from `esm.reports`
    /// on init and after every submit. `.uncalibrated` below the min-sample gate (the
    /// hero chip keeps its margin heuristic); `.calibrated(qhat:)` at/above it (the chip
    /// renders the calibrated "likely {…}" set). Observed by the ground-truth section.
    private(set) var conformalStatus: ConformalCalibrator.Status = .uncalibrated(mappablePairs: 0)

    /// The most recent Health-write outcome, surfaced in the ground-truth section's
    /// Health status line (savedToHealth vs localOnly + honest reason). Nil until the
    /// first report this launch.
    private(set) var lastHealthResult: HealthSaveResult?

    /// A per-frame face-ANALYSIS consumer (US-B5a). MainActor-isolated: it runs on
    /// the main actor alongside the engine tap that invokes it.
    typealias AnalysisConsumer = @MainActor (FrameAnalysis) -> Void

    /// Registered analysis consumers, kept in REGISTRATION order for deterministic
    /// fan-out (US-B5a). Windowed channels (eyes/blink, windowed head-pose)
    /// piggyback on the face pipeline's per-frame ANALYSIS rather than on raw
    /// camera buffers — there is no pixel-level distributor (PRD v2 §7.1 / §7.3):
    /// the engine exposes ONE `onAnalysis` tap and the hub multiplexes it here.
    /// Everything in this registry runs on the MainActor (the hub, the engine's
    /// tap, and every consumer are MainActor-isolated), so it is a plain array —
    /// NO locking is needed.
    @ObservationIgnored
    private var analysisConsumers: [(id: String, consumer: AnalysisConsumer)] = []

    /// The honest ANALYSIS-SESSION anchor (US-C11): the timestamp of the FIRST processed
    /// frame the hub ever dispatches — i.e. when the face pipeline began producing
    /// analyses this run (capture start). It backs the synthesized CONTEXT channel's
    /// `sessionMinutes` (the §3.7 modifier that feeds F3's fatigue accrual). Anchored on
    /// the first frame (not first FACE) so a look-away can't reset the clock; a fresh hub
    /// re-anchors, so accrual is per-run, never persisted.
    @ObservationIgnored
    private var sessionStart: Date?

    /// Construct the hub and, with it, the face engine it owns.
    init() {
        face = EmotionEngine()
        baselines = BaselineStore.loaded()
        eyes = EyeChannel()
        interaction = InteractionChannel()
        voice = VoiceChannel()
        hands = HandsChannel()
        head = HeadChannel()
        immersiveSensing = ImmersiveSensingCoordinator()
        thermalGovernor = ThermalGovernor()
        traceRecorder = TraceRecorder()
        // Wire the engine's single analysis tap to the hub's fan-out. `[weak self]`
        // breaks the hub → face → closure → hub retain cycle. The engine stays a
        // pure face lens; the hub owns the multiplexing (PRD v2 §5.2).
        face.onAnalysis = { [weak self] analysis in
            self?.dispatchAnalysis(analysis)
        }
        // Dimensional-combine seam (US-C8, PRD v2 §7.2 seam b): `face.vaTransform` is
        // deliberately left NIL here — the identity seam ⇒ byte-identical face output.
        // A later fusion construct (F1 composure-under-load, …) plugs its per-frame
        // valence/arousal blend in RIGHT HERE by setting `face.vaTransform`; non-face
        // channels reach the reading ONLY through that hook (seam-a veto), never the
        // categorical pool.
        // Give the eyes lens its baseline back-reference, then register it iff enabled.
        eyes.connect(hub: self)
        // The interaction lens gets the same baseline back-reference; it manages its
        // own enable lifecycle (no fan-out consumer — the view feeds it), so it is
        // deliberately NOT part of `refreshRegistration`.
        interaction.connect(hub: self)
        // The voice lens likewise self-manages (it polls its own analyzer actor, not the
        // fan-out); connecting seeds its baseline references and re-starts it if it was
        // left enabled across launches.
        voice.connect(hub: self)
        // The hands lens is fed by the immersive coordinator (not the fan-out); connecting
        // seeds its resting-speed reference and its honest space-closed initial state. The
        // coordinator gets its hub back-reference too, but stays inert until the immersive
        // space opens (`startIfNeeded`), so constructing a hub touches no ARKit.
        hands.connect(hub: self)
        // The head lens is DUAL-SOURCE: connecting seeds its resting-energy + neutral-pose
        // references and its honest initial state; the windowed source is registered on the
        // fan-out by `refreshRegistration` when enabled, and the coordinator pushes the 6DoF
        // source while the immersive space is open.
        head.connect(hub: self)
        immersiveSensing.connect(hub: self)
        refreshRegistration()

        // Always-on face-axis state-shift monitor (US-B7). Registered unconditionally
        // (the face lens is always live), it samples the POST-apply valence/arousal
        // into the two BOCPD detectors and emits a `.stateShift` + insight on a
        // change-point. Registered here (never touched by `refreshRegistration`, which
        // only manages the eyes id) so it rides the same MainActor fan-out.
        addAnalysisConsumer(Self.stateShiftConsumerID) { [weak self] analysis in
            self?.ingestStateShift(analysis)
        }

        // Always-on cross-channel congruence monitor (US-C10a). Registered
        // unconditionally right after the state-shift monitor. It reads each channel's
        // freshest PUBLISHED vote (the channel's own reading), so it is independent of
        // fan-out order (a re-registered eyes consumer can land after it with no more
        // than a ~1-tick-stale vote), and it lands BEFORE the recorder (which registers
        // its consumer last, on start()).
        addAnalysisConsumer(Self.congruenceConsumerID) { [weak self] analysis in
            self?.ingestCongruence(analysis)
        }

        // Fusion evaluation (US-C9). Registered right AFTER congruence and BEFORE the
        // recorder, so every fused construct is evaluated against the frame's already-
        // consistent per-channel readings + congruence, and a construct's activation
        // event is on the bus before the recorder (start()-registered, last) snapshots
        // the tick. Off-by-default modes make this nearly free until one is enabled.
        fusionRegistry.register(F7FrustrationMode())     // F×I task-friction flagship (US-C9)
        fusionRegistry.register(F1ComposureMode())       // F×E composure-under-load (US-C10)
        fusionRegistry.register(F3FatigueEngagementMode())   // E-over-time coupled meter (US-C11)
        fusionRegistry.register(F2CognitiveLoadMode())   // E×I cognitive-load meter + variance (US-D14a)
        fusionRegistry.register(F4FrownHeadDownMode())   // F×Hd frown+head-down ladder (US-D14a)
        fusionRegistry.register(F6CorroboratedPositivityMode())  // F×V laughter-echoed positivity (US-D14b)
        fusionRegistry.register(F10ApproachWithdrawalMode())     // Hd×H coupled approach⇄withdrawal (US-D14b)
        fusionRegistry.register(F8DominanceMode())               // Hd×H coupled dominance display (US-D14b)
        fusionRegistry.register(F9ExpansiveDisplayMode())        // Hd×H×F expansive display, head-only (US-D14b)
        fusionRegistry.register(F5CovertArousalMode())           // E×(H/Hd/V) corroborated arousal (US-D14b)
        addAnalysisConsumer(Self.fusionConsumerID) { [weak self] analysis in
            self?.evaluateFusion(analysis)
        }

        // Wire the recorder's weak hub back-reference. It registers its OWN fan-out
        // consumer only when recording starts (so it lands LAST, after eyes + the
        // state-shift monitor) and is otherwise completely inert.
        traceRecorder.connect(hub: self)

        // Connect the sensing governor LAST, once every channel + the engine exist: it reads
        // the initial thermal state and applies the matching policy. At `.nominal` (the
        // common case) that policy IS today's behavior, so this is a no-op — byte-identical.
        thermalGovernor.connect(hub: self)

        // Seed the conformal status from any reports loaded off disk (US-E17), so a
        // returning user's calibrated set is live immediately at launch.
        recomputeConformal()
    }

    // MARK: - Channel registration

    /// (Re)register the opt-in windowed channels on the analysis fan-out to match
    /// their `isEnabled` flags. A lens is registered ONLY while enabled (cleaner than
    /// registered-but-inert: no wasted per-frame work when off), and its reading
    /// reports `.unavailable` while off. The K2 HUD toggle calls this after flipping
    /// the `UserDefaults` flag. Idempotent — safe to call repeatedly.
    func refreshRegistration() {
        if eyes.isEnabled {
            eyes.prepareForActivation()
            addAnalysisConsumer(EyeChannel.consumerID) { [weak eyes] analysis in
                eyes?.ingest(analysis)
            }
        } else {
            removeAnalysisConsumer(EyeChannel.consumerID)
            eyes.deactivate()
        }
        // The head lens's WINDOWED source rides the same fan-out (US-D13b). Registered only
        // while enabled; the immersive 6DoF source (pushed by the coordinator) is independent
        // and preferred whenever it is live.
        if head.isEnabled {
            head.prepareForActivation()
            addAnalysisConsumer(HeadChannel.consumerID) { [weak head] analysis in
                head?.ingest(analysis)
            }
        } else {
            removeAnalysisConsumer(HeadChannel.consumerID)
            head.deactivate()
        }
    }

    // MARK: - Analysis fan-out (US-B5a)

    /// Register a consumer of the per-frame face ANALYSIS under a stable `id`.
    /// Re-registering an existing `id` REPLACES its consumer in place (keeping its
    /// fan-out position). MainActor-only; no locking (see `analysisConsumers`).
    func addAnalysisConsumer(_ id: String, _ consumer: @escaping AnalysisConsumer) {
        if let i = analysisConsumers.firstIndex(where: { $0.id == id }) {
            analysisConsumers[i].consumer = consumer
        } else {
            analysisConsumers.append((id: id, consumer: consumer))
        }
    }

    /// Remove a previously-registered consumer. A no-op for an unknown `id`.
    func removeAnalysisConsumer(_ id: String) {
        analysisConsumers.removeAll { $0.id == id }
    }

    /// Fan one analysis out to every registered consumer, in registration order.
    /// Deterministic and MainActor-synchronous; invoked from the engine's
    /// `onAnalysis` tap wired in `init`.
    private func dispatchAnalysis(_ analysis: FrameAnalysis) {
        // Anchor the analysis session on the first processed frame (US-C11 context clock).
        if sessionStart == nil { sessionStart = analysis.date }
        // Voice speech gate (US-D12, PRD §3.5 honesty law): set the eyes lens's gate flag
        // from the voice channel's latest snapshot BEFORE fanning the frame out, so eye
        // ingestion THIS tick already discounts blink→arousal while the user is speaking
        // (speech drives blinks). Cheap and order-correct; a no-op while voice is off.
        eyes.speechGateActive = voice.speechGateActive
        for entry in analysisConsumers {
            entry.consumer(analysis)
        }
    }

    // MARK: - AffectEvent bus (US-B7, PRD v2 §5.3 / §5.5)

    /// The append-only affect-event ledger — the single auditable chokepoint every
    /// mechanical or agent behavior emits through (never a side channel). "One type,
    /// three consumers": debug HUD feed, regression fixture, LLM input. Capped like
    /// the face engine's `history` (see `eventsCap`); past events are never mutated.
    private(set) var events: [AffectEvent] = []

    /// The narrated insight feed (US-B7 §6.3) — one `InsightEntry` per narrated
    /// event, oldest-first. Observed by `InsightFeedView`.
    private(set) var insights: [InsightEntry] = []

    /// Event-log cap. Mirrors `EmotionEngine.historyCap` (720) — the same "keep a
    /// bounded rolling record" idiom. Events are sparse (a shift is rare), so this is
    /// a long audit window, not a per-frame buffer.
    static let eventsCap = 720
    /// Insight-feed cap (a smaller, human-scale window over the same idiom).
    static let insightsCap = 240

    /// Stable id for the always-on face-axis state-shift consumer on the fan-out.
    static let stateShiftConsumerID = "hub.stateShift"

    /// BOCPD detectors — one per honest dimensional axis. A shift on EITHER axis is a
    /// `.stateShift`: valence and arousal are the two dimensions the app tracks
    /// honestly (the face owns valence; every channel can touch arousal), so a
    /// change on either is a real, citable change in the reading.
    @ObservationIgnored private var valenceCPD = ChangePointDetector()
    @ObservationIgnored private var arousalCPD = ChangePointDetector()

    /// Slow per-axis reference (EMA, alpha `axisRefAlpha`) used ONLY to describe a
    /// detected shift's signed size/direction — kept out of the detector so the BOCPD
    /// stays a pure decision of WHEN, while these describe WHAT moved.
    @ObservationIgnored private var valenceRef = 0.0
    @ObservationIgnored private var arousalRef = 0.0
    @ObservationIgnored private var axisRefSeeded = false
    private let axisRefAlpha = 0.02

    // MARK: - Congruence engine (US-C10a, PRD v2 §4.4)

    /// The live cross-channel agreement read (§4.4) — consensus, direction, windowed
    /// synchrony, the retained per-channel votes, and the named state. Observed by the
    /// congruence RING + the circumplex GHOST votes. `.insufficient` until ≥2 channels
    /// vote (one voice is not agreement).
    ///
    /// This item COMPUTES and DISPLAYS agreement only; it does NOT change any fused
    /// reading — `face.vaTransform` stays nil and the pad's main dot stays the face V/A.
    private(set) var congruence: CongruenceState = .insufficient

    /// The pure congruence core (§4.4 options 1 + 2). Observation-ignored — it mutates
    /// every tick; views observe the published `congruence` snapshot, not the struct.
    @ObservationIgnored private var congruenceEngine = CongruenceEngine()

    /// Stable id for the always-on congruence consumer on the fan-out.
    static let congruenceConsumerID = "hub.congruence"

    /// The `.face` `BaselineStore` feature key for the rolling resting-arousal median
    /// the face's signed arousal delta is measured against.
    private static let faceArousalKey = FeatureKey.faceArousal.rawValue
    /// Slow re-track alpha for the resting-arousal baseline — the established
    /// 2 s-verified-neutral lerp rate reused per §5.4.
    private static let faceArousalBaselineAlpha = 0.02
    /// |face-arousal Δ from the resting baseline| that maps to a full-magnitude (±1)
    /// signed vote. The circumplex arousal coordinate spans ~[−0.45, +0.88] and rests
    /// at 0 for neutral, so a 0.5 delta already reads as a strong activation swing.
    private static let faceArousalDeltaScale = 0.5
    /// Calibration-quality input to `ChannelConfidence` when a channel's per-user
    /// baseline is not yet mature (un-calibrated Persona / unlearned resting blink
    /// rate): discounted, so the vote's reliability — its say in consensus — is lower
    /// until the baseline settles.
    private static let immatureCalibrationQuality = 0.5
    /// τ for the `ChannelConfidence` recency term. Votes are built from the freshest
    /// reading each tick (Δt ≈ 0 ⇒ recency ≈ 1 regardless), so this is a documented
    /// default rather than a tuned value.
    private static let confidenceTau = 1.0

    /// Append an event to the bus, trimming oldest-first past the cap. Append-only:
    /// existing entries are never rewritten.
    func emit(_ event: AffectEvent) {
        events.append(event)
        if events.count > Self.eventsCap {
            events.removeFirst(events.count - Self.eventsCap)
        }
    }

    private func appendInsight(_ entry: InsightEntry) {
        insights.append(entry)
        if insights.count > Self.insightsCap {
            insights.removeFirst(insights.count - Self.insightsCap)
        }
    }

    /// A CHANNEL-originated event entry point (US-D12): append it to the bus AND narrate it
    /// into the insight feed — the same emit+narrate the hub's own fan-out consumers do,
    /// exposed for channels that are NOT on the fan-out (the voice lens polls its own
    /// analyzer, so it emits its laughter corroboration through here).
    func emitChannelEvent(_ event: AffectEvent) {
        emit(event)
        appendInsight(TemplateNarrator.narrate(event, reading: face.reading))
    }

    /// Fan-out consumer: sample the face reading's valence/arousal into the BOCPD
    /// detectors and, on a change-point, emit a `.stateShift` + narrate it.
    private func ingestStateShift(_ analysis: FrameAnalysis) {
        let r = face.reading
        // A face gap is NOT an affect change (the reading decays toward rest while the
        // face is gone). Skip no-face frames so a look-away can't fake a shift (§3.2).
        guard r.faceDetected else { return }

        // Seed the references on the first face so the first move isn't measured
        // against an arbitrary 0.
        if !axisRefSeeded {
            valenceRef = r.valence
            arousalRef = r.arousal
            axisRefSeeded = true
        }

        let vFired = valenceCPD.observe(r.valence, at: r.date)
        let aFired = arousalCPD.observe(r.arousal, at: r.date)

        // Signed shift vs the lagged reference (computed BEFORE updating the refs).
        let vShift = r.valence - valenceRef
        let aShift = r.arousal - arousalRef
        valenceRef += axisRefAlpha * (r.valence - valenceRef)
        arousalRef += axisRefAlpha * (r.arousal - arousalRef)

        guard vFired || aFired else { return }

        // Primary = the fired axis that moved more; list it first so the narrator
        // describes it (and cite every axis that fired as evidence).
        let primaryValence = (vFired ? abs(vShift) : -1) >= (aFired ? abs(aShift) : -1)
        var evidence: [SignalRef] = []
        if primaryValence {
            evidence.append(.valence)
            if aFired { evidence.append(.arousal) }
        } else {
            evidence.append(.arousal)
            if vFired { evidence.append(.valence) }
        }
        let signedShift = primaryValence ? vShift : aShift
        let confidence = primaryValence ? valenceCPD.changeConfidence : arousalCPD.changeConfidence

        let event = AffectEvent(
            t: r.date,
            channel: .face,
            kind: .stateShift,
            magnitude: abs(signedShift),
            confidence: confidence,
            evidence: evidence,
            baselineDelta: signedShift
        )
        emit(event)
        // Latch the shift for the never-interruptive ESM prompt (US-E17, PRD OQ14). The
        // banner surfaces only once cooldowns pass; the store no-ops if one is pending.
        esm.noteStateShift(at: r.date)
        appendInsight(TemplateNarrator.narrate(event, reading: r))
    }

    // MARK: - Congruence fan-out consumer (US-C10a, PRD v2 §4.4)

    /// Fan-out consumer: build each voting channel's signed arousal delta + reliability,
    /// step the congruence engine, publish the state, and (on a rising edge) emit a
    /// `.congruenceBreak` / `.arousalConsensus` event + insight.
    ///
    /// Reads each channel's LATEST published reading (fan-out-order-independent). Only
    /// arousal-bearing channels vote — face (circumplex arousal, as a signed delta from a
    /// per-user resting baseline), eyes (signed blink-rate delta), hands (signed
    /// motion-energy delta), head (signed head-motion-energy delta), and voice (signed
    /// prosody delta — voice OWNS arousal, §3.5/§4.4). Interaction is excluded BY DESIGN —
    /// it owns the effort / load axis, not arousal (§2 master law, §3.6). The published
    /// readings and `face.vaTransform` are untouched: this computes and displays
    /// agreement, it does not fuse.
    private func ingestCongruence(_ analysis: FrameAnalysis) {
        let now = analysis.date
        var votes: [Channel: ChannelVote] = [:]

        // FACE — the circumplex arousal coordinate, as a signed delta from the per-user
        // resting-arousal baseline (seed-if-absent + slow retrack, §5.4). A face gap does
        // not vote (no fresh arousal to trust).
        let r = face.reading
        if r.faceDetected {
            let median = seededFaceArousalMedian(r.arousal)
            let delta = r.arousal - median
            let signed = max(-1, min(1, delta / Self.faceArousalDeltaScale))
            let reliability = ChannelConfidence.confidence(
                calibrationQuality: face.isCalibrated ? 1 : Self.immatureCalibrationQuality,
                availability: .live,
                secondsSinceUpdate: 0,
                tau: Self.confidenceTau,
                dataQuality: r.quality
            )
            if reliability > 0 {
                votes[.face] = ChannelVote(signedArousalDelta: signed, reliability: reliability)
            }
        }

        // EYES — the SIGNED, normalized blink-rate delta the channel exposes for
        // consensus. Reliability gated on enabled + resting-rate maturity + availability.
        if eyes.isEnabled, let signed = eyes.signedArousalDelta {
            let reliability = ChannelConfidence.confidence(
                calibrationQuality: eyes.restingLearned ? 1 : Self.immatureCalibrationQuality,
                availability: eyes.availability,
                secondsSinceUpdate: 0,
                tau: Self.confidenceTau,
                dataQuality: eyes.quality
            )
            if reliability > 0 {
                votes[.eyes] = ChannelVote(signedArousalDelta: signed, reliability: reliability)
            }
        }

        // HANDS — the SIGNED, normalized motion-energy delta the channel exposes for consensus
        // (US-D13a, §3.3: hands own arousal). Reliability gated on enabled + resting-baseline
        // maturity + availability, exactly like eyes. A dark / disabled / space-closed hands
        // channel returns nil ⇒ it doesn't vote (one dark channel changes nothing).
        if hands.isEnabled, let signed = hands.signedArousalDelta {
            let reliability = ChannelConfidence.confidence(
                calibrationQuality: hands.restingLearned ? 1 : Self.immatureCalibrationQuality,
                availability: hands.availability,
                secondsSinceUpdate: 0,
                tau: Self.confidenceTau,
                dataQuality: hands.quality
            )
            if reliability > 0 {
                votes[.hands] = ChannelVote(signedArousalDelta: signed, reliability: reliability)
            }
        }

        // HEAD — the SIGNED, normalized head-motion-energy delta the channel exposes for
        // consensus (US-D13b, §3.4: head owns arousal too). Reliability gated on enabled +
        // resting-baseline maturity + availability, exactly like hands. A dark / disabled /
        // no-pose head channel returns nil ⇒ it doesn't vote.
        if head.isEnabled, let signed = head.signedArousalDelta {
            let reliability = ChannelConfidence.confidence(
                calibrationQuality: head.restingLearned ? 1 : Self.immatureCalibrationQuality,
                availability: head.availability,
                secondsSinceUpdate: 0,
                tau: Self.confidenceTau,
                dataQuality: head.quality
            )
            if reliability > 0 {
                votes[.head] = ChannelVote(signedArousalDelta: signed, reliability: reliability)
            }
        }

        // VOICE — the SIGNED, normalized prosody arousal delta the channel exposes for
        // consensus (US-D12, §3.5: voice OWNS arousal — the §4.4 master-law voter set is
        // face/eyes/hands/head/voice). Reliability gated on enabled + voiced-baseline
        // maturity + availability, exactly like the others. A silent / disabled /
        // unavailable voice channel returns nil ⇒ it doesn't vote. Note the designed
        // interplay: while the user speaks, the eyes lens's blink vote is speech-gated
        // DOWN (its confidence factor) precisely when this vote comes alive.
        if voice.isEnabled, let signed = voice.signedArousalDelta {
            let reliability = ChannelConfidence.confidence(
                calibrationQuality: voice.baselineLearned ? 1 : Self.immatureCalibrationQuality,
                availability: voice.availability,
                secondsSinceUpdate: 0,
                tau: Self.confidenceTau,
                dataQuality: voice.quality
            )
            if reliability > 0 {
                votes[.voice] = ChannelVote(signedArousalDelta: signed, reliability: reliability)
            }
        }

        let update = congruenceEngine.update(votes: votes, at: now)
        if update.state != congruence { congruence = update.state }

        if update.divergenceBegan {
            emitCongruenceEvent(.congruenceBreak, state: update.state, reading: r)
        }
        if update.agreementBegan {
            emitCongruenceEvent(.arousalConsensus, state: update.state, reading: r)
        }
    }

    /// Seed-if-absent then slow-retrack the `.face` resting-arousal baseline in the
    /// shared store, returning the current median. Mirrors `EyeChannel.observeBaseline`
    /// (`BaselineStore.retrack` no-ops on an unbaselined feature, so a signal the
    /// 36-sample neutral ritual never touches bootstraps its entry here on first
    /// observation). The very first frame seeds median = the observation ⇒ a 0 delta,
    /// then the baseline converges over seconds. Session-scoped in practice; it reuses
    /// the persisted store, so it is incidentally saved whenever another channel saves.
    private func seededFaceArousalMedian(_ observed: Double) -> Double {
        if baselines.stat(.face, Self.faceArousalKey) == nil {
            var entry = baselines.channels[.face] ?? .empty
            entry[Self.faceArousalKey] = RobustStat(median: observed, mad: RobustStat.unknownMAD)
            baselines.channels[.face] = entry
            return observed
        }
        baselines.retrack(channel: .face, feature: Self.faceArousalKey,
                          observed: observed, alpha: Self.faceArousalBaselineAlpha)
        return baselines.stat(.face, Self.faceArousalKey)?.median ?? observed
    }

    /// Emit a cross-channel congruence event (`.congruenceBreak` / `.arousalConsensus`)
    /// grounded in the voting channels' arousal signals, and narrate it. `channel` is
    /// nil (a cross-channel event has no single owner); evidence is the closed-vocabulary
    /// arousal `SignalRef` of each voter (so the narrator can cite only present signals).
    private func emitCongruenceEvent(_ kind: EventKind, state: CongruenceState, reading: EmotionReading) {
        let evidence = state.votes.keys
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap(Self.arousalSignal(for:))
        let voters = state.votes.values
        let meanReliability = voters.isEmpty ? 0
            : voters.reduce(0) { $0 + $1.reliability } / Double(voters.count)
        let consensus = state.consensus ?? 0
        let magnitude = kind == .congruenceBreak ? (1 - consensus) : consensus
        let event = AffectEvent(
            t: reading.date,
            channel: nil,
            kind: kind,
            magnitude: max(0, min(1, magnitude)),
            confidence: meanReliability,
            evidence: evidence,
            baselineDelta: nil
        )
        emit(event)
        appendInsight(TemplateNarrator.narrate(event, reading: reading))
    }

    /// The arousal `SignalRef` a channel contributes to a congruence event's evidence.
    /// Face → arousal, eyes → blink rate; the later arousal channels map to their own
    /// signals as they land. Non-arousal channels never vote, so never appear here.
    private static func arousalSignal(for channel: Channel) -> SignalRef? {
        switch channel {
        case .face: return .arousal
        case .eyes: return .blinkRate
        case .hands: return .gestureEnergy
        case .head: return .headMotionEnergy
        case .voice: return .vocalF0
        case .interaction, .context: return nil
        }
    }

    // MARK: - Fusion evaluation (US-C9, PRD v2 §4.2 / §7.3)

    /// The per-mode live state the fusion UI observes: availability + latched active +
    /// the latest fused output. Keyed by mode id; populated only for ENABLED modes (a
    /// disabled mode has no live state — its row shows the enable toggle). Published so
    /// the `FusionModesSection` chips/greying update live.
    private(set) var fusionStates: [String: FusionModeState] = [:]

    /// Stable id for the fusion-evaluation consumer on the fan-out (registered after
    /// congruence, before the recorder).
    static let fusionConsumerID = "hub.fusion"

    /// The LIVE `ConstructHysteresis` latch per enabled single-poled mode (the hub owns
    /// the mutable instance; the mode only supplies a fresh band+dwell). Observation-
    /// ignored — it advances every frame; the UI observes the published `fusionStates`.
    @ObservationIgnored private var fusionHysteresis: [String: ConstructHysteresis] = [:]

    /// The LIVE `CoupledPoleLatch` per enabled COUPLED mode (US-C11 F3) — the two-pole,
    /// mutually-exclusive, dead-banded latch driven by the fused SIGNED axis. Parallel to
    /// `fusionHysteresis`; a mode uses exactly one of the two (by its `CoupledFusionMode`
    /// conformance). Observation-ignored for the same reason.
    @ObservationIgnored private var coupledLatches: [String: CoupledPoleLatch] = [:]

    /// The LIVE `RollingLoad` window per enabled `VarianceReportingFusionMode` (US-D14a F2) —
    /// the Omnicept mean+variance buffer the hub advances each tick with the fused score to
    /// fill `FusionOutput.spread`. Parallel to `fusionHysteresis`; kept out of `fuse` so the
    /// mode stays pure. Observation-ignored — it advances every frame; the UI observes `spread`.
    @ObservationIgnored private var loadWindows: [String: RollingLoad] = [:]

    /// The face channel's latest reading, ENRICHED with the AU features fusion needs.
    /// `EmotionReading.asChannelReading()` deliberately leaves `features` empty (an
    /// `EmotionReading` doesn't carry the AU vector — it lives on `EmotionEngine.auVector`),
    /// so the hub — which DOES hold the engine — populates `features[.au4]` here at the
    /// projection boundary. Additive: `EmotionReading` and the engine are untouched, and
    /// only the AU keys `FeatureKey` actually declares (au4) that the vector actually has
    /// are copied.
    private func enrichedFaceReading() -> ChannelReading {
        var r = face.latest
        // Copy out the brow / lid AUs the fusion constructs read (F7 uses au4; F4 also needs
        // au1/au5/au7/au15 for its L1 brow-morphology step). `au4` is ALREADY pitch-corrected
        // upstream (`AUComputer.compute` with the head pitch; US-A0). Only the keys `FeatureKey`
        // declares that the vector actually holds are copied — additive, no engine change.
        for au: (ActionUnit, FeatureKey) in [(.au1, .au1), (.au4, .au4), (.au5, .au5), (.au7, .au7), (.au15, .au15)] {
            if let v = face.auVector[au.0] { r.features[au.1] = v }
        }
        // Inject the per-Persona expressive-separability score (§5.4) so a PURE fusion
        // `fuse(...)` — F1's low-expresser gate — can widen without reaching the hub.
        // Migrated / un-recalibrated face baselines read LOW here (MADs are the unknown
        // marker), so F1 defaults to its hedged/tentative regime until a fresh
        // calibration supplies a real spread — the honest default for F1.
        if let sep = baselines.separability(for: .face) {
            r.expressiveSeparability = sep
        }
        return r
    }

    /// The synthesized CONTEXT channel reading (US-C11, PRD v2 §3.7) — a fusion INPUT
    /// only, never a user-facing lens. Carries `sessionMinutes` (minutes since the
    /// analysis session began, from `sessionStart`) as the modifier F3 consumes for its
    /// fatigue accrual. Availability `.live` so a consuming construct always sees it, but
    /// it is deliberately absent from `enabledChannels`/`liveChannels`, so it never gates
    /// any construct's availability (context is a modifier, not a required channel).
    ///
    /// Thermal state is DEFERRED here on purpose: `ProcessInfo.thermalState` is trivially
    /// readable, but there is no consumer yet and the sensing governor (§8.5) is a later
    /// item — adding an unused feature would be scope this item doesn't own.
    private func synthesizedContextReading(at now: Date) -> ChannelReading {
        let minutes = sessionStart.map { max(0, now.timeIntervalSince($0)) / 60 } ?? 0
        return ChannelReading(
            channel: .context,
            date: now,
            availability: .live,
            quality: 1,
            valence: nil,
            arousal: nil,
            intensity: 0,
            features: [.sessionMinutes: minutes],
            posterior: nil
        )
    }

    /// Fan-out consumer: evaluate the enabled+available fusion modes for this frame.
    /// Nearly free while nothing is enabled (the default) — a single membership check
    /// short-circuits before any reading is assembled. Runs AFTER congruence so it sees
    /// the frame's consistent per-channel readings.
    ///
    /// For each ENABLED mode it resolves the designed `FusionAvailability`, and while
    /// `.available` runs `fuse`, advances the mode's `ConstructHysteresis` on the raw
    /// score, and publishes `FusionModeState`. On the ACTIVATION rising edge it emits a
    /// `.constructStateChanged` event + a narrated insight (the honesty grammar). The
    /// DEACTIVATION edge is deliberately QUIET — no event, no insight (the chip simply
    /// clears): a construct ending is not itself news, and narrating every clear would
    /// spam the feed. A mode that becomes unavailable drops its latch (`reset`), so
    /// re-establishing it demands a fresh enter-dwell rather than resuming stale.
    private func evaluateFusion(_ analysis: FrameAnalysis) {
        // Cheap short-circuit: with no mode enabled (the default) there is nothing to do.
        guard fusionRegistry.modes.contains(where: { fusionRegistry.isEnabled($0.id) }) else {
            if !fusionStates.isEmpty { fusionStates = [:] }
            if !fusionHysteresis.isEmpty { fusionHysteresis = [:] }
            if !coupledLatches.isEmpty { coupledLatches = [:] }
            if !loadWindows.isEmpty { loadWindows = [:] }
            return
        }

        // Assemble the readings for the ENABLED channels (face enriched with its AUs), plus
        // the synthesized CONTEXT modifier (fusion-input only, §3.7 — never gates
        // availability; a construct that doesn't read it simply ignores the extra key).
        var readings: [Channel: ChannelReading] = [.face: enrichedFaceReading()]
        if eyes.isEnabled { readings[.eyes] = eyes.latest }
        if interaction.isEnabled { readings[.interaction] = interaction.latest }
        // Hands flow into fusion inputs when enabled (US-D13a): F1's gestureEnergy /
        // selfTouchRate proxy sources (F1Composure.proxySources) light up automatically the
        // moment a live hands reading is present — no fusion-math change, exactly as the
        // proxy-source comment promised.
        if hands.isEnabled { readings[.hands] = hands.latest }
        // Head flows into fusion inputs when enabled (US-D13b): F1's headMotionEnergy proxy
        // source lights up automatically the moment a live head reading is present.
        if head.isEnabled { readings[.head] = head.latest }
        // Voice flows into fusion inputs when enabled (US-D12/US-D14b): F6's `recentLaughter`
        // corroboration + F5's vocal-F0 proxy read the voice reading the moment it's live.
        if voice.isEnabled { readings[.voice] = voice.latest }
        readings[.context] = synthesizedContextReading(at: analysis.date)

        let now = analysis.date
        for mode in fusionRegistry.modes {
            let id = mode.id
            guard fusionRegistry.isEnabled(id) else {
                if fusionStates[id] != nil { fusionStates.removeValue(forKey: id) }
                fusionHysteresis.removeValue(forKey: id)
                coupledLatches.removeValue(forKey: id)
                loadWindows.removeValue(forKey: id)
                continue
            }

            let availability = fusionRegistry.resolveAvailability(mode, hub: self)
            guard availability == .available, var output = mode.fuse(readings) else {
                // Designed unavailable / starved (or no fused output this tick): publish
                // the honest state, drop the latch (a dark channel deactivates cleanly).
                fusionHysteresis[id]?.reset()
                coupledLatches[id]?.reset()
                loadWindows[id]?.reset()
                publishFusionState(id, FusionModeState(output: nil, isActive: false, availability: availability))
                continue
            }

            // Advance the construct's latch and name the surfaced state ONLY once latched.
            // A COUPLED construct (F3) drives a two-pole `CoupledPoleLatch` on its signed
            // axis and surfaces the POLE; every other construct drives the single
            // `ConstructHysteresis` on the raw score and surfaces its title.
            let becameActive: Bool
            let isActive: Bool
            if let coupled = mode as? any CoupledFusionMode {
                var latch = coupledLatches[id] ?? coupled.coupledLatch
                let oldPole = latch.pole
                let pole = latch.update(axis: output.axis ?? 0)
                coupledLatches[id] = latch
                isActive = pole != .neutral
                // Fire on entry to a pole AND on a pole FLIP (each is news worth narrating).
                becameActive = isActive && pole != oldPole
                if isActive {
                    let sign = pole == .positive ? 1 : -1
                    output.namedState = coupled.poleName(forSign: sign) ?? mode.title
                }
            } else {
                var latch = fusionHysteresis[id] ?? mode.hysteresis
                let wasActive = latch.isActive
                isActive = latch.update(score: output.score)
                fusionHysteresis[id] = latch
                becameActive = isActive && !wasActive
                // Respect a fuse-provided named state (F2's "high effort/load", F4's hedged
                // lean), else fall back to the title; clear it while NOT latched so the
                // invariant "namedState non-nil ⟺ surfaced" holds for every construct (US-D14a).
                output.namedState = isActive ? (output.namedState ?? mode.title) : nil
            }

            // Variance (US-D14a F2): advance the per-mode rolling load window and fill `spread`
            // — the hub owns this temporal state (like the latches) so `fuse` stays pure. A
            // no-op for every construct that doesn't report variance (F1/F3/F4/F7).
            if let variance = mode as? any VarianceReportingFusionMode {
                var window = loadWindows[id] ?? RollingLoad(window: variance.spreadWindow)
                output.spread = window.record(output.score, at: now)
                loadWindows[id] = window
            }

            publishFusionState(id, FusionModeState(output: output, isActive: isActive, availability: .available))

            // Rising edge (or pole flip) → the auditable event + the narrated insight.
            // Falling edge to neutral: quiet (a construct ending is not itself news).
            if becameActive {
                emitConstructActivation(mode, output: output, at: now)
            }
        }
    }

    /// Republish a mode's state only when it actually changed (avoid observation churn;
    /// while active the live confidence legitimately drifts, so those updates DO flow).
    private func publishFusionState(_ id: String, _ state: FusionModeState) {
        if fusionStates[id] != state { fusionStates[id] = state }
    }

    /// Emit a `.constructStateChanged` for a construct that just latched active, grounded
    /// in its contributing `SignalRef`s, and narrate it (the M7 grammar: estimate +
    /// attribution + confound + confidence). `channel` is nil (a fused construct has no
    /// single owner). `magnitude` = the activation score (aleatoric), `confidence`
    /// separate (epistemic) — the two-signal split kept intact.
    private func emitConstructActivation(_ mode: any FusionMode, output: FusionOutput, at now: Date) {
        let event = AffectEvent(
            t: now,
            channel: nil,
            kind: .constructStateChanged,
            magnitude: max(0, min(1, output.score)),
            confidence: output.confidence,
            evidence: output.evidence,
            // Coupled constructs carry their SIGNED axis so the narrator can recover the pole;
            // a LEANING single-poled construct (F4) carries its discrete lean CODE instead
            // (US-D14a); every other single-poled construct leaves both nil (unchanged).
            baselineDelta: output.axis ?? output.leanCode,
            // Route the narrator by construct IDENTITY, not an evidence heuristic (US-C11).
            constructID: mode.id
        )
        emit(event)
        appendInsight(TemplateNarrator.narrate(event, reading: face.reading))
    }

    // MARK: - ESM ground-truth loop (US-E17, PRD v2 §5.7 / §5.4 / §9.1 M6)

    /// Submit a 1-tap self-report. SNAPSHOTS the live inferred reading AT REPORT TIME
    /// (before any await), attempts the Health write, then ALWAYS appends the local
    /// JSONL record — ground truth is never lost regardless of the Health outcome.
    ///
    /// ORDERING NOTE (append-only law): the Health attempt runs first ONLY so the record
    /// can be authored ONCE with the honest `healthSaved` flag — the append-only log
    /// forbids back-patching it later. `healthWriter.save` returns a result (never
    /// throws) and, in the common unavailable case, returns without suspending, so the
    /// unconditional `esm.append` below is what guarantees "local-first, never lost".
    func submitSelfReport(userValence: Double, labels: [QuickMood]) async {
        let now = Date()
        let reading = face.reading                       // report-time snapshot (value type)
        let health = await healthWriter.save(valence: userValence, labels: labels, date: now)

        let faceOK = reading.faceDetected
        let report = SelfReport(
            t: now,
            valence: max(-1, min(1, userValence)),
            labels: labels.map(\.rawValue),
            inferredValence: faceOK ? reading.valence : nil,
            inferredArousal: faceOK ? reading.arousal : nil,
            inferredConfidence: faceOK ? reading.confidence : nil,
            dominantEmotion: faceOK ? reading.dominant.rawValue : nil,
            inferredPosterior: faceOK ? reading.distribution : nil,
            healthSaved: health.didSaveToHealth
        )
        esm.append(report)                               // local JSONL — unconditional
        lastHealthResult = health
        esm.noteReportSubmitted(at: now)                 // reset the never-nag cooldown
        recomputeConformal()                             // the new label may unlock/refine the set
    }

    /// The calibrated conformal label set for a posterior, or `nil` while UNCALIBRATED
    /// (below the min-sample gate) — in which case the hero chip keeps its margin
    /// heuristic (`MultiLabelChip.topLabels`). The surgical source-switch for the chip.
    func conformalLabels(for distribution: EmotionDistribution) -> [Emotion]? {
        guard case let .calibrated(qhat, _) = conformalStatus else { return nil }
        return ConformalCalibrator.predict(distribution, qhat: qhat)
    }

    /// Per-user CCC between inferred valence and self-reported valence over the reports
    /// that carry BOTH (PRD §9.1 M6). `nil` under 3 paired reports.
    func valenceCCC() -> Double? {
        var inferred: [Double] = []
        var reported: [Double] = []
        for r in esm.reports {
            if let v = r.inferredValence {
                inferred.append(v)
                reported.append(r.valence)
            }
        }
        return Concordance.ccc(inferred, reported)
    }

    /// The count of reports that pair an inferred valence with a felt valence (drives the
    /// CCC copy's "over N paired reports").
    func pairedReportCount() -> Int {
        esm.reports.reduce(0) { $0 + ($1.inferredValence != nil ? 1 : 0) }
    }

    private func recomputeConformal() {
        conformalStatus = ConformalCalibrator.calibrate(ConformalCalibrator.pairs(from: esm.reports))
    }

    // MARK: - Thermal governor application (US-D13b, PRD v2 §8.1 / §8.5)

    /// True while the thermal governor has paused aux sensing (eyes / hands / voice / head)
    /// to shed heat (the `.critical` floor). Observed so a HUD can note the reduced state.
    private(set) var auxThermallyPaused = false

    /// The policy currently applied (starts at `.full` = today's behavior).
    @ObservationIgnored private var appliedSensingPolicy: SensingPolicy = .full

    /// Apply a `SensingPolicy` from the governor: the engine's face cadence + FER+ gate, the
    /// immersive poll rate, and the aux-channel gate. On a REAL policy change (and not the
    /// initial apply, `old == nil`) narrate ONE honest, non-alarming insight and emit a
    /// `.channelAvailabilityChanged`. At `.nominal` this is a no-op (byte-identical default);
    /// `.nominal`↔`.fair` share a policy, so no spurious notice fires for that transition.
    func applyThermalPolicy(_ policy: SensingPolicy,
                            changedFrom old: ProcessInfo.ThermalState?,
                            tier: ProcessInfo.ThermalState) {
        let previous = appliedSensingPolicy
        face.minProcessInterval = policy.faceInterval
        face.mlScoringEnabled = policy.ferPlusEnabled
        immersiveSensing.setPollHz(policy.immersivePollHz)
        setAuxThermalPaused(!policy.auxChannelsEnabled)
        appliedSensingPolicy = policy

        guard old != nil, policy != previous else { return }
        emitThermalNotice(policy: policy, tier: tier)
    }

    /// Pause / resume aux-channel processing (eyes / hands / voice / head). Idempotent.
    private func setAuxThermalPaused(_ paused: Bool) {
        guard paused != auxThermallyPaused else { return }
        auxThermallyPaused = paused
        eyes.setThermalPaused(paused)
        hands.setThermalPaused(paused)
        voice.setThermalPaused(paused)
        head.setThermalPaused(paused)
    }

    /// Emit + narrate the ONE honest governor notice for a real policy change: a
    /// non-alarming "eased back" line while reduced, or the "restored" line on recovery to
    /// full sensing. Banlist-clean copy (swept in `EmotionSelfTests.thermalGovernor()`).
    private func emitThermalNotice(policy: SensingPolicy, tier: ProcessInfo.ThermalState) {
        let restored = policy == .full
        let text = restored
            ? HonestyPhrases.thermalRestored
            : HonestyPhrases.thermalReduced(warmth: Self.thermalWarmthWord(for: tier))
        let event = AffectEvent(
            t: Date(), channel: nil, kind: .channelAvailabilityChanged,
            magnitude: restored ? 0 : 1, confidence: 1, evidence: [], baselineDelta: nil)
        emit(event)
        appendInsight(InsightEntry(id: event.id, t: event.t, text: text,
                                   kind: .channelAvailabilityChanged, evidence: [], confidence: 1))
    }

    /// A non-alarming warmth word for the reduced-sensing notice.
    private static func thermalWarmthWord(for tier: ProcessInfo.ThermalState) -> String {
        switch tier {
        case .critical: return "running hot"
        case .serious: return "warm"
        default: return "warming up"
        }
    }
}

#endif
