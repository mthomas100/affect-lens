//
//  EmotionTimelineView.swift
//  AffectLens
//
//  A scrolling strip of the recent emotional record — each processed frame
//  drawn as a colored tick (hue = emotion, opacity = confidence).
//

import SwiftUI

#if os(visionOS)
struct EmotionTimelineView: View {
    let samples: [EmotionSample]
    var window: TimeInterval = 45

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Emotion timeline")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("last \(Int(window))s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Canvas { ctx, size in
                let now = Date()
                for sample in samples {
                    let age = now.timeIntervalSince(sample.date)
                    guard age >= 0, age <= window else { continue }
                    let x = (1 - age / window) * size.width
                    let rect = CGRect(x: x - 1.5, y: 0, width: 3, height: size.height)
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(sample.emotion.color.opacity(0.35 + 0.6 * sample.confidence))
                    )
                }
            }
            .frame(height: 26)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
#endif
