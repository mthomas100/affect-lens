//
//  HandsLensView.swift
//  AffectLens
//
//  The HANDS lens UI (US-D13a, PRD v2 §3.3) — the view side of the arousal-only
//  `HandsChannel`. Two parts:
//    1. `HandsEnableToggle` — the enable switch (shared by the lens card + focus view),
//       which notes its flip into the interaction lens as toggle churn.
//    2. `HandsLensView` — the 3-strata focus view (RAW live per-hand speed / aperture
//       readouts — light + honest, no heavy joint-dot ghost / FEATURES the four
//       delta-from-baseline meters / INTERPRETATION: ONE arousal meter + the "rates vs your
//       baseline, never a single gesture, no gesture dictionary" paragraph). Because hands
//       are immersive-only, the off-states are designed: disabled ⇒ enable prompt; enabled
//       but the aura space is closed ⇒ an "open the aura" prompt with the toggle; auth-denied
//       / unsupported / failed ⇒ the honest reason. Never a faked reading.
//
//  Honesty law (PRD §2 master law / §3.3): AROUSAL / agitation / load ONLY — never valence,
//  never a discrete emotion, and NO gesture dictionary. Self-touch is a RATE, never a single
//  gesture. All interpretation copy comes from `HonestyPhrases`.
//

#if os(visionOS)

import SwiftUI

// MARK: - HandsEnableToggle (shared enable switch)

/// The hands enable switch, owning the `@AppStorage` flag so a card tap, the focus view, and
/// the K1 HUD toggle always agree. On change it re-publishes the channel's state, then notes
/// its own flip into the interaction lens (dropped unless interaction is on).
struct HandsEnableToggle: View {
    let hands: HandsChannel
    let interaction: InteractionChannel
    @AppStorage(HandsChannel.enabledKey) private var enabled = false

    var body: some View {
        Toggle(isOn: $enabled) {
            Text(enabled ? "Hands lens on" : "Enable hands lens").font(.caption)
        }
        .toggleStyle(.switch)
        .onChange(of: enabled) { _, isOn in
            hands.refreshEnabled()
            interaction.note(InteractionEvent(.toggle(id: "lens.hands", isOn: isOn), at: Date()))
        }
    }
}

// MARK: - HandsLensView (the 3-strata focus view)

/// The hands lens focus view. Reads the channel's published state only (no `HandsChannel`
/// change); the coordinator supplies the live K1 update rate.
struct HandsLensView: View {
    let hands: HandsChannel
    let coordinator: ImmersiveSensingCoordinator
    let interaction: InteractionChannel
    @AppStorage(HandsChannel.enabledKey) private var enabled = false

    var body: some View {
        Group {
            if !enabled {
                enablePrompt
            } else if hands.availability != .unavailable {
                lens
            } else {
                offState
            }
        }
    }

    private var lens: some View {
        ChannelLensView(title: "Hands",
                        systemImage: "hand.raised",
                        scope: Lens.hands.scope) {
            rawStrata
        } features: {
            featuresStrata
        } interpretation: {
            interpretationStrata
        }
    }

    // MARK: RAW — light numeric per-hand readouts (no heavy joint ghost)

    private var rawStrata: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: hands.tracked ? "hand.raised.fill" : "hand.raised.slash")
                    .foregroundStyle(hands.tracked ? .orange : .secondary)
                ProgressView(value: min(1, hands.meanJointSpeed / HandsChannel.energyDeltaScale))
                    .tint(hands.tracked ? .orange : .gray)
                Text(hands.tracked ? "tracked" : "out of view")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }

            HStack(spacing: 18) {
                metric("Motion energy", String(format: "%.2f m/s", hands.meanJointSpeed))
                metric("Aperture", hands.handAperture.map { String(format: "%.2f", $0) } ?? "—")
                metric("Hands Hz", String(format: "%.0f", coordinator.handsUpdateHz))
            }
            HStack(spacing: 18) {
                metric("Self-touches", "\(hands.sessionSelfTouchCount)")
                metric("Gestures", "\(hands.sessionGestureBurstCount)")
                metric("Signal", hands.availability.rawValue.capitalized)
            }

            Text("Live hand-motion energy and aperture from ARKit hand tracking, read alongside your Persona. The unprocessed signal — mean joint speed over a short window. No gesture is ever named.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: FEATURES — Δ-from-baseline meters

    private var featuresStrata: some View {
        let f = hands.reading.features
        let energyDelta = f[.gestureEnergy] ?? 0
        let selfTouch = f[.selfTouchRate] ?? 0
        let gestures = f[.gestureRate] ?? 0
        let aperture = f[.handAperture] ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            LensFeatureMeter(
                title: "Motion energy Δ",
                valueText: String(format: "%+.2f m/s  (rest %.2f%@)",
                                  energyDelta, hands.restingSpeed, hands.restingLearned ? "" : "*"),
                fraction: min(1, abs(energyDelta) / HandsChannel.energyDeltaScale),
                tint: .orange
            )
            LensFeatureMeter(
                title: "Self-touch rate",
                valueText: String(format: "%.0f/min", selfTouch),
                fraction: min(1, selfTouch / HandsChannel.selfTouchRateScale),
                tint: .pink
            )
            LensFeatureMeter(
                title: "Gesture rate",
                valueText: String(format: "%.0f/min", gestures),
                fraction: min(1, gestures / 10),
                tint: .yellow
            )
            LensFeatureMeter(
                title: "Hand aperture (tension)",
                valueText: String(format: "%.2f", aperture),
                fraction: min(1, aperture / 1.5),
                tint: .teal
            )
            if !hands.restingLearned {
                Text("* your resting hand baseline is still learning — deltas use a small literature default until it matures, so confidence is held low (hand affect is within-user only).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: INTERPRETATION — ONE arousal meter + ambiguity + can/can't

    private var interpretationStrata: some View {
        VStack(alignment: .leading, spacing: 12) {
            LensMeterGauge(label: "Arousal (from hand motion — agitation / load)", meter: hands.reading.arousal)

            VStack(alignment: .leading, spacing: 6) {
                Label("A level, not a direction", systemImage: "arrow.triangle.branch")
                    .font(.caption.bold())
                Text(HonestyPhrases.handsAmbiguity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("What this can / can't tell you").font(.caption.bold())
                Text(HonestyPhrases.handsScope)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Off states (designed, never an error)

    private var enablePrompt: some View {
        promptScaffold(icon: "hand.raised.slash",
                       title: "Hands lens is off",
                       body: "Enable to read hand-motion energy, gesture rate and self-touch rate from ARKit hand tracking — an agitation / load signal on the arousal axis, measured against your own resting hands. Never a gesture dictionary, never valence.") {
            HandsEnableToggle(hands: hands, interaction: interaction)
        }
    }

    /// Enabled but the aura space is closed — the "open the aura" CTA (hands run only there).
    private var immersiveClosedPrompt: some View {
        promptScaffold(icon: "cube.transparent",
                       title: "Hands need the immersive space",
                       body: "Hand tracking runs only while the immersive aura space is open. Open the aura and the hands lens comes to life — on-device, hand-motion energy → arousal.") {
            ToggleImmersiveSpaceButton()
        }
    }

    private var offState: some View {
        Group {
            switch hands.unavailableReason {
            case .immersiveClosed, .none:
                immersiveClosedPrompt
            case .disabled:
                enablePrompt
            case .authDenied:
                reasonPrompt(icon: "hand.raised.slash",
                             text: "Hand tracking access is off. Allow it in Settings, then reopen the immersive space to read hand motion on-device.")
            case .providerUnsupported:
                reasonPrompt(icon: "exclamationmark.triangle",
                             text: "Hand tracking isn't available here — it doesn't run in the simulator. Try on an Apple Vision Pro with the immersive space open.")
            case .sessionError(let m):
                reasonPrompt(icon: "exclamationmark.triangle",
                             text: "Hand tracking couldn't start — \(m). Try reopening the immersive space.")
            }
        }
    }

    private func reasonPrompt(icon: String, text: String) -> some View {
        promptScaffold(icon: icon, title: "Hands unavailable", body: text) { EmptyView() }
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
                .frame(maxWidth: 400)
            control()
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
