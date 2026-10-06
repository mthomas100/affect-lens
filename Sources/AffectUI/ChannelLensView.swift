//
//  ChannelLensView.swift
//  AffectLens
//
//  The reusable 3-strata channel-lens scaffold (US-B6, PRD v2 §6.1) and its first
//  instantiation — the EYES lens. Every lens presents the same three strata:
//    1. RAW stream       — the live signal, straight through. Collapsible; default
//                          COLLAPSED (interpretation is what matters at a glance).
//    2. FEATURES         — delta-from-baseline meters (the AU-meters ProgressView
//                          idiom, reused).
//    3. INTERPRETATION   — 1–2 calibrated, low-dimensional meters, each with a
//                          confidence band, an ambiguity label, and a persistent
//                          "what this can / can't tell you" paragraph. Always visible.
//
//  Honesty law (PRD §6.7): Persona framing throughout; the eyes lens speaks only in
//  attention / fatigue terms and renders blink's directional ambiguity as a
//  designed, forked state — never an emotion claim.
//

#if os(visionOS)

import SwiftUI

// MARK: - ChannelLensView (the generic 3-strata scaffold)

/// Generic over its three strata's content. `RAW` is wrapped in a collapsible
/// disclosure (default collapsed); `FEATURES` and `INTERPRETATION` are always shown.
struct ChannelLensView<Raw: View, Features: View, Interpretation: View>: View {
    let title: String
    let systemImage: String
    /// One-line honest scope (Persona framing).
    let scope: String

    private let raw: Raw
    private let features: Features
    private let interpretation: Interpretation

    @State private var rawExpanded = false

    init(title: String,
         systemImage: String,
         scope: String,
         @ViewBuilder raw: () -> Raw,
         @ViewBuilder features: () -> Features,
         @ViewBuilder interpretation: () -> Interpretation) {
        self.title = title
        self.systemImage = systemImage
        self.scope = scope
        self.raw = raw()
        self.features = features()
        self.interpretation = interpretation()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                // RAW — collapsible, default collapsed.
                strata("Raw stream", subtitle: "the live signal, straight through") {
                    DisclosureGroup(isExpanded: $rawExpanded) {
                        raw.padding(.top, 8)
                    } label: {
                        Text(rawExpanded ? "Hide raw stream" : "Show raw stream")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // FEATURES — always visible.
                strata("Features", subtitle: "Δ from your Persona baseline") {
                    features
                }

                // INTERPRETATION — always visible.
                strata("Interpretation", subtitle: "calibrated, with confidence & ambiguity") {
                    interpretation
                }
            }
            .padding(4)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.title3.bold())
            Text(scope)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func strata<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.footnote.bold())
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Small strata building blocks

/// A delta-from-baseline feature meter (the AU-meters ProgressView idiom).
struct LensFeatureMeter: View {
    let title: String
    let valueText: String
    /// 0…1 bar fill (typically |Δ| normalized to the feature's dynamic range).
    let fraction: Double
    var tint: Color = .cyan

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer(minLength: 6)
                Text(valueText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, fraction)))
                .tint(tint)
        }
    }
}

/// A `Meter`-driven interpretation gauge: magnitude bar + confidence. The shared meter
/// the lens views render — its fill runs through `Color.vsup`, so it DESATURATES + COARSENS
/// as confidence falls (VSUP, Correll/Moritz/Heer 2018: less certain ⇒ less vivid). At full
/// confidence the fill is the same vivid cyan as before.
struct LensMeterGauge: View {
    let label: String
    let meter: Meter?

    /// The vivid cyan the fill desaturates FROM (h, s, b) as confidence falls.
    private static let cyanBase: (h: Double, s: Double, b: Double) = (0.5, 0.8, 0.9)

    var body: some View {
        let value = min(1, max(0, meter?.value ?? 0))
        let conf = min(1, max(0, meter?.confidence ?? 0))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold())
                Spacer(minLength: 6)
                Text(meter == nil ? "—" : "conf \(Int((conf * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(Color.vsup(Self.cyanBase, confidence: conf))
                        .frame(width: max(3, geo.size.width * value))
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - EYES lens (the first ChannelLensView instantiation, PRD §3.2)

/// The eyes / blink lens focus view. Off → an enable prompt; on → the 3-strata
/// scaffold driven by the live `EyeChannel`. Reads the channel's published state
/// only (no `EyeChannel` change); accumulates a short openness trace locally for the
/// raw sparkline.
struct EyesLensView: View {
    let eyes: EyeChannel
    @AppStorage(EyeChannel.enabledKey) private var enabled = false
    @State private var opennessTrace: [Double] = []

    private static let arousalDeltaScale = 12.0   // matches EyeChannel's mapping

    var body: some View {
        Group {
            if enabled {
                lens
            } else {
                enablePrompt
            }
        }
        .onChange(of: eyes.currentOpenness) { _, new in
            guard let v = new else { return }
            opennessTrace.append(v)
            if opennessTrace.count > 90 { opennessTrace.removeFirst(opennessTrace.count - 90) }
        }
    }

    private var lens: some View {
        ChannelLensView(title: "Eyes / blink",
                        systemImage: "eye",
                        scope: Lens.eyes.scope) {
            rawStrata
        } features: {
            featuresStrata
        } interpretation: {
            interpretationStrata
        }
    }

    // MARK: RAW — openness trace + blink ticks

    private var rawStrata: some View {
        VStack(alignment: .leading, spacing: 10) {
            Canvas { ctx, size in
                guard opennessTrace.count > 1 else { return }
                let base = eyes.openBaseline ?? (opennessTrace.max() ?? 0.3)
                let maxV = max(opennessTrace.max() ?? base, base) * 1.2
                guard maxV > 0 else { return }
                func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat(v / maxV)) }

                // Per-user open-eye baseline (dashed).
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: y(base)))
                baseline.addLine(to: CGPoint(x: size.width, y: y(base)))
                ctx.stroke(baseline, with: .color(.gray.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                // Openness trace.
                var line = Path()
                let n = opennessTrace.count
                for (i, v) in opennessTrace.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(max(1, n - 1))
                    let pt = CGPoint(x: x, y: y(v))
                    if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                }
                ctx.stroke(line, with: .color(.cyan),
                           style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            .frame(height: 70)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 2) {
                Text("Blinks")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 52, alignment: .leading)
                ForEach(0..<min(eyes.sessionBlinkCount, 60), id: \.self) { _ in
                    Capsule().fill(Color.cyan.opacity(0.8)).frame(width: 2, height: 12)
                }
                if eyes.sessionBlinkCount > 60 {
                    Text("+\(eyes.sessionBlinkCount - 60)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 18) {
                metric("Openness", eyes.currentOpenness.map { String(format: "%.3f", $0) } ?? "—")
                metric("Baseline", eyes.openBaseline.map { String(format: "%.3f", $0) } ?? "—")
                metric("Signal", eyes.availability.rawValue.capitalized)
            }

            Text("Raw eye-openness from your Persona (IOD-normalized), with a tick per counted blink. This is the unprocessed signal — collapsed by default.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: FEATURES — Δ-from-baseline meters

    private var featuresStrata: some View {
        let delta = eyes.blinksPerMinute - eyes.restingBlinkRate
        return VStack(alignment: .leading, spacing: 10) {
            LensFeatureMeter(
                title: "Blink rate Δ",
                valueText: String(format: "%+.0f/min  (rest %.0f%@)",
                                  delta, eyes.restingBlinkRate, eyes.restingLearned ? "" : "*"),
                fraction: min(1, abs(delta) / Self.arousalDeltaScale)
            )
            LensFeatureMeter(
                title: "Openness variance",
                valueText: String(format: "%.4f", eyes.eyeOpennessVariance),
                fraction: min(1, eyes.eyeOpennessVariance * 40)
            )
            HStack {
                Label("Prolonged closure (PERCLOS / AU43)",
                      systemImage: eyes.prolongedClosure ? "eye.slash.fill" : "eye.slash")
                    .font(.caption)
                    .foregroundStyle(eyes.prolongedClosure ? .orange : .secondary)
                Spacer()
                Text(eyes.prolongedClosure ? "active" : "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !eyes.restingLearned {
                Text("* resting rate still using the ~15–20/min literature default until your Persona baseline matures.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: INTERPRETATION — weak arousal + ambiguity + can/can't

    private var interpretationStrata: some View {
        VStack(alignment: .leading, spacing: 12) {
            LensMeterGauge(label: "Arousal (weak — from blink rate)", meter: eyes.reading.arousal)

            VStack(alignment: .leading, spacing: 6) {
                Label("Directionally ambiguous on its own", systemImage: "arrow.triangle.branch")
                    .font(.caption.bold())
                // The §3.2 dual-reading law as a designed FORK — suppressed blink leans the
                // "engaged" prong, an elevated rate leans the "fatigue" prong, and the fork
                // shows BOTH because blink rate alone can't choose. Driven by the channel's
                // signed arousal delta; it commits to neither reading.
                ForkedMeter(magnitude: min(1, abs(eyes.signedArousalDelta ?? 0)),
                            forkA: HonestyPhrases.eyesForkLowLabel,
                            forkB: HonestyPhrases.eyesForkHighLabel,
                            balance: eyes.signedArousalDelta ?? 0)
                Text(HonestyPhrases.eyesForkExplainer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("What this can / can't tell you").font(.caption.bold())
                Text("Reads how often your Persona blinks and how open your eyes are — an attention / fatigue signal. It can't say WHY (engagement and fatigue can look alike), it carries no valence, it never tracks your gaze, and it is not an emotion readout.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Off state

    private var enablePrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.slash")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Eyes / blink lens is off")
                .font(.headline)
            Text("Enable to read rolling blinks/min and eye openness from your Persona — an attention / fatigue signal, not an emotion readout.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Toggle(isOn: $enabled) {
                Label("Enable eyes lens", systemImage: "eye")
            }
            .toggleStyle(.button)
            .onChange(of: enabled) { _, _ in eyes.refreshEnabled() }
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
