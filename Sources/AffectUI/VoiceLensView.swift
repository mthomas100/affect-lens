//
//  VoiceLensView.swift
//  AffectLens
//
//  The VOICE lens UI (US-D12, PRD v2 §3.5) — the view side of the arousal-only
//  `VoiceChannel`. Three parts:
//    1. `VoiceEnableToggle` — the mic-aware enable switch (shared by the lens card and
//       focus view). On enable it kicks the channel's request-mic → start-analyzer flow.
//    2. `VoiceLensView` — the 3-strata focus view (RAW live level + F0 sparkline /
//       FEATURES F0-intensity-tempo delta meters / INTERPRETATION: ONE arousal meter +
//       the honesty paragraph). Reads the channel's published state only.
//
//  Honesty law (PRD §3.5 / §6.7): AROUSAL ONLY — the interpretation copy comes from
//  `HonestyPhrases` and NEVER infers valence or a discrete emotion from the voice; the
//  on-device guarantee is stated plainly. No words, ever.
//

#if os(visionOS)

import SwiftUI

// MARK: - VoiceEnableToggle (shared, mic-aware enable switch)

/// The voice enable switch, owning the `@AppStorage` flag so a card tap and the focus
/// view (and the K6 HUD) always agree. On change it drives the channel's enable flow
/// (request mic → start analyzer, or stop + release the mic), then notes its own flip
/// into the interaction lens so a rapid enable→disable reads as toggle churn (dropped
/// unless interaction is on).
struct VoiceEnableToggle: View {
    let voice: VoiceChannel
    let interaction: InteractionChannel
    @AppStorage(VoiceChannel.enabledKey) private var enabled = false

    var body: some View {
        Toggle(isOn: $enabled) {
            Text(enabled ? "Voice lens on" : "Enable voice lens").font(.caption)
        }
        .toggleStyle(.switch)
        .onChange(of: enabled) { _, isOn in
            voice.refreshEnabled()
            interaction.note(InteractionEvent(.toggle(id: "lens.voice", isOn: isOn), at: Date()))
        }
    }
}

// MARK: - VoiceLensView (the 3-strata focus view)

/// The voice lens focus view. Off → an enable prompt (mic-aware); on → the 3-strata
/// scaffold driven by the live `VoiceChannel`, with a locally-accumulated level / F0
/// trace for the raw sparkline (no channel change).
struct VoiceLensView: View {
    let voice: VoiceChannel
    let interaction: InteractionChannel
    @AppStorage(VoiceChannel.enabledKey) private var enabled = false

    @State private var levelTrace: [Double] = []
    @State private var f0Trace: [Double] = []

    private static let traceCap = 90

    var body: some View {
        Group {
            if enabled { lens } else { enablePrompt }
        }
        .onChange(of: voice.currentLevel) { _, v in
            levelTrace.append(v)
            if levelTrace.count > Self.traceCap { levelTrace.removeFirst(levelTrace.count - Self.traceCap) }
        }
        .onChange(of: voice.latestVoicedF0) { _, new in
            guard let f0 = new else { return }
            f0Trace.append(f0)
            if f0Trace.count > Self.traceCap { f0Trace.removeFirst(f0Trace.count - Self.traceCap) }
        }
    }

    private var lens: some View {
        ChannelLensView(title: "Voice",
                        systemImage: "waveform",
                        scope: Lens.voice.scope) {
            rawStrata
        } features: {
            featuresStrata
        } interpretation: {
            interpretationStrata
        }
    }

    // MARK: RAW — live mic level + F0 sparkline

    private var rawStrata: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Live level meter.
            HStack(spacing: 8) {
                Image(systemName: voice.isSpeaking ? "waveform" : "waveform.slash")
                    .foregroundStyle(voice.isSpeaking ? .green : .secondary)
                ProgressView(value: min(1, voice.currentLevel / 0.2))
                    .tint(voice.isSpeaking ? .green : .gray)
                Text(voice.isSpeaking ? "voiced" : "silent")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }

            // F0 sparkline (voiced pitch over the recent window).
            Canvas { ctx, size in
                guard f0Trace.count > 1 else { return }
                let lo = 60.0, hi = 500.0
                func y(_ v: Double) -> CGFloat {
                    let t = (min(hi, max(lo, v)) - lo) / (hi - lo)
                    return size.height * (1 - CGFloat(t))
                }
                var line = Path()
                let n = f0Trace.count
                for (i, v) in f0Trace.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(max(1, n - 1))
                    let pt = CGPoint(x: x, y: y(v))
                    if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                }
                ctx.stroke(line, with: .color(.teal), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            .frame(height: 60)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 18) {
                metric("F0", voice.latestVoicedF0.map { String(format: "%.0f Hz", $0) } ?? "—")
                metric("Level", String(format: "%.3f", voice.currentLevel))
                metric("Signal", voice.availability.rawValue.capitalized)
            }

            Text("Raw mic level and voiced pitch (F0), computed on-device via DIY vDSP/YIN. The unprocessed prosody signal — collapsed by default. Never your words.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: FEATURES — Δ-from-baseline meters

    private var featuresStrata: some View {
        let f = voice.reading.features
        let f0Delta = f[.vocalF0] ?? 0
        let intDelta = f[.vocalIntensity] ?? 0
        let tempo = f[.vocalTempo] ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            LensFeatureMeter(
                title: "Pitch (F0) Δ",
                valueText: String(format: "%+.0f Hz  (rest %.0f%@)",
                                  f0Delta, voice.f0Median ?? 0, voice.baselineLearned ? "" : "*"),
                fraction: min(1, abs(f0Delta) / VoiceChannel.f0DeltaScale),
                tint: .teal
            )
            LensFeatureMeter(
                title: "Loudness Δ",
                valueText: String(format: "%+.3f%@", intDelta, voice.baselineLearned ? "" : "*"),
                fraction: min(1, abs(intDelta) / VoiceChannel.intensityDeltaScale),
                tint: .mint
            )
            LensFeatureMeter(
                title: "Vocal tempo (voiced onsets/s)",
                valueText: String(format: "%.1f/s", tempo),
                fraction: min(1, tempo / 4),
                tint: .cyan
            )
            if !voice.baselineLearned {
                Text("* your voice baseline is still learning from speech — deltas use a literature default until it matures, so confidence is held low.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: INTERPRETATION — ONE arousal meter + ambiguity + can/can't

    private var interpretationStrata: some View {
        VStack(alignment: .leading, spacing: 12) {
            LensMeterGauge(label: "Arousal (from your voice — activation level)", meter: voice.arousal)

            VStack(alignment: .leading, spacing: 6) {
                Label("A level, not a direction", systemImage: "arrow.triangle.branch")
                    .font(.caption.bold())
                Text(HonestyPhrases.voiceAmbiguity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("What this can / can't tell you").font(.caption.bold())
                Text(HonestyPhrases.voiceScope)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label(HonestyPhrases.voiceOnDevice, systemImage: "lock.shield")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Off state

    private var enablePrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: voice.micDenied ? "mic.slash" : "waveform")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Voice lens is off")
                .font(.headline)
            Text(voice.micDenied
                 ? "Microphone access is off. Turn it on in Settings, then enable this lens to read vocal arousal on-device."
                 : "Enable to read vocal arousal on-device — pitch, loudness and tempo, routed into arousal only. Audio never leaves the device and no words are recognized.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            VoiceEnableToggle(voice: voice, interaction: interaction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

#endif
