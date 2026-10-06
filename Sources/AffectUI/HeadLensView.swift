//
//  HeadLensView.swift
//  AffectLens
//
//  The HEAD lens UI (US-D13b, PRD v2 §3.4) — the view side of the dual-source
//  `HeadChannel`. Two parts:
//    1. `HeadEnableToggle` — the enable switch (shared by the lens card + focus view),
//       noting its flip into the interaction lens as toggle churn.
//    2. `HeadLensView` — the 3-strata focus view:
//         • RAW — the numeric gimbal (pitch / yaw / roll in degrees + motion) with a SOURCE
//           badge (windowed ⟷ 6DoF), so you can see which sensor is driving it.
//         • FEATURES — the delta-from-neutral meters + head-motion energy.
//         • INTERPRETATION — ONE arousal meter, the hedged dominance-lean bar + line, and
//           THE mandated honesty paragraph (head orientation ≠ gaze; head-down with direct
//           gaze is concentration, not withdrawal; roll low-confidence; no nod/shake meanings).
//
//  Honesty law (PRD §2 master law / §3.4): DOMINANCE / APPROACH + AROUSAL only — never
//  valence, never a discrete emotion, and NO head-tilt or nod/shake dictionary. The felt
//  words "pride" / "shame" appear ONLY as hedged glosses. All interpretation copy comes
//  from `HonestyPhrases`.
//

#if os(visionOS)

import SwiftUI

// MARK: - HeadEnableToggle (shared enable switch)

/// The head enable switch, owning the `@AppStorage` flag so a card tap, the focus view, and
/// the K3 HUD toggle always agree. On change it re-registers the windowed source on the
/// hub's fan-out, then notes its own flip into the interaction lens.
struct HeadEnableToggle: View {
    let head: HeadChannel
    let interaction: InteractionChannel
    @AppStorage(HeadChannel.enabledKey) private var enabled = false

    var body: some View {
        Toggle(isOn: $enabled) {
            Text(enabled ? "Head lens on" : "Enable head lens").font(.caption)
        }
        .toggleStyle(.switch)
        .onChange(of: enabled) { _, isOn in
            head.refreshEnabled()
            interaction.note(InteractionEvent(.toggle(id: "lens.head", isOn: isOn), at: Date()))
        }
    }
}

// MARK: - HeadLensView (the 3-strata focus view)

/// The head lens focus view. Off → an enable prompt; thermally paused → the cooling reason;
/// on → the 3-strata scaffold driven by the live `HeadChannel`. Reads the channel's
/// published state only (no `HeadChannel` change).
struct HeadLensView: View {
    let head: HeadChannel
    let interaction: InteractionChannel
    @AppStorage(HeadChannel.enabledKey) private var enabled = false

    var body: some View {
        Group {
            if !enabled {
                enablePrompt
            } else if head.thermalPaused {
                thermalPrompt
            } else {
                lens
            }
        }
    }

    private var lens: some View {
        ChannelLensView(title: "Head",
                        systemImage: "person.bust",
                        scope: Lens.head.scope) {
            rawStrata
        } features: {
            featuresStrata
        } interpretation: {
            interpretationStrata
        }
    }

    // MARK: RAW — the numeric gimbal + source badge

    private var rawStrata: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: head.tracked ? "person.bust.fill" : "person.bust")
                    .foregroundStyle(head.tracked ? .indigo : .secondary)
                Text("Source")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(sourceLabel)
                    .font(.caption2.bold())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.indigo.opacity(0.22), in: Capsule())
                    .foregroundStyle(.indigo)
                Spacer()
                Text(head.availability.rawValue.capitalized)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                metric("Pitch", degrees(head.pose?.pitch))
                metric("Yaw", degrees(head.pose?.yaw))
                metric("Roll", degrees(head.pose?.roll))
                metric("Motion", String(format: "%.2f r/s", head.motionEnergy))
            }

            Text("Live head pose from \(sourceExplainer). Pitch + is head-back / chin up, − is head-down; the numbers are the raw gimbal before any per-user baseline. No head-tilt or nod is ever given a meaning.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: FEATURES — Δ-from-neutral meters

    private var featuresStrata: some View {
        VStack(alignment: .leading, spacing: 10) {
            LensFeatureMeter(
                title: "Pitch Δ (back + / down −)",
                valueText: String(format: "%+.0f°%@", head.pitchDelta * 180 / .pi, head.neutralLearned ? "" : "*"),
                fraction: min(1, abs(head.pitchDelta) / HeadChannel.dominancePitchScale),
                tint: .indigo
            )
            LensFeatureMeter(
                title: "Yaw Δ (turned away)",
                valueText: String(format: "%+.0f°", head.yawDelta * 180 / .pi),
                fraction: min(1, abs(head.yawDelta) / HeadChannel.dominanceYawScale),
                tint: .purple
            )
            LensFeatureMeter(
                title: "Roll Δ (lateral tilt — low-confidence)",
                valueText: String(format: "%+.0f°", head.rollDelta * 180 / .pi),
                fraction: min(1, abs(head.rollDelta) / 0.5),
                tint: .gray
            )
            LensFeatureMeter(
                title: "Head-motion energy Δ",
                valueText: String(format: "%+.2f r/s  (rest %.2f%@)",
                                  head.motionEnergy - head.restingEnergy, head.restingEnergy,
                                  head.restingLearned ? "" : "*"),
                fraction: min(1, abs(head.motionEnergy - head.restingEnergy) / HeadChannel.energyDeltaScale),
                tint: .teal
            )
            if !head.neutralLearned || !head.restingLearned {
                Text("* your neutral head pose / resting-motion baseline is still learning — deltas are provisional and confidence is held low until it matures.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: INTERPRETATION — arousal + hedged dominance + the mandated honesty paragraph

    private var interpretationStrata: some View {
        VStack(alignment: .leading, spacing: 12) {
            LensMeterGauge(label: "Arousal (from head motion — engagement)", meter: head.reading.arousal)

            // The hedged dominance lean — a bipolar bar + the hedged line. ALWAYS low-confidence.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Dominance / approach lean").font(.caption.bold())
                    Spacer()
                    Text("low-confidence")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                DominanceLeanBar(lean: head.dominanceLean)
                Text(HonestyPhrases.headDominanceLine(lean: head.dominanceLean))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Label("A level, not a direction", systemImage: "arrow.triangle.branch")
                    .font(.caption.bold())
                Text(HonestyPhrases.headAmbiguity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What this can / can't tell you").font(.caption.bold())
                Text(HonestyPhrases.headHonesty)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Off states (designed, never an error)

    private var enablePrompt: some View {
        promptScaffold(icon: "person.bust",
                       title: "Head lens is off",
                       body: "Enable to read head pose & motion from your Persona — a dominance / approach and arousal signal, measured against your own neutral pose. Works in this window; richer with the immersive space open. Never valence, never a head-tilt or nod dictionary.") {
            HeadEnableToggle(head: head, interaction: interaction)
        }
    }

    private var thermalPrompt: some View {
        promptScaffold(icon: "thermometer.medium",
                       title: "Head sensing paused to cool down",
                       body: "The device is warm, so aux sensing eased back to keep things cool. Your Persona face reading stays live; the head lens resumes automatically as the device cools.") {
            EmptyView()
        }
    }

    private func promptScaffold<Control: View>(icon: String, title: String, body: String,
                                               @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            control()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: Helpers

    private var sourceLabel: String {
        switch head.activeSource {
        case .immersive6DoF: return "6DoF"
        case .windowed: return "windowed"
        case .none: return "—"
        }
    }

    private var sourceExplainer: String {
        switch head.activeSource {
        case .immersive6DoF: return "the immersive 6DoF device pose (higher fidelity)"
        case .windowed: return "the windowed Persona pose (open the immersive space for the 6DoF source)"
        case .none: return "your Persona — look toward the camera"
        }
    }

    private func degrees(_ radians: Double?) -> String {
        radians.map { String(format: "%+.0f°", $0 * 180 / .pi) } ?? "—"
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

// MARK: - DominanceLeanBar (a bipolar withdrawal ⟷ expansion bar)

/// A single zero-centred BIPOLAR bar for the hedged dominance-lean ∈ [−1, 1]: left =
/// withdrawal (head-down + turned-away), right = expansion (head-back + level), centre =
/// no lean. Pure presentation over the value the channel publishes; it makes no claim of
/// its own (the hedged line beside it carries the words + the gaze caveat).
private struct DominanceLeanBar: View {
    /// −1 withdrawal … 0 neutral … +1 expansion.
    let lean: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("withdrawal").font(.caption2).foregroundStyle(.orange)
                Spacer(minLength: 8)
                Text("expansion").font(.caption2).foregroundStyle(.teal)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let mid = w / 2
                let clamped = CGFloat(max(-1, min(1, lean)))
                let knobX = mid + clamped * mid
                ZStack {
                    Capsule().fill(.quaternary).frame(height: 6)
                    Rectangle()
                        .fill(.secondary.opacity(0.6))
                        .frame(width: 1.5, height: 14)
                        .position(x: mid, y: geo.size.height / 2)
                    Circle()
                        .fill(lean >= 0 ? Color.teal : Color.orange)
                        .frame(width: 14, height: 14)
                        .position(x: knobX, y: geo.size.height / 2)
                }
            }
            .frame(height: 16)
        }
    }
}

#endif
