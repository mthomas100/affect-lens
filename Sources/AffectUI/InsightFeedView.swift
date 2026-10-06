//
//  InsightFeedView.swift
//  AffectLens
//
//  The insight feed (US-B7, PRD v2 §6.3) — a compact scrolling strip of narrated
//  `AffectEvent`s. Each row is a timestamp + one honest sentence (from the template
//  narrator today; the FM narrator later); tap a row to expand its evidence chips
//  (the cited `SignalRef`s) and confidence word. This is the narrated evolution of
//  `EmotionTimelineView`'s colored ticks — meaning over a dashboard.
//
//  Honesty law (§6.7): every sentence is banned-substring-clean by construction
//  (it comes from `HonestyPhrases`), the confidence word is shown separate from any
//  intensity, and the empty state is an honest placeholder, never an error.
//

#if os(visionOS)

import SwiftUI

struct InsightFeedView: View {
    /// The hub's narrated entries (oldest-first). The newest are shown on top.
    let insights: [InsightEntry]

    /// Keep the home strip unobtrusive: show the most recent few, newest first.
    private let maxRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if insights.isEmpty {
                Text(HonestyPhrases.insightFeedEmpty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(recent) { entry in
                    InsightRowView(entry: entry)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Newest-first slice for display.
    private var recent: [InsightEntry] {
        Array(insights.suffix(maxRows).reversed())
    }

    private var header: some View {
        HStack {
            Label("Insight feed", systemImage: "sparkles")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()
            if !insights.isEmpty {
                Text("\(insights.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// One feed row: timestamp + sentence, tappable to reveal the evidence chips and the
/// confidence word. Local expand state only — nothing here mutates the model.
private struct InsightRowView: View {
    let entry: InsightEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.t, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(entry.text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                detail
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.evidence.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.evidence, id: \.self) { ref in
                        Text(ref.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                }
            }
            Text("Confidence: \(HonestyPhrases.confidenceWord(entry.confidence)) · a signal, not a felt state")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }
}

#endif
