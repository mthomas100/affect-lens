//
//  CongruenceRingView.swift
//  AffectLens
//
//  THE CONGRUENCE RING (US-C10a, PRD v2 §6.2) — "the single most novel, most
//  defensible fusion UX." Wraps the hero readout in a ring around/behind it that:
//    • TIGHTENS + BRIGHTENS on agreement (thin, saturated stroke), and
//    • WIDENS + DESATURATES on conflict (a thick, washed-out stroke — the ambient
//      analogue of VSUP: less certain ⇒ less vivid),
//  with a subtle state label ("signals agree / mixed / diverging"). The
//  `.insufficient` state renders NO judgment (a neutral, faint, thin ring and no
//  label) — a designed state, never an error.
//
//  The contribution the ring visualizes is the congruence engine's reliability-weighted
//  AROUSAL consensus (§4.4). It DISPLAYS agreement; it changes no reading.
//

#if os(visionOS)

import SwiftUI

struct CongruenceRingView<Content: View>: View {
    let congruence: CongruenceState
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(7)   // room between the hero's own edge and the outer ring
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(ringColor, lineWidth: ringWidth)
                    .animation(.smooth(duration: 0.4), value: ringWidth)
                    .animation(.smooth(duration: 0.4), value: consensus)
            )
            .overlay(alignment: .bottomTrailing) { label }
    }

    // MARK: Derived ring geometry / color

    /// Whether there is a real cross-channel judgment to render (≥2 voters). Otherwise
    /// the ring is a neutral, non-committal shape (no agreement claimed from one voice).
    private var isJudging: Bool {
        congruence.named != .insufficient && congruence.consensus != nil
    }

    private var consensus: Double { max(0, min(1, congruence.consensus ?? 0)) }

    /// Stroke width ∝ (1 − consensus): tight when agreeing, wide on conflict.
    private var ringWidth: CGFloat {
        guard isJudging else { return 1 }                 // neutral, no judgment
        return CGFloat(1.5 + (1 - consensus) * 6.5)       // 1.5 (agree) … 8 (conflict)
    }

    /// Hue: agreement = saturated green, divergence = warm amber. VSUP-GRADE: the hue itself
    /// DESATURATES + COARSENS as consensus falls (via `Color.vsup`), AND the whole stroke
    /// fades — the ambient VSUP idiom (less certain ⇒ less vivid). At full consensus
    /// `Color.vsup` returns the base hue unchanged, so a strong-agreement ring is unaffected.
    private var ringColor: Color {
        guard isJudging else { return .white.opacity(0.08) }   // neutral, no judgment
        let base: (h: Double, s: Double, b: Double) =
            congruence.named == .diverging ? (0.08, 0.9, 0.95) : (0.33, 0.85, 0.80)
        return Color.vsup(base, confidence: consensus).opacity(0.2 + 0.6 * consensus)
    }

    @ViewBuilder private var label: some View {
        if let text = HonestyPhrases.congruenceStateLabel(congruence.named) {
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
        }
    }
}

#endif
