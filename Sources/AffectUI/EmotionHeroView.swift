//
//  EmotionHeroView.swift
//  AffectLens
//
//  The headline readout: big emoji inside an animated confidence ring,
//  emotion name, confidence, and the FACS evidence hint.
//

import SwiftUI

#if os(visionOS)
struct EmotionHeroView: View {
    let reading: EmotionReading

    /// The calibrated split-conformal label set (US-E17), or `nil` to use the built-in
    /// top-2 margin heuristic. Surgical, defaulted opt-in: only the home hero passes a
    /// value (from `AffectHub.conformalLabels`); every other call site is unchanged.
    var conformalLabels: [Emotion]? = nil

    private var color: Color { reading.dominant.color }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.001, reading.faceDetected ? reading.confidence : 0))
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0.45), color],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text(reading.faceDetected ? reading.dominant.emoji : "🔍")
                    .font(.system(size: 58))
                    .contentTransition(.opacity)
            }
            .frame(width: 124, height: 124)
            .animation(.smooth(duration: 0.3), value: reading.confidence)

            VStack(alignment: .leading, spacing: 5) {
                Text(headline)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(reading.faceDetected ? color : Color.secondary)
                    .contentTransition(.opacity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                if reading.faceDetected {
                    Text("\(Int((reading.confidence * 100).rounded()))% sure")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())

                    multiLabelChip

                    intensityGauge

                    Text(reading.dominant.facsHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Start the camera and face it to begin")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .animation(.smooth(duration: 0.25), value: reading.intensity)
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(color.opacity(reading.faceDetected ? 0.35 : 0.08), lineWidth: 1.5)
        )
        .animation(.smooth(duration: 0.35), value: reading.dominant)
    }

    /// "Very Angry", "Slightly Happy" … (neutral stays ungraded).
    private var headline: String {
        guard reading.faceDetected else { return "Looking for you…" }
        guard reading.dominant != .neutral else { return reading.dominant.displayName }
        return "\(EmotionIntensity.adjective(reading.intensity)) \(reading.dominant.displayName)"
    }

    /// The conformal-set look (§6.5). When a CALIBRATED conformal set is supplied
    /// (US-E17), render it whenever it is genuinely ambiguous (≥2 labels) — the honest
    /// per-user "likely {A, B}" that covers the truth at the 90% target. Otherwise fall
    /// back to the built-in top-2 margin heuristic: shown ONLY when the posterior's top-2
    /// margin is below `MultiLabelChip.defaultMargin`. Either way a clear winner shows no
    /// chip, and this is a DISPLAY of existing calibration — no new per-frame inference.
    @ViewBuilder private var multiLabelChip: some View {
        if let conformal = conformalLabels {
            if conformal.count > 1 { MultiLabelChip(labels: conformal) }
        } else {
            let labels = MultiLabelChip.topLabels(for: reading.distribution)
            if labels.count > 1 { MultiLabelChip(labels: labels) }
        }
    }

    /// How hard the expression is being made (vs. the ring's "how sure").
    private var intensityGauge: some View {
        HStack(spacing: 8) {
            Text(reading.dominant == .neutral ? "Expression" : "Intensity")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(3, geo.size.width * reading.intensity))
                }
            }
            .frame(height: 8)
            Text("\(Int((reading.intensity * 10).rounded()))/10")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(width: 34, alignment: .trailing)
        }
        .frame(maxWidth: 270)
    }
}
#endif
