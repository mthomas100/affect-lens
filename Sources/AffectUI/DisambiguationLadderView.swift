//
//  DisambiguationLadderView.swift
//  AffectLens
//
//  THE reusable disambiguation-ladder widget (US-C10, PRD v2 §6.6) — "the single
//  most important honesty widget: the UI's job is to show the app THINKING, not to
//  assert." A progressive-narrowing stepper where each RESOLVED step lights with its
//  claim, an unresolved fork stays AMBIGUOUS (shows what it can't yet tell apart), and
//  a RULED-OUT confound greys with a STRIKETHROUGH. The user watches the claim narrow
//  in real time (the design notes' worked example: L0 "brow lowered — but head is down,
//  correcting" → L3 "most consistent with focused effort").
//
//  Pure presentation over `LadderStep` — every construct feeds its OWN steps (F1
//  Composure today; F4 frown+head-down, cognitive-load, fatigue⇄engagement, and every
//  fusion mode reuse it). The model is a `nonisolated` value type so a construct's
//  ladder BUILDER is pure and self-testable off the main actor; the view is the usual
//  MainActor SwiftUI.
//

#if os(visionOS)

import SwiftUI

// MARK: - DisambiguationLadderView (pure presentation)

/// Renders a `[LadderStep]` as a vertical stepper. Pure presentation: it holds no
/// state and makes no claims of its own — it only draws the model a construct hands it.
struct DisambiguationLadderView: View {
    let steps: [LadderStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                row(step, isLast: index == steps.count - 1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // One rung: an indicator column (dot + connector) beside the claim/fork text.
    private func row(_ step: LadderStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                indicator(step.status)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                claimText(step)
                if case .ambiguous(let fork) = step.status, !fork.isEmpty {
                    Text(fork)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, isLast ? 0 : 12)

            Spacer(minLength: 0)
        }
    }

    // The leading indicator, keyed to the status.
    @ViewBuilder private func indicator(_ status: LadderStep.Status) -> some View {
        switch status {
        case .resolved:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .ambiguous:
            Image(systemName: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.yellow)
        case .ruledOut:
            Image(systemName: "slash.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // The claim text — lit when resolved, muted when ambiguous, greyed + STRUCK when
    // ruled out (with the honest reason on a second line).
    @ViewBuilder private func claimText(_ step: LadderStep) -> some View {
        switch step.status {
        case .resolved:
            Text(step.claim)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .ambiguous:
            Text(step.claim)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .ruledOut(let reason):
            VStack(alignment: .leading, spacing: 1) {
                Text(step.claim)
                    .font(.caption)
                    .strikethrough(true, color: .secondary)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

#endif
