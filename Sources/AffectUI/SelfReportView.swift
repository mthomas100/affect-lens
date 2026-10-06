//
//  SelfReportView.swift
//  AffectLens
//
//  The ESM ground-truth UI (US-E17, PRD v2 §5.7 / §6.8 / §9.1 M6):
//    • SelfReportSheet     — the compact 1-tap check-in (a State-of-Mind-ramp valence
//                            slider + optional label chips + one Save). The slider
//                            alone is a complete report.
//    • ShiftPromptBanner   — the gentle, dismissible inline banner offered after a
//                            settled BOCPD state-shift (never a modal interruption).
//    • SelfReportButton    — the always-available manual "How do you feel?" trigger.
//    • GroundTruthSection  — the honest per-user overlay: report count, valence CCC,
//                            conformal-set status, and the Health write status. Framed
//                            "for you, on this device" — never a population claim.
//
//  Honesty law (§6.7): every string comes from `HonestyPhrases` (swept by the
//  self-test); the aura/feed never scores or praises — this UI reflects and records.
//

#if os(visionOS)

import SwiftUI

// MARK: - SelfReportButton (the manual trigger)

/// The always-available "How do you feel?" button (near the insight feed). One tap
/// opens the sheet; the sheet's slider alone is a complete report.
struct SelfReportButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(HonestyPhrases.selfReportManualButton, systemImage: "heart.text.square")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .tint(.pink)
    }
}

// MARK: - ShiftPromptBanner (the never-interruptive nudge)

/// The gentle inline banner surfaced after a settled state-shift (PRD OQ14). It is
/// NOT a modal, is dismissible, and never re-prompts within the cooldown (the store's
/// `EsmPromptPolicy` gates it). "Optional" in the copy by design.
struct ShiftPromptBanner: View {
    let onLog: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.pink)
            Text(HonestyPhrases.selfReportBannerText)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button(HonestyPhrases.selfReportBannerCTA, action: onLog)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.pink)
                Button(HonestyPhrases.selfReportBannerDismiss, action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.pink.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - SelfReportSheet (the 1-tap check-in)

/// The compact self-report sheet. A valence slider tinted along the Apple
/// State-of-Mind ramp (`StateOfMindRamp`) plus optional multi-select label chips and a
/// single Save. The slider alone suffices — a true 1-tap report.
struct SelfReportSheet: View {
    let hub: AffectHub

    @Environment(\.dismiss) private var dismiss
    @State private var valence: Double = 0
    /// Ordered so `primaryEmotion` honors first-selected (conformal true class).
    @State private var selected: [QuickMood] = []
    @State private var saving = false

    private let chipColumns = [GridItem(.adaptive(minimum: 104, maximum: .infinity), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                valenceControl
                labelChips
                healthNote
                Spacer(minLength: 0)
            }
            .padding(22)
        }
        .safeAreaInset(edge: .bottom) { saveBar }
        .frame(minWidth: 420, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HonestyPhrases.selfReportTitle)
                .font(.title2.bold())
            Text(HonestyPhrases.selfReportSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // The valence slider, tinted along the State-of-Mind ramp, with a live word.
    private var valenceControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HonestyPhrases.selfReportValencePrompt)
                .font(.subheadline.bold())

            // The ramp bar (unpleasant → neutral → pleasant) behind a tinted slider.
            ZStack {
                Capsule()
                    .fill(LinearGradient(
                        colors: [Self.color(StateOfMindRamp.unpleasant),
                                 Self.color(StateOfMindRamp.neutral),
                                 Self.color(StateOfMindRamp.pleasant)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: 10)
                    .opacity(0.55)
                Slider(value: $valence, in: -1...1)
                    .tint(Self.color(StateOfMindRamp.color(valence: valence)))
            }

            HStack {
                Text(HonestyPhrases.selfReportValenceLow)
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(HonestyPhrases.valenceWord(valence))
                    .font(.caption.bold())
                    .foregroundStyle(Self.color(StateOfMindRamp.color(valence: valence)))
                Spacer()
                Text(HonestyPhrases.selfReportValenceHigh)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var labelChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HonestyPhrases.selfReportLabelsPrompt)
                .font(.subheadline.bold())
            LazyVGrid(columns: chipColumns, spacing: 8) {
                ForEach(QuickMood.allCases) { mood in
                    chip(mood)
                }
            }
        }
    }

    private func chip(_ mood: QuickMood) -> some View {
        let isOn = selected.contains(mood)
        return Button {
            if let i = selected.firstIndex(of: mood) { selected.remove(at: i) }
            else { selected.append(mood) }
        } label: {
            Text(mood.displayName)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isOn ? Color.pink.opacity(0.28) : Color.white.opacity(0.06),
                            in: Capsule())
                .overlay(Capsule().stroke(isOn ? Color.pink.opacity(0.6) : Color.white.opacity(0.1),
                                          lineWidth: 1))
                .foregroundStyle(isOn ? Color.pink : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var healthNote: some View {
        Label(HonestyPhrases.selfReportHealthNote, systemImage: "heart.text.square")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var saveBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
            Spacer()
            Button {
                saving = true
                let reported = selected
                let v = valence
                Task {
                    await hub.submitSelfReport(userValence: v, labels: reported)
                    saving = false
                    dismiss()
                }
            } label: {
                Text(saving ? HonestyPhrases.selfReportSavingButton : HonestyPhrases.selfReportSaveButton)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .disabled(saving)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    /// (h, s, b) → SwiftUI Color (the ramp anchors are HSB triples).
    private static func color(_ c: (h: Double, s: Double, b: Double)) -> Color {
        Color(hue: c.h, saturation: c.s, brightness: c.b)
    }
}

// MARK: - GroundTruthSection (the honest per-user overlay)

/// The ground-truth panel (near the fusion section). Shows — always "for you, on this
/// device" — the report count, the valence CCC (inferred vs self-reported), the
/// conformal-set status, and the most recent Health write status. Never a population
/// claim; nothing here leaves the device unless the user saved it to Health.
struct GroundTruthSection: View {
    let hub: AffectHub

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(HonestyPhrases.groundTruthTitle)
                    .font(.headline)
                Text(HonestyPhrases.groundTruthBlurb)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if hub.esm.reports.isEmpty {
                Text(HonestyPhrases.groundTruthEmpty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                row("tray.full", "\(hub.esm.reports.count) report\(hub.esm.reports.count == 1 ? "" : "s") logged.")
                cccRow
                conformalRow
                healthRow
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var cccRow: some View {
        let paired = hub.pairedReportCount()
        let text = hub.valenceCCC().map { HonestyPhrases.groundTruthCCC(ccc: $0, pairedCount: paired) }
            ?? HonestyPhrases.groundTruthCCCNeedsMore(pairedCount: paired)
        return row("waveform.path.ecg", text)
    }

    @ViewBuilder private var conformalRow: some View {
        switch hub.conformalStatus {
        case .uncalibrated(let n):
            row("questionmark.circle", HonestyPhrases.conformalLearning(have: n, need: ConformalCalibrator.minSamples))
        case .calibrated(_, let n):
            row("checkmark.seal", HonestyPhrases.conformalCalibrated(sampleCount: n))
        }
    }

    @ViewBuilder private var healthRow: some View {
        if let result = hub.lastHealthResult {
            let text = result.didSaveToHealth
                ? HonestyPhrases.groundTruthHealthSaved
                : HonestyPhrases.groundTruthHealthLocalOnly(reason: result.reason ?? "")
            row("heart", text)
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(.pink)
        }
    }
}

#endif
