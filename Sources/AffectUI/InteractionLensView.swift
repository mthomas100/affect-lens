//
//  InteractionLensView.swift
//  AffectLens
//
//  The INTERACTION lens UI (US-B8, PRD v2 §3.6) — the view side of the
//  zero-permission `InteractionChannel`. Three parts:
//    1. `interactionSensing(channel:)` — a container-level `SpatialEventGesture`,
//       attached SIMULTANEOUSLY so existing buttons / toggles / taps keep working,
//       that translates raw spatial-event phases (began / ended / CANCELLED) into the
//       channel's abstract `InteractionEvent`s. Collection runs ONLY while the lens
//       is enabled (privacy-by-default: zero collection when off).
//    2. `InteractionEnableToggle` — the enable switch (shared by the lens card and
//       focus view); on change it activates/deactivates the channel and notes its own
//       toggle so churn detection sees it.
//    3. `InteractionLensView` — the 3-strata focus view (RAW event ticks / FEATURES
//       meters with baseline deltas / INTERPRETATION: ONE effort-load framing), wrapped
//       in a `TimelineView` so the rolling window AGES live with no channel-side timer.
//
//  Honesty law (PRD §3.6 / §6.7): effort / load framing ONLY (the interpretation copy
//  comes from `HonestyPhrases`); NEVER "stress", NEVER "frustration" as a state; the
//  starved state renders the designed low-signal copy rather than a fabricated read.
//

#if os(visionOS)

import SwiftUI

// MARK: - interactionSensing modifier (the SpatialEventGesture capture)

/// Attaches a container-level `SpatialEventGesture` that feeds the channel. Uses
/// `.simultaneousGesture` so it recognizes ALONGSIDE the existing controls (card
/// taps, buttons, toggles) rather than consuming their input. Only the phase EDGES
/// are noted (began on first-active, ended/cancelled on resolution), tracked per
/// event id so a long-held pinch counts once.
private struct InteractionSensingModifier: ViewModifier {
    let channel: InteractionChannel

    /// Start time per active event id, so a resolution can report a press duration and
    /// a still-active event isn't recounted every update.
    @State private var activeSince: [SpatialEventCollection.Event.ID: Date] = [:]

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            SpatialEventGesture()
                .onChanged { events in
                    // Privacy posture: zero collection while the lens is off.
                    guard channel.isEnabled else {
                        if !activeSince.isEmpty { activeSince.removeAll() }
                        return
                    }
                    let now = Date()
                    for event in events {
                        switch event.phase {
                        case .active:
                            if activeSince[event.id] == nil {
                                activeSince[event.id] = now
                                channel.note(InteractionEvent(.began, at: now))
                            }
                        case .ended:
                            let dur = activeSince[event.id].map { now.timeIntervalSince($0) }
                            activeSince[event.id] = nil
                            channel.note(InteractionEvent(.ended, at: now, duration: dur))
                        case .cancelled:
                            let dur = activeSince[event.id].map { now.timeIntervalSince($0) }
                            activeSince[event.id] = nil
                            channel.note(InteractionEvent(.cancelled, at: now, duration: dur))
                        @unknown default:
                            break
                        }
                    }
                }
                .onEnded { _ in
                    // Any event still active when the whole gesture ends completed
                    // normally; note + clean up (the phases can also resolve in
                    // onChanged, in which case the id is already gone).
                    guard channel.isEnabled else { activeSince.removeAll(); return }
                    let now = Date()
                    for (_, start) in activeSince {
                        channel.note(InteractionEvent(.ended, at: now, duration: now.timeIntervalSince(start)))
                    }
                    activeSince.removeAll()
                }
        )
    }
}

extension View {
    /// Sense manipulation of the app's OWN controls into `channel` (PRD §3.6 / F7).
    /// Attach at a container root; it gives broad, honest coverage of that subtree's
    /// pinches/taps while the existing controls keep working (simultaneous gesture).
    func interactionSensing(channel: InteractionChannel) -> some View {
        modifier(InteractionSensingModifier(channel: channel))
    }
}

// MARK: - InteractionEnableToggle (shared enable switch)

/// The interaction enable switch, owning the `@AppStorage` flag so a card tap and the
/// focus view always agree. On change it activates/deactivates the channel FIRST (so
/// activation starts from a clean window), then notes its own toggle — which is
/// recorded only when the lens ends up ON (the note guards on `isEnabled`), keeping
/// the disabled state truly zero-collection.
struct InteractionEnableToggle: View {
    let interaction: InteractionChannel
    @AppStorage(InteractionChannel.enabledKey) private var enabled = false

    var body: some View {
        Toggle(isOn: $enabled) {
            Text(enabled ? "Interaction lens on" : "Enable interaction lens").font(.caption)
        }
        .toggleStyle(.switch)
        .onChange(of: enabled) { _, isOn in
            interaction.refreshEnabled()
            interaction.note(InteractionEvent(.toggle(id: "lens.interaction", isOn: isOn), at: Date()))
        }
    }
}

// MARK: - InteractionLensView (the 3-strata focus view)

/// The interaction lens focus view. Off → an enable prompt; on → the 3-strata
/// scaffold driven by the live `InteractionChannel`, refreshed on a 1 Hz clock so the
/// rolling window ages even while the user isn't interacting.
struct InteractionLensView: View {
    let interaction: InteractionChannel
    @AppStorage(InteractionChannel.enabledKey) private var enabled = false

    var body: some View {
        Group {
            if enabled { lens } else { enablePrompt }
        }
    }

    private var lens: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let s = interaction.snapshot(at: context.date)
            ChannelLensView(title: "Interaction",
                            systemImage: "hand.tap",
                            scope: Lens.interaction.scope) {
                rawStrata(now: context.date)
            } features: {
                featuresStrata(s)
            } interpretation: {
                interpretationStrata(s)
            }
        }
    }

    // MARK: RAW — recent event ticks (kind + age)

    private func rawStrata(now: Date) -> some View {
        let recents = interaction.recentEvents(now: now, limit: 12)
        return VStack(alignment: .leading, spacing: 10) {
            if recents.isEmpty {
                Text("No recent interaction. Pinch a card, flip a toggle, or scrub — events show here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(recents.enumerated()), id: \.offset) { _, e in
                        HStack(spacing: 8) {
                            Circle().fill(color(for: e.kind)).frame(width: 7, height: 7)
                            Text(label(for: e.kind))
                                .font(.caption.monospacedDigit())
                            Spacer(minLength: 6)
                            Text(age(e.t, now: now))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Text("Raw interaction stream — pinch/tap phases (incl. cancelled) and toggle flips on THIS app's controls. Never the content you view; only that you acted.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: FEATURES — Δ-from-baseline meters

    private func featuresStrata(_ s: InteractionReadout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LensFeatureMeter(
                title: "Input tempo Δ",
                valueText: String(format: "%.0f/min  (%+.0f vs you%@)",
                                  s.inputTempo, s.inputTempoDelta, s.baselineLearned ? "" : "*"),
                fraction: min(1, abs(s.inputTempoDelta) / InteractionChannel.tempoDeltaScale),
                tint: .mint
            )
            LensFeatureMeter(
                title: "Cancel / correction rate Δ",
                valueText: String(format: "%.0f%%  (%+.0f%% vs you%@)",
                                  s.cancelRate * 100, s.cancelRateDelta * 100, s.baselineLearned ? "" : "*"),
                fraction: min(1, s.cancelRate / InteractionChannel.cancelRateFull),
                tint: .orange
            )
            LensFeatureMeter(
                title: "Press-duration median (dwell)",
                valueText: s.pressDurationMedian.map { String(format: "%.2f s", $0) } ?? "—",
                fraction: min(1, (s.pressDurationMedian ?? 0) / 1.0),
                tint: .cyan
            )
            HStack {
                Label("Toggle corrections (flip-backs)", systemImage: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(s.toggleCorrections > 0 ? .orange : .secondary)
                Spacer()
                Text("\(s.toggleCorrections)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !s.baselineLearned {
                Text("* your interaction baseline is still learning from use — deltas are shown against the current estimate until it matures.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: INTERPRETATION — ONE effort/load framing + ambiguity + can/can't

    private func interpretationStrata(_ s: InteractionReadout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if s.isStarved {
                Label(HonestyPhrases.interactionStarved, systemImage: "hand.raised.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            } else {
                LensMeterGauge(label: "Effort / load (from how you use the app)",
                               meter: Meter(value: s.effort, confidence: s.quality))
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("A load signal, not a feeling", systemImage: "arrow.triangle.branch")
                    .font(.caption.bold())
                Text(HonestyPhrases.interactionAmbiguity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("What this can / can't tell you").font(.caption.bold())
                Text(HonestyPhrases.interactionScope)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Off state

    private var enablePrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.tap")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Interaction lens is off")
                .font(.headline)
            Text("Enable to read your input tempo and how often you cancel or correct — an effort / engagement signal derived only from how you use this app's controls. Zero permission, nothing about the content you view.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            InteractionEnableToggle(interaction: interaction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: Event-tick formatting

    private func label(for kind: InteractionEvent.Kind) -> String {
        switch kind {
        case .began: return "pinch began"
        case .ended: return "pinch ended"
        case .cancelled: return "pinch cancelled"
        case let .toggle(id, isOn): return "toggle \(id) \(isOn ? "on" : "off")"
        }
    }

    private func color(for kind: InteractionEvent.Kind) -> Color {
        switch kind {
        case .began: return .mint
        case .ended: return .green
        case .cancelled: return .orange
        case .toggle: return .purple
        }
    }

    private func age(_ t: Date, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(t)))
        return secs < 60 ? "\(secs)s ago" : "\(secs / 60)m ago"
    }
}

#endif
