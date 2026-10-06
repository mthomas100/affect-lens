//
//  EmotionLensHomeView.swift
//  AffectLens
//
//  The Emotion tab home (US-B6, PRD v2 §6.8 "home = a lens GRID"). A compact
//  fusion-hero strip on top (reusing the existing hero — a proper cross-channel
//  congruence ring arrives in a later item) over a glanceable grid of lens cards.
//  Tap a card to focus:
//    • face        → the existing `EmotionDashboardView`, unchanged.
//    • eyes        → the first `ChannelLensView` instance (`EyesLensView`).
//    • hands/head/voice/interaction → an honest explainer (what it will read, why
//      it isn't available yet).
//
//  Camera lifecycle lives in `ContentView`: it starts the Persona feed (or a demo
//  video) and wires `engine.ingest`, so the hero + face card
//  are live the moment the tab is up, and focusing a lens never re-wires capture.
//
//  Honesty law (PRD §6.7): "from your Persona" everywhere; no emotion claim on any
//  non-face card; the three availability states are designed, never error toasts.
//

#if os(visionOS)

import SwiftUI

// MARK: - EmotionLensHomeView

struct EmotionLensHomeView: View {
    let hub: AffectHub
    let camera: CameraFeed

    /// The focused lens, or `nil` for the grid home. A manual swap (not a
    /// NavigationStack) so a focus view — the dense face dashboard especially — gets
    /// the full panel height instead of losing it to nav chrome.
    @State private var focused: Lens?

    /// Whether the ESM self-report sheet is presented (US-E17). Opened by the manual
    /// button or the shift banner.
    @State private var showingSelfReport = false

    /// Whether the never-interruptive shift banner is currently offered. Driven by the
    /// prompt-policy poll loop, not by `body`, so nothing mutates the model mid-render.
    @State private var pendingPrompt = false

    /// Foreground-only: stop golden-trace recording if the app backgrounds mid-record
    /// (a trace should never span a background gap; the fan-out pauses anyway).
    @Environment(\.scenePhase) private var scenePhase

    /// Detach the focused lens into the `lens-detail` window (US-lab, §6.8 detachable
    /// columns) — a cheap affordance covering every lens focus view at once.
    @Environment(\.openWindow) private var openWindow

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: .infinity), spacing: 14)]

    var body: some View {
        Group {
            if let lens = focused {
                focusContainer(lens)
            } else {
                home
            }
        }
        .onAppear {
            // Demo/screenshot hook: `-open-lens face` (or any `Lens` raw value) opens that
            // focus view at launch, e.g. for simulator captures driven by `-demo-video`.
            let args = ProcessInfo.processInfo.arguments
            if focused == nil, let i = args.firstIndex(of: "-open-lens"), i + 1 < args.count {
                focused = Lens(rawValue: args[i + 1])
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { hub.traceRecorder.stop() }
            // Foreground-only voice (US-D12): release the mic fully on background, resume
            // it on return if the lens is still enabled. Never an idle mic in the background.
            hub.voice.handleScenePhase(background: phase == .background)
        }
        // US-B8: sense manipulation of the Emotion tab's own controls (grid + focus
        // views) into the interaction lens. One attachment point, broad coverage; a
        // simultaneous gesture, so cards/toggles/buttons keep working. Gated internally
        // on the lens being enabled — zero collection when off.
        .interactionSensing(channel: hub.interaction)
    }

    // MARK: Home (hero strip + lens grid)

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroStrip
                TraceRecorderControl(recorder: hub.traceRecorder)
                // ESM ground-truth loop (US-E17): the never-interruptive shift banner
                // (only while eligible) + the always-available manual trigger, near the feed.
                if pendingPrompt {
                    ShiftPromptBanner(
                        onLog: { pendingPrompt = false; showingSelfReport = true },
                        onDismiss: { pendingPrompt = false })
                }
                HStack {
                    SelfReportButton { showingSelfReport = true }
                    Spacer(minLength: 0)
                }
                InsightFeedView(insights: hub.insights)
                lensGrid
                FusionModesSection(hub: hub)
                GroundTruthSection(hub: hub)
                FusedAuraToggle(interaction: hub.interaction)
            }
            .padding(4)
        }
        .sheet(isPresented: $showingSelfReport) {
            SelfReportSheet(hub: hub)
        }
        .task { await pollForSelfReportPrompt() }
    }

    /// Poll the ESM prompt policy (~2 s) and raise the banner when eligible — a state
    /// loop so nothing mutates the model from `body`. Consumes the pending shift on
    /// surface; the store's `EsmPromptPolicy` enforces the 60 s / 5 min cooldowns.
    private func pollForSelfReportPrompt() async {
        while !Task.isCancelled {
            if !pendingPrompt, !showingSelfReport, hub.esm.shouldSurfacePrompt(now: .now) {
                hub.esm.notePromptSurfaced(at: .now)
                pendingPrompt = true
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private var heroStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            CongruenceRingView(congruence: hub.congruence) {
                EmotionHeroView(reading: hub.face.reading,
                                conformalLabels: hub.conformalLabels(for: hub.face.reading.distribution))
            }
            Text("Fused affect summary — the ring shows cross-channel AROUSAL agreement (tight + bright = agree, wide + faint = diverging); enable a second lens to bring it to life. The dominant reading still mirrors the face lens.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var lensGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(Lens.allCases) { lens in
                LensCardView(lens: lens,
                             availability: lens.availability(in: hub),
                             hub: hub)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .hoverEffect()                       // system hover — privacy-safe (§6.8)
                    .onTapGesture { focused = lens }     // inner controls (eyes toggle) win their own taps
            }
        }
    }

    // MARK: Focus

    private func focusContainer(_ lens: Lens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { focused = nil } label: {
                    Label("Lenses", systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button { openWindow(id: "lens-detail", value: lens) } label: {
                    Label("Detach", systemImage: "rectangle.on.rectangle")
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }

            focusView(for: lens)
        }
    }

    @ViewBuilder
    private func focusView(for lens: Lens) -> some View {
        switch lens {
        case .face:
            EmotionDashboardView(engine: hub.face, eyes: hub.eyes, voice: hub.voice,
                                 hands: hub.hands, head: hub.head, coordinator: hub.immersiveSensing,
                                 interaction: hub.interaction,
                                 camera: camera, congruence: hub.congruence)
        case .eyes:
            EyesLensView(eyes: hub.eyes)
        case .interaction:
            InteractionLensView(interaction: hub.interaction)
        case .voice:
            VoiceLensView(voice: hub.voice, interaction: hub.interaction)
        case .hands:
            HandsLensView(hands: hub.hands, coordinator: hub.immersiveSensing,
                          interaction: hub.interaction)
        case .head:
            HeadLensView(head: hub.head, interaction: hub.interaction)
        }
    }
}

// MARK: - LensCardView

/// One glanceable lens card: icon + title + status badge, a live mini-state where
/// available (face: dominant emotion + confidence; eyes: blinks/min), an enable
/// toggle for eyes, and greyed + honest copy for the two unavailable states.
struct LensCardView: View {
    let lens: Lens
    let availability: LensAvailability
    let hub: AffectHub

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            miniState
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderColor, lineWidth: 1))
        .opacity(availability.isAvailable ? 1 : 0.6)   // greyed for the unavailable states
    }

    private var header: some View {
        HStack {
            Label(lens.title, systemImage: lens.systemImage)
                .font(.headline)
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch availability {
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .unavailableButEnableable:
            Image(systemName: "power.circle").foregroundStyle(.yellow).font(.caption)
        case .unavailable:
            Image(systemName: "lock.circle").foregroundStyle(.secondary).font(.caption)
        }
    }

    // Live mini-state where available; the honest scope otherwise.
    @ViewBuilder private var miniState: some View {
        if lens == .face {
            faceMini
        } else if lens == .eyes, availability.isAvailable {
            eyesMini
        } else if lens == .interaction, availability.isAvailable {
            interactionMini
        } else if lens == .voice, availability.isAvailable {
            voiceMini
        } else if lens == .hands, availability.isAvailable {
            handsMini
        } else if lens == .head, availability.isAvailable {
            headMini
        } else {
            Text(lens.scope)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var faceMini: some View {
        let r = hub.face.reading
        return HStack(spacing: 10) {
            Text(r.faceDetected ? r.dominant.emoji : "🔍")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.faceDetected ? r.dominant.displayName : "Looking for you…")
                    .font(.subheadline.bold())
                Text(r.faceDetected
                     ? "\(Int((r.confidence * 100).rounded()))% sure · from your Persona"
                     : "Expression estimate from your Persona")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var eyesMini: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye").font(.title3).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.0f blinks/min", hub.eyes.blinksPerMinute))
                    .font(.subheadline.bold().monospacedDigit())
                Text("attention / fatigue · from your Persona")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Live voice state — speaking flag + latest F0 (arousal-only framing).
    private var voiceMini: some View {
        HStack(spacing: 10) {
            Image(systemName: hub.voice.isSpeaking ? "waveform" : "waveform.slash")
                .font(.title3).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(hub.voice.isSpeaking
                     ? String(format: "%.0f Hz · speaking", hub.voice.latestVoicedF0 ?? 0)
                     : "listening…")
                    .font(.subheadline.bold().monospacedDigit())
                Text("arousal only · on-device")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Live hands state — tracked flag + motion energy (arousal / agitation framing).
    private var handsMini: some View {
        HStack(spacing: 10) {
            Image(systemName: hub.hands.tracked ? "hand.raised.fill" : "hand.raised")
                .font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(hub.hands.tracked
                     ? String(format: "%.2f m/s · moving", hub.hands.meanJointSpeed)
                     : "hands out of view…")
                    .font(.subheadline.bold().monospacedDigit())
                Text("agitation / load · immersive")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Live head state — tracked flag + source badge (dominance / approach framing).
    private var headMini: some View {
        HStack(spacing: 10) {
            Image(systemName: hub.head.tracked ? "person.bust.fill" : "person.bust")
                .font(.title3).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(hub.head.pose != nil
                     ? String(format: "%+.0f° pitch · %@", (hub.head.pose?.pitch ?? 0) * 180 / .pi,
                              hub.head.activeSource == .immersive6DoF ? "6DoF" : "windowed")
                     : "looking for your head…")
                    .font(.subheadline.bold().monospacedDigit())
                Text("dominance / approach · from your Persona")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Live tempo / starvation state, aged on a 1 Hz clock (no channel-side timer).
    private var interactionMini: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let s = hub.interaction.snapshot(at: context.date)
            HStack(spacing: 10) {
                Image(systemName: "hand.tap").font(.title3).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.isStarved ? "Waiting for input…"
                                     : String(format: "%.0f actions/min", s.inputTempo))
                        .font(.subheadline.bold().monospacedDigit())
                    Text(s.isStarved ? "not enough interaction yet"
                                     : "effort / engagement · this app’s controls")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // Enable CTA (eyes) / honest reason (not-yet-wired) / off-switch (eyes on).
    @ViewBuilder private var footer: some View {
        switch availability {
        case .available:
            if lens == .eyes { EyesEnableToggle(eyes: hub.eyes, interaction: hub.interaction) }
            if lens == .interaction { InteractionEnableToggle(interaction: hub.interaction) }
            if lens == .voice { VoiceEnableToggle(voice: hub.voice, interaction: hub.interaction) }
            if lens == .hands { HandsEnableToggle(hands: hub.hands, interaction: hub.interaction) }
            if lens == .head { HeadEnableToggle(head: hub.head, interaction: hub.interaction) }
        case .unavailableButEnableable(let cta):
            VStack(alignment: .leading, spacing: 6) {
                Text(cta).font(.caption2).foregroundStyle(.secondary)
                if lens == .eyes { EyesEnableToggle(eyes: hub.eyes, interaction: hub.interaction) }
                if lens == .interaction { InteractionEnableToggle(interaction: hub.interaction) }
                if lens == .voice { VoiceEnableToggle(voice: hub.voice, interaction: hub.interaction) }
                if lens == .hands { HandsEnableToggle(hands: hub.hands, interaction: hub.interaction) }
                if lens == .head { HeadEnableToggle(head: hub.head, interaction: hub.interaction) }
            }
        case .unavailable(let reason):
            Label(reason, systemImage: "clock.badge.exclamationmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var borderColor: Color {
        switch availability {
        case .available:
            return lens == .face ? Color.accentColor.opacity(0.4) : Color.cyan.opacity(0.35)
        case .unavailableButEnableable:
            return Color.yellow.opacity(0.25)
        case .unavailable:
            return Color.white.opacity(0.08)
        }
    }
}

/// The eyes enable switch, owning the `@AppStorage` flag so a card tap and the K2
/// HUD toggle always agree; re-registers the lens on the hub's fan-out on change. Also
/// notes the flip into the interaction lens (US-B8) so a rapid enable→disable of the
/// eyes lens registers as toggle churn — the note is dropped unless interaction is on.
private struct EyesEnableToggle: View {
    let eyes: EyeChannel
    let interaction: InteractionChannel
    @AppStorage(EyeChannel.enabledKey) private var enabled = false

    var body: some View {
        Toggle(isOn: $enabled) {
            Text(enabled ? "Eyes lens on" : "Enable eyes lens").font(.caption)
        }
        .toggleStyle(.switch)
        .onChange(of: enabled) { _, isOn in
            eyes.refreshEnabled()
            interaction.note(InteractionEvent(.toggle(id: "lens.eyes", isOn: isOn), at: Date()))
        }
    }
}

// MARK: - FusedAuraToggle (PRD v2 §6.4 — the toggleable fused aura)

/// A small control near the fusion section: flip it and the passthrough aura follows the
/// FUSED signals (hue = valence, pulse = combined arousal, dimness = uncertainty) instead
/// of the face alone. Off by default — the face-driven aura is byte-identical when off.
/// One honest line, no reward framing (the aura reflects the reading, it never praises it).
private struct FusedAuraToggle: View {
    /// Toggle churn feeds the interaction lens — the
    /// aura mode is an affect-surface toggle like every lens/fusion toggle. No-op while
    /// the interaction lens is off.
    let interaction: InteractionChannel
    @AppStorage(FusedAura.enabledKey) private var enabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $enabled) {
                Label(HonestyPhrases.auraFusedToggleLabel, systemImage: "circle.hexagongrid")
                    .font(.subheadline.bold())
            }
            .toggleStyle(.switch)
            .onChange(of: enabled) { _, isOn in
                interaction.note(InteractionEvent(.toggle(id: "aura.fusedMode", isOn: isOn), at: Date()))
            }
            Text(HonestyPhrases.auraFusedExplainer)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - TraceRecorderControl (golden-trace recording indicator, US-E15 / §6.8)

/// The record control for the golden-trace flight recorder. Idle: a small, quiet
/// "Record trace" button. Recording: a DISTINCT, prominent pill (a pulsing red dot —
/// deliberately NOT the OS green camera dot) with honest copy — "features & events
/// only, never pixels" — plus a live elapsed/frame counter and a clear Stop.
private struct TraceRecorderControl: View {
    let recorder: TraceRecorder

    var body: some View {
        Group {
            if recorder.isRecording {
                recordingPill
            } else {
                idleButton
            }
        }
    }

    private var idleButton: some View {
        HStack(spacing: 8) {
            Button {
                recorder.start()
            } label: {
                Label("Record trace", systemImage: "record.circle")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            Text("Golden trace — features & events only, never pixels")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var recordingPill: some View {
        HStack(spacing: 12) {
            // A pulsing red dot — distinct from the OS green recording dot.
            PulsingDot()
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording trace — features & events only, never pixels")
                    .font(.callout.bold())
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(statusLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                recorder.stop()
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.red.opacity(0.5), lineWidth: 1))
    }

    private var statusLine: String {
        let elapsed = recorder.startedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
        return "\(elapsed)s · \(recorder.tickCount) frames · Documents/GoldenTraces"
    }
}

/// A gently pulsing filled red dot for the recording indicator.
private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 12, height: 12)
            .shadow(color: .red.opacity(0.8), radius: 4)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - FusionModesSection (US-C9, PRD v2 §4.2 / §6.7)

/// The fusion-constructs list under the lens grid: one row per REGISTERED mode. Each is
/// off by default and self-explains (title + availability + toggle + live chip + an
/// expandable `RationalePanel` carrying the mechanism / named confound / citation /
/// confidence ceiling). Hidden entirely when nothing is registered.
struct FusionModesSection: View {
    let hub: AffectHub

    var body: some View {
        let modes = hub.fusionRegistry.modes
        if !modes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fusion constructs")
                        .font(.headline)
                    Text("Named cross-channel states no single lens can measure — each needs 2+ lenses and shows its mechanism, confound, and confidence. Off by default.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(modes, id: \.id) { mode in
                    FusionModeRow(mode: mode, hub: hub)
                }
            }
        }
    }
}

/// One fusion-construct row. Owns the `fusion.<id>.enabled` `@AppStorage` flag (so the
/// toggle and the hub's registry always agree), surfaces the live `FusionModeState` the
/// hub publishes (active chip / designed "needs …" copy — honestly greyed), and reveals
/// the mechanism/confound/citation/ceiling in a `RationalePanel`.
private struct FusionModeRow: View {
    let mode: any FusionMode
    let hub: AffectHub
    @AppStorage private var enabled: Bool

    init(mode: any FusionMode, hub: AffectHub) {
        self.mode = mode
        self.hub = hub
        _enabled = AppStorage(wrappedValue: false, FusionRegistry.enabledKey(mode.id))
    }

    private var state: FusionModeState? { hub.fusionStates[mode.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(mode.title, systemImage: "wand.and.stars")
                    .font(.subheadline.bold())
                Spacer()
                if let s = state, s.isActive, let out = s.output {
                    activeChip(out)
                }
            }

            Toggle(isOn: $enabled) {
                Text(enabled ? "On" : "Enable").font(.caption)
            }
            .toggleStyle(.switch)
            .onChange(of: enabled) { _, isOn in
                // Keep the registry in lock-step with the flag, and — like the lens
                // toggles — note the flip into the interaction lens so a rapid
                // enable→disable reads as toggle churn (dropped unless interaction is on).
                hub.fusionRegistry.setEnabled(mode.id, isOn)
                hub.interaction.note(InteractionEvent(.toggle(id: "fusion.\(mode.id)", isOn: isOn), at: Date()))
            }

            availabilityLine

            // The ONE coupled meter (US-C11): a single zero-centred bipolar bar for any
            // coupled construct (F3 fatigued⇄engaged, F8 contraction⇄expansion, F10
            // withdrawal⇄approach — US-D14b). The pole LABELS come from the mode's own
            // `poleName(forSign:)`. Shown whenever the mode publishes a signed axis; there is
            // NEVER a second meter (the PRD's law).
            if enabled, let out = state?.output, let axis = out.axis {
                let coupled = mode as? any CoupledFusionMode
                CoupledAxisBar(axis: axis,
                               negativeLabel: coupled?.poleName(forSign: -1) ?? "",
                               positiveLabel: coupled?.poleName(forSign: 1) ?? "",
                               pole: state?.isActive == true ? out.namedState : nil)
            }

            // The F2 mean + variance load meter (US-D14a): the score as a needle inside a
            // ±spread band — the Omnicept idiom, never a bare number. Shown whenever the mode
            // publishes a `spread` (only a `VarianceReportingFusionMode` — F2 — does).
            if enabled, let out = state?.output, let spread = out.spread {
                LoadMeterBar(mean: out.score, spread: spread)
            }

            // The disambiguation ladder (§6.6) — "show the app THINKING." Rendered when
            // the mode supplies rungs for the current live state (F1 always; F7 a minimal
            // 2-step; modes with no ladder fall back to just the RationalePanel).
            if enabled, let s = state {
                let steps = mode.ladder(for: s)
                if !steps.isEmpty {
                    DisambiguationLadderView(steps: steps)
                }
            }

            RationalePanel(mode: mode)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: 1))
        .opacity(enabled ? 1 : 0.7)
    }

    /// The live "<state> — <confidence word> confidence" chip. Confidence is a WORD,
    /// rendered separate from intensity (§5.4) — never a number glued to the score. A
    /// COUPLED construct (F3) shows its latched POLE ("engaged" / "alertness declining");
    /// every other construct shows "active".
    private func activeChip(_ out: FusionOutput) -> some View {
        // Coupled constructs (F3) show their latched POLE; a NAMED / leaning single-poled
        // construct (F2 "high effort/load", F4's hedged lean) shows that state; a plain
        // single-poled construct (F7/F1, whose namedState is just its title) reads "active".
        let label: String
        if out.axis != nil {
            label = out.namedState ?? "active"
        } else if let named = out.namedState, named != mode.title {
            label = named
        } else {
            label = "active"
        }
        return Text("\(label) · \(HonestyPhrases.confidenceWord(out.confidence)) confidence")
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.22), in: Capsule())
            .foregroundStyle(.orange)
    }

    /// The honest status line under the toggle — the designed availability copy.
    @ViewBuilder private var availabilityLine: some View {
        if !enabled {
            Label("Needs \(requiresList) — off by default.", systemImage: "square.stack.3d.up")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if let s = state {
            switch s.availability {
            case .available:
                if s.isActive {
                    EmptyView()   // the chip already says it
                } else {
                    Label("Watching for the state…", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .starved(let channel):
                Label(starvedCopy(channel), systemImage: "hand.raised.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .requiresChannel(let channel):
                Label("Enable the \(display(channel)) lens to run this construct.", systemImage: "power.circle")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            // Enabled but no tick evaluated yet (camera not running) — honest, not empty.
            Label("Needs \(requiresList).", systemImage: "square.stack.3d.up")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// The DESIGNED starvation copy (PRD §4.2 F7). Interaction gets its specific
    /// "use the controls" wording; any other starved channel gets an honest generic line.
    private func starvedCopy(_ channel: Channel) -> String {
        channel == .interaction
            ? "Needs interaction — use the app's controls for a while."
            : "Needs a live \(display(channel)) signal right now."
    }

    private var requiresList: String {
        mode.requires.map(display).sorted().joined(separator: " + ")
    }

    private func display(_ channel: Channel) -> String { channel.rawValue }

    private var borderColor: Color {
        guard enabled else { return Color.white.opacity(0.08) }
        if state?.isActive == true { return Color.orange.opacity(0.5) }
        if case .available = state?.availability { return Color.accentColor.opacity(0.3) }
        return Color.yellow.opacity(0.22)
    }
}

// MARK: - CoupledAxisBar (F3's ONE coupled meter, US-C11)

/// A single zero-centred BIPOLAR bar for ANY coupled construct (PRD v2 §4.2 F3, "NEVER two
/// meters — ONE coupled axis"). The knob rides a `[−1, +1]` signed axis; the two POLE labels
/// are handed in by the row (each coupled mode's `poleName(forSign:)`), so F3 (fatigued ⇄
/// engaged), F8 (contraction ⇄ expansion) and F10 (withdrawal ⇄ approach) all render honestly
/// from their OWN vocabulary. Pure presentation over the axis + labels the hub/mode publish;
/// it holds no state and makes no claims of its own (the latched pole label, when any, is
/// handed in as `pole`).
private struct CoupledAxisBar: View {
    /// −1 (negative pole) … 0 neutral … +1 (positive pole).
    let axis: Double
    /// The NEGATIVE-pole (left) label — the mode's `poleName(forSign: -1)`.
    let negativeLabel: String
    /// The POSITIVE-pole (right) label — the mode's `poleName(forSign: +1)`.
    let positiveLabel: String
    /// The latched pole label, or nil while neutral.
    let pole: String?

    private var leaningPositive: Bool { axis >= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(negativeLabel)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Text(positiveLabel)
                    .font(.caption2)
                    .foregroundStyle(.teal)
            }

            GeometryReader { geo in
                let w = geo.size.width
                let mid = w / 2
                let clamped = CGFloat(max(-1, min(1, axis)))
                let knobX = mid + clamped * mid
                ZStack {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 6)                              // the track
                    Rectangle()
                        .fill(.secondary.opacity(0.6))
                        .frame(width: 1.5, height: 14)
                        .position(x: mid, y: geo.size.height / 2)      // the zero tick
                    Circle()
                        .fill(leaningPositive ? Color.teal : Color.orange)
                        .frame(width: 14, height: 14)
                        .position(x: knobX, y: geo.size.height / 2)    // the signed knob
                }
            }
            .frame(height: 16)

            Text(pole ?? "No strong lean either way")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - LoadMeterBar (F2's mean + variance load meter, US-D14a)

/// A single horizontal load meter that renders the MEAN as a needle inside a translucent
/// ±SPREAD band (the HP-Omnicept "mean + variance" idiom, PRD v2 §4.2 F2 — never a bare
/// number). Pure presentation over the score + spread the hub publishes; it makes no claims
/// of its own, and its copy is effort/load only (never "stress").
private struct LoadMeterBar: View {
    /// The mean load, 0…1.
    let mean: Double
    /// The rolling standard deviation (the band half-width), 0…1.
    let spread: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("effort / load").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(pct(mean)) ± \(pct(spread))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let w = geo.size.width
                let m = CGFloat(min(1, max(0, mean)))
                let s = CGFloat(min(1, max(0, spread)))
                let lo = max(0, m - s), hi = min(1, m + s)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 6)                 // the track
                    Capsule()                                                    // the ±spread band
                        .fill(.orange.opacity(0.25))
                        .frame(width: max(2, (hi - lo) * w), height: 6)
                        .offset(x: lo * w)
                    Circle()                                                     // the mean needle
                        .fill(.orange)
                        .frame(width: 12, height: 12)
                        .offset(x: m * w - 6)
                }
            }
            .frame(height: 14)

            Text("An attention axis, not an emotion — the band is how much the reading is wobbling.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func pct(_ x: Double) -> String { "\(Int((min(1, max(0, x)) * 100).rounded()))%" }
}

#endif
