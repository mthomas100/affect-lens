//
//  EmotionDashboardView.swift
//  AffectLens
//
//  The emotion-recognition dashboard: live Persona preview with landmark
//  overlay and calibration flow on the left; hero readout, probability bars,
//  circumplex pad, and FACS meters on the right.
//

import SwiftUI

#if os(visionOS)
struct EmotionDashboardView: View {
    let engine: EmotionEngine
    /// The eyes / blink lens (US-B5). Drives the K2 HUD; observed live.
    let eyes: EyeChannel
    /// The voice lens (US-D12). Drives the K6 HUD (mic↔camera coexistence); observed live.
    let voice: VoiceChannel
    /// The hands lens (US-D13a). Drives the K1 HUD (HandTracking↔camera coexistence); observed live.
    let hands: HandsChannel
    /// The head lens (US-D13b). Drives the K3 instrument note (windowed pitch fidelity →
    /// the head channel's live pitch delta + source); observed live.
    let head: HeadChannel
    /// The immersive sensing coordinator (US-D13a). The K1 HUD reads its status + hands
    /// update Hz against `engine.processedFPS`.
    let coordinator: ImmersiveSensingCoordinator
    /// The interaction-dynamics lens: the K-HUD enable
    /// toggles note toggle churn into it — same ids as the home-grid card toggles, so a
    /// flip-back across the two surfaces still reads as one correction. No-op while the
    /// interaction lens is off (zero collection when off).
    let interaction: InteractionChannel
    let camera: CameraFeed
    /// The live cross-channel congruence read (US-C10a, §4.4) — drives the circumplex
    /// GHOST VOTES. `.insufficient` by default, so the pad renders exactly as before
    /// when no cross-channel story exists.
    var congruence: CongruenceState = .insufficient

    @State private var showScience = true
    @State private var vaTrail: [CGPoint] = []
    /// Live tuning for the AU4 pitch-correction slope (US-A0). Writes the same
    /// UserDefaults key the engine reads each frame, so the slider tunes it live.
    @AppStorage("au4.pitchCorrection.slope") private var au4Slope = PitchCorrection.defaultSlope
    /// The eyes-lens enable flag (US-B5, PRD law: off by default). Bound to the K2
    /// toggle; on change the hub re-registers the lens on the analysis fan-out.
    @AppStorage(EyeChannel.enabledKey) private var eyesEnabled = false
    /// The voice-lens enable flag (US-D12, off by default). Bound to the K6 toggle; on
    /// change the channel requests the mic and starts / stops the analyzer.
    @AppStorage(VoiceChannel.enabledKey) private var voiceEnabled = false
    /// The hands-lens enable flag (US-D13a, off by default). Bound to the K1 toggle.
    @AppStorage(HandsChannel.enabledKey) private var handsEnabled = false
    /// The head-lens enable flag (US-D13b, off by default). Bound to the K3 instrument note.
    @AppStorage(HeadChannel.enabledKey) private var headEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlBar
            HStack(alignment: .top, spacing: 14) {
                leftColumn
                    .frame(width: 440)
                rightColumn
                    .frame(minWidth: 500, maxWidth: .infinity)
            }
        }
        .padding(4)
        .onChange(of: engine.reading.date) { _, _ in
            let r = engine.reading
            guard r.faceDetected else { return }
            vaTrail.append(CGPoint(x: r.valence, y: r.arousal))
            if vaTrail.count > 40 { vaTrail.removeFirst(vaTrail.count - 40) }
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { @MainActor in
                    if camera.isRunning {
                        camera.stop()
                    } else {
                        try? await camera.start()
                    }
                }
            } label: {
                Label(camera.isRunning ? "Stop" : "Start", systemImage: camera.isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(camera.isRunning ? .red : .green)

            Button {
                engine.startCalibration()
            } label: {
                Label("Calibrate Neutral", systemImage: "face.dashed")
            }
            .disabled(!camera.isRunning)

            if engine.isCalibrated {
                Label("Calibrated", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Spacer()

            Toggle(isOn: $showScience) {
                Label("Science", systemImage: "waveform.path.ecg")
            }
            .toggleStyle(.button)

            Label(
                engine.appearanceModelActive ? "FACS + Neural fusion" : "FACS geometric engine",
                systemImage: "brain.head.profile"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Left column (preview + status + timeline)

    private var leftColumn: some View {
        VStack(spacing: 10) {
            ZStack {
                FrameView(pixelBuffer: camera.latestPixelBuffer)
                FaceLandmarkOverlay(overlay: engine.overlay, tint: engine.reading.dominant.color)
                if case .collecting(let progress) = engine.calibrationPhase {
                    CalibrationOverlay(progress: progress)
                }
            }
            .frame(width: 440, height: 248)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            statusRow
            EmotionTimelineView(samples: engine.history)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            Label(
                engine.reading.faceDetected ? "Face locked" : "No face",
                systemImage: engine.reading.faceDetected ? "faceid" : "questionmark.circle"
            )
            .font(.caption)
            .foregroundStyle(engine.reading.faceDetected ? Color.green : Color.secondary)

            Label(String(format: "%.0f Hz", engine.processedFPS), systemImage: "speedometer")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 5) {
                Text("Signal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ProgressView(value: engine.reading.quality)
                    .frame(width: 70)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Circumplex ghost votes (US-C10a, §6.2)

    /// The per-channel ghost votes for the pad. Shown ONLY when there is a real
    /// cross-channel story (≥2 voters); face-only renders EXACTLY as before (no ghosts).
    /// Face votes at its true circumplex position in its emotion hue; arousal-only
    /// channels (eyes) are AXIS MARKERS at their signed delta — never a fabricated
    /// valence. Each ghost's opacity is its live reliability r_k (the audit property).
    private var ghostVotes: [PadGhostVote] {
        guard congruence.votes.count >= 2 else { return [] }
        var out: [PadGhostVote] = []
        if let fv = congruence.votes[.face] {
            out.append(PadGhostVote(channel: .face,
                                    valence: engine.reading.valence,
                                    arousal: engine.reading.arousal,
                                    reliability: fv.reliability,
                                    tint: engine.reading.dominant.color))
        }
        if let ev = congruence.votes[.eyes] {
            out.append(PadGhostVote(channel: .eyes,
                                    valence: nil,                          // arousal-only ⇒ axis marker
                                    arousal: ev.signedArousalDelta,
                                    reliability: ev.reliability,
                                    tint: .cyan))
        }
        return out
    }

    // MARK: - Arousal quantile dotplot (§6.5 — the honest wide axis)

    /// σ at zero confidence for the arousal dotplot's spread. Visual-only arousal is a wide,
    /// low-agreement axis (CCC ≈ 0.26), so at zero confidence the dots fan across most of
    /// [−1, 1]; at full confidence the spread collapses to a tight cluster at the estimate.
    private static let arousalUncertaintyScale = 0.6

    /// Face arousal as a QUANTILE DOTPLOT rather than a single over-precise value — ~15 dots
    /// whose spread is a RENDERING of `(1 − confidence) × scale` (a display of the reading's
    /// uncertainty, NOT a new measurement).
    private var arousalDotplot: some View {
        let r = engine.reading
        let conf = r.faceDetected ? r.confidence : 0
        let spread = (1 - conf) * Self.arousalUncertaintyScale
        return VStack(alignment: .leading, spacing: 4) {
            Text(HonestyPhrases.arousalWideAxisTitle)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            QuantileDotplot(center: r.faceDetected ? r.arousal : 0,
                            spread: spread,
                            range: -1...1,
                            dotCount: 15,
                            tint: r.dominant.color)
                .frame(height: 44)
            Text(HonestyPhrases.arousalWideAxisCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Right column (readouts)

    private var rightColumn: some View {
        VStack(spacing: 12) {
            EmotionHeroView(reading: engine.reading)
            EmotionBarsView(
                distribution: engine.reading.distribution,
                intensities: engine.reading.intensities
            )
            HStack(alignment: .top, spacing: 12) {
                ValenceArousalPadView(
                    valence: engine.reading.valence,
                    arousal: engine.reading.arousal,
                    trail: vaTrail,
                    color: engine.reading.dominant.color,
                    ghostVotes: ghostVotes
                )
                .frame(width: 215, height: 215)

                if showScience {
                    AUMetersView(au: engine.auVector)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                        Text("Turn on Science to watch the FACS Action Units driving each classification.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            arousalDotplot
            pitchCorrectionHUD
            eyesHUD
            voiceHUD
            handsHUD
        }
    }

    // MARK: - Hands lens debug HUD (US-D13a, the K1 keystone instrument)

    /// The K1 keystone HUD: proves `HandTrackingProvider` COEXISTS with the running Persona
    /// camera. Shows the face pipeline's `processedFPS` SIDE-BY-SIDE with the measured hands
    /// update rate + the coordinator status line (idle / starting / running / unsupported /
    /// auth-denied / failed) — the exact instrument for the K1 check. Hands run only while the
    /// immersive aura space is open; in the simulator the provider is unsupported, so the HUD
    /// reads that honestly. Neutral copy, arousal-only framing, NO valence / emotion claim.
    private var handsHUD: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $handsEnabled) {
                    Label("Enable hands lens", systemImage: "hand.raised")
                        .font(.caption)
                }
                .onChange(of: handsEnabled) { _, isOn in
                    hands.refreshEnabled()
                    interaction.note(InteractionEvent(.toggle(id: "lens.hands", isOn: isOn), at: Date()))
                }

                // THE K1 coexistence readout — face FPS beside the hands update rate.
                HStack(spacing: 18) {
                    pitchMetric("Face", String(format: "%.0f Hz", engine.processedFPS))
                    pitchMetric("Hands", String(format: "%.0f Hz", coordinator.handsUpdateHz))
                    pitchMetric("Signal", hands.availability.rawValue.capitalized)
                }

                // Coordinator status line — the auth / provider / running / reason evidence.
                HStack(spacing: 6) {
                    Circle()
                        .fill(coordinatorDotColor)
                        .frame(width: 7, height: 7)
                    Text(coordinator.status.label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if handsEnabled {
                    HStack(spacing: 18) {
                        pitchMetric("Energy", String(format: "%.2f m/s", hands.meanJointSpeed))
                        pitchMetric("Aperture", hands.handAperture.map { String(format: "%.2f", $0) } ?? "—")
                        pitchMetric("Tracked", hands.tracked ? "yes" : "no")
                    }
                    HStack(spacing: 18) {
                        pitchMetric("Self-touch/min", String(format: "%.0f", hands.selfTouchRate))
                        pitchMetric("Gestures/min", String(format: "%.0f", hands.gestureRate))
                        pitchMetric("Head anchor", coordinator.deviceAnchorSeen ? "yes" : "no")
                    }
                    Text("K1: HandTracking running ALONGSIDE the Persona camera — watch that face Hz stays ~15 while hands stream. On-device hand-motion energy → arousal, measured against your resting baseline; self-touch is a rate, never a single gesture. No gesture dictionary." +
                         (hands.restingLearned ? "" : "  (* hands baseline still learning.)"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Off by default. Enable + open the immersive aura space to run the K1 keystone — HandTracking alongside the live camera. Hands don't run in the simulator (provider unsupported).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Hands (K1)", systemImage: "hand.raised")
                .font(.caption)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Green while the coordinator is running (K1 pass state); orange otherwise.
    private var coordinatorDotColor: Color {
        coordinator.status == .running ? .green : .orange
    }

    // MARK: - Voice / prosody lens debug HUD (US-D12, the K6 keystone instrument)

    /// The K6 keystone HUD: proves the mic tap COEXISTS with the running camera and that
    /// DIY prosody is legible. Enable toggle, an engine-status line (running / failed
    /// reason — the coexistence evidence), live F0 / level / voiced flag / arousal, and a
    /// laughter tick counter. Neutral copy, arousal-only framing, NO valence/emotion claim.
    private var voiceHUD: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $voiceEnabled) {
                    Label("Enable voice lens", systemImage: "waveform")
                        .font(.caption)
                }
                .onChange(of: voiceEnabled) { _, isOn in
                    voice.refreshEnabled()
                    interaction.note(InteractionEvent(.toggle(id: "lens.voice", isOn: isOn), at: Date()))
                }

                // Engine-status line — the K6 coexistence evidence.
                HStack(spacing: 6) {
                    Circle()
                        .fill(voice.engineRunning ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(voiceEngineStatus)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if voiceEnabled {
                    HStack(spacing: 18) {
                        pitchMetric("F0", voice.latestVoicedF0.map { String(format: "%.0f Hz", $0) } ?? "—")
                        pitchMetric("Level", String(format: "%.3f", voice.currentLevel))
                        pitchMetric("Voiced", voice.isSpeaking ? "yes" : "no")
                    }
                    HStack(spacing: 18) {
                        pitchMetric("F0 median", voice.f0Median.map { String(format: "%.0f", $0) } ?? "—")
                        pitchMetric("Arousal", voice.arousal.map { String(format: "%.2f", $0.value) } ?? "—")
                        pitchMetric("Laughs", "\(voice.laughterCount)")
                    }
                    Text("K6: mic tap running ALONGSIDE the Persona camera. On-device DIY vDSP/YIN prosody → arousal only; blinks are speech-gated while voiced. Never words, never valence." +
                         (voice.baselineLearned ? "" : "  (* voice baseline still learning.)"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Off by default. Enable to run the K6 keystone — a mic tap alongside the live camera, DIY prosody → arousal. Foreground-only; the mic is released when off.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Voice / prosody (K6)", systemImage: "waveform")
                .font(.caption)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The K6 engine-status string (running / mic-denied / failed reason / starting).
    private var voiceEngineStatus: String {
        if voice.engineRunning { return "engine running · mic + camera coexisting" }
        if voice.micDenied { return "mic denied — enable in Settings" }
        if let reason = voice.startFailureReason { return "stopped — \(reason)" }
        return voiceEnabled ? "starting…" : "engine stopped"
    }

    // MARK: - Eyes / blink lens debug HUD (US-B5, the K2 keystone instrument)

    /// The K2 keystone HUD: a collapsible "Persona" blink instrument — enable toggle,
    /// rolling blinks/min, blink ticks, live openness vs. its per-user baseline, and
    /// a prolonged-closure indicator. Neutral copy, "Persona" framing, NO emotion
    /// claims: K2 answers only "does blink rate rise legibly under forced arousal?"
    private var eyesHUD: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $eyesEnabled) {
                    Label("Enable eyes lens", systemImage: "eye")
                        .font(.caption)
                }
                .onChange(of: eyesEnabled) { _, isOn in
                    eyes.refreshEnabled()
                    interaction.note(InteractionEvent(.toggle(id: "lens.eyes", isOn: isOn), at: Date()))
                }

                if eyesEnabled {
                    HStack(spacing: 18) {
                        pitchMetric("Blinks/min", String(format: "%.0f", eyes.blinksPerMinute))
                        pitchMetric("Resting", String(format: "%.0f%@", eyes.restingBlinkRate,
                                                      eyes.restingLearned ? "" : "*"))
                        pitchMetric("Signal", eyes.availability.rawValue.capitalized)
                    }
                    HStack(spacing: 18) {
                        pitchMetric("Openness",
                                    eyes.currentOpenness.map { String(format: "%.3f", $0) } ?? "—")
                        pitchMetric("Baseline",
                                    eyes.openBaseline.map { String(format: "%.3f", $0) } ?? "—")
                        pitchMetric("Quality", String(format: "%.0f%%", eyes.quality * 100))
                    }

                    // Blink "ticks": one mark per counted blink this session (capped).
                    HStack(spacing: 2) {
                        Text("Ticks")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .leading)
                        ForEach(0..<min(eyes.sessionBlinkCount, 40), id: \.self) { _ in
                            Capsule()
                                .fill(Color.cyan.opacity(0.8))
                                .frame(width: 2, height: 12)
                        }
                        if eyes.sessionBlinkCount > 40 {
                            Text("+\(eyes.sessionBlinkCount - 40)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    if eyes.prolongedClosure {
                        Label("Prolonged closure (PERCLOS)", systemImage: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text("Reads blink rate from your Persona's eye openness. Attention/fatigue signal; blink rate alone is directionally ambiguous. Not an emotion readout." +
                         (eyes.restingLearned ? "" : "  (* resting rate still using the ~15–20/min literature default.)"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Off by default. Enable to watch rolling blinks/min from your Persona — the K2 legibility check (does blink rate rise under forced arousal?).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Eyes / blink (K2)", systemImage: "eye")
                .font(.caption)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - AU4 pitch-correction debug HUD (US-A0)

    /// Compact, collapsible K3/K4 tuning panel: live Persona pitch, AU4 raw vs
    /// pitch-corrected, and a slope slider. A fuller Lab Mode arrives later.
    private var pitchCorrectionHUD: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let d = engine.pitchDebug {
                    HStack(spacing: 18) {
                        pitchMetric("Pitch", String(format: "%.1f°", d.pitch * 180 / .pi))
                        pitchMetric("AU4 raw", String(format: "%.2f", d.au4Raw))
                        pitchMetric("AU4 corrected", String(format: "%.2f", d.au4Corrected))
                    }
                } else {
                    Text("No Persona pitch yet — look toward the camera.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("Slope")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Slider(value: $au4Slope, in: 0...3)
                    Text(String(format: "%.2f", au4Slope))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                Text("Discounts the pitch-induced brow-lower from the Persona's AU4, so looking down no longer mimics a frown.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // K3 instrument note (US-D13b): the SAME windowed pitch feeds the head
                // channel's dominance/approach read — surface its live pitch delta + source
                // so K3 (windowed-pitch fidelity) is legible against the head lens.
                Divider().opacity(0.4)
                Toggle(isOn: $headEnabled) {
                    Label("Enable head lens", systemImage: "person.bust")
                        .font(.caption)
                }
                .onChange(of: headEnabled) { _, isOn in
                    head.refreshEnabled()
                    interaction.note(InteractionEvent(.toggle(id: "lens.head", isOn: isOn), at: Date()))
                }
                if headEnabled {
                    HStack(spacing: 18) {
                        pitchMetric("Head pitch Δ", String(format: "%+.0f°", head.pitchDelta * 180 / .pi))
                        pitchMetric("Source", headSourceLabel)
                        pitchMetric("Signal", head.availability.rawValue.capitalized)
                    }
                    Text("K3: windowed pitch driving the head lens' dominance/approach read (never valence). Immersive-open swaps in the 6DoF source; head-down + turned-away only reads withdrawal — a straight look-down stays neutral (we can't see gaze)." +
                         (head.neutralLearned ? "" : "  (* neutral head pose still learning.)"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("AU4 pitch-correction · head (K3)", systemImage: "arrow.down.forward.and.arrow.up.backward")
                .font(.caption)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The head channel's active-source label for the K3 instrument note.
    private var headSourceLabel: String {
        switch head.activeSource {
        case .immersive6DoF: return "6DoF"
        case .windowed: return "windowed"
        case .none: return "—"
        }
    }

    private func pitchMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }
}

/// Dimmed overlay with a progress ring shown while the neutral baseline is captured.
struct CalibrationOverlay: View {
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: max(0.001, progress))
                        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.bold())
                        .contentTransition(.numericText())
                }
                .frame(width: 64, height: 64)

                Text("Calibrating your neutral face")
                    .font(.headline)
                Text("Relax and look toward the camera")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.smooth(duration: 0.2), value: progress)
    }
}
#endif
