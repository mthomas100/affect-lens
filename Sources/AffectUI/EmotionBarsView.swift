//
//  EmotionBarsView.swift
//  AffectLens
//
//  Live animated probability bars for all emotion classes.
//

import SwiftUI

#if os(visionOS)
struct EmotionBarsView: View {
    let distribution: EmotionDistribution
    /// Raw evidence strength per emotion (drawn as the thin underline).
    var intensities: [Emotion: Double] = [:]

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Probability")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text("· thin line = intensity")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            ForEach(Emotion.allCases) { emotion in
                let p = distribution[emotion]
                let intensity = intensities[emotion] ?? 0
                HStack(spacing: 10) {
                    Text(emotion.emoji)
                        .font(.system(size: 15))
                        .frame(width: 24)
                    Text(emotion.displayName)
                        .font(.callout)
                        .frame(width: 100, alignment: .leading)
                    GeometryReader { geo in
                        VStack(alignment: .leading, spacing: 2) {
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(emotion.color.gradient)
                                    .frame(width: max(4, geo.size.width * p))
                            }
                            .frame(height: 11)
                            Capsule()
                                .fill(emotion.color.opacity(0.55))
                                .frame(width: max(2, geo.size.width * intensity), height: 3)
                        }
                    }
                    .frame(height: 16)
                    Text("\(Int((p * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .animation(.smooth(duration: 0.25), value: distribution)
        .animation(.smooth(duration: 0.25), value: intensities)
    }
}
#endif
