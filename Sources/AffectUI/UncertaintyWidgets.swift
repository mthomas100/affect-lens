//
//  UncertaintyWidgets.swift
//  AffectLens
//
//  The UNCERTAINTY-DISPLAY GRAMMAR (PRD v2 §6.5) plus the pure helpers that
//  drive the toggleable FUSED AURA (§6.4). Two families live here:
//
//    DISPLAY widgets — they render EXISTING uncertainty; they invent no inference.
//      • VSUP           — Value-Suppressing Uncertainty Palette (Correll, Moritz &
//                         Heer 2018): a meter DESATURATES + COARSENS as its
//                         confidence falls ("less certain ⇒ less vivid").
//      • QuantileDotplot— Kay & Hullman 2016: ~15 stacked dots across a plausible
//                         interval, in place of one over-precise glowing dot. The
//                         spread is a RENDERING of (1 − confidence), never a new
//                         measurement (documented at the call site).
//      • ForkedMeter    — one bar that splits into two labeled prongs for a
//                         directionally-AMBIGUOUS state (the eyes lens's
//                         "engaged OR fatigued" fork, §3.2).
//      • MultiLabelChip — the conformal-set LOOK: "likely {A, B}" when the face
//                         posterior's top-2 margin is small (real conformal
//                         calibration arrives next item and feeds this same chip).
//
//    PURE AURA-MAPPING helpers (testable, `nonisolated`) — used only when the
//    fused-aura toggle is ON (default OFF; the face-driven aura is byte-identical
//    when off):
//      • StateOfMindRamp — valence → an Apple State-of-Mind-style purple→blue→orange
//                          hue ramp.
//      • CombinedArousal — reliability-weighted mean of the LIVE channels' arousal
//                          meters (r = 0 excluded).
//      • FusedAura       — the shared defaults key + the documented mapping numbers.
//
//  Honesty law (PRD §6.7): these REFLECT the reading; they never praise it. There is
//  no score, streak, or celebratory state anywhere in this file (the reward-loop ban).
//

#if os(visionOS) || os(macOS)

import SwiftUI

// MARK: - VSUP (Value-Suppressing Uncertainty Palette; Correll, Moritz & Heer 2018)

/// A pure color transform: as CONFIDENCE falls, a meter's hue is preserved but its
/// **saturation** drops (desaturate) and its **brightness** compresses toward a muted
/// mid — and the confidence is first QUANTIZED into a few bins so the change happens in
/// discrete, legible steps (the "coarsen" arm of VSUP: an uncertain reading earns fewer
/// distinguishable levels). At full confidence the base color is returned unchanged, so
/// a confident meter looks exactly as it did before VSUP.
nonisolated enum VSUP {
    /// Saturation multiplier floor at zero confidence — heavily washed out, but never a
    /// dead grey (so the hue still reads).
    static let saturationFloor = 0.15
    /// The muted mid-brightness a low-confidence color compresses toward.
    static let mutedMidBrightness = 0.55
    /// How many discrete confidence levels the "coarsen" step quantizes to. Four gives a
    /// clearly stepped desaturation without looking banded.
    static let confidenceBins = 4

    /// COARSEN: quantize a 0…1 confidence into `confidenceBins` discrete levels, returned
    /// as a value in {0, 1/(n−1), … , 1}. Monotone non-decreasing in `confidence`, and
    /// stable (a given confidence always maps to the same bin) — the property the
    /// self-test pins.
    static func coarsen(_ confidence: Double) -> Double {
        let c = min(1, max(0, confidence))
        let n = max(2, confidenceBins)
        let k = min(n - 1, Int(c * Double(n)))   // c == 1 lands in the top bin, not past it
        return Double(k) / Double(n - 1)
    }

    /// Desaturate + coarsen `base` by `confidence`. Hue is preserved; saturation scales
    /// down with the coarsened confidence (never UP as confidence falls — the monotonicity
    /// the self-test asserts); brightness compresses toward `mutedMidBrightness`. At
    /// `confidence == 1` this returns `base` exactly.
    static func adjust(_ base: (h: Double, s: Double, b: Double),
                       confidence: Double) -> (h: Double, s: Double, b: Double) {
        let step = coarsen(confidence)                          // 0 … 1, in discrete bins
        let satScale = saturationFloor + (1 - saturationFloor) * step
        let s = min(1, max(0, base.s * satScale))
        let b = min(1, max(0, mutedMidBrightness + (base.b - mutedMidBrightness) * step))
        return (base.h, s, b)
    }
}

extension Color {
    /// SwiftUI convenience for `VSUP.adjust` — a confidence-desaturated color from an
    /// `(h, s, b)` base. Pure; safe to call from any actor.
    nonisolated static func vsup(_ base: (h: Double, s: Double, b: Double),
                                 confidence: Double) -> Color {
        let a = VSUP.adjust(base, confidence: confidence)
        return Color(hue: a.h, saturation: a.s, brightness: a.b)
    }
}

// MARK: - QuantileDotplot (Kay & Hullman 2016)

/// A quantile dotplot: `dotCount` dots placed at the quantiles of a normal-ish spread
/// around `center`, stacked where they collide, spanning the plausible `range`. It is a
/// DISPLAY of the reading's uncertainty — the `spread` is handed in by the caller
/// (typically `(1 − confidence) × scale`), so this widget performs NO new inference. A
/// degenerate `spread` collapses to a tight cluster at `center` (no NaN).
struct QuantileDotplot: View {
    /// The point estimate the dots are centered on.
    let center: Double
    /// The half-width of the plausible interval (a normal σ). 0 ⇒ a tight cluster.
    let spread: Double
    /// The axis bounds the dots are clamped into and mapped across.
    let range: ClosedRange<Double>
    /// ~10–20 dots (Kay & Hullman find ~20 legible); 15 by default.
    var dotCount: Int = 15
    var tint: Color = .cyan

    var body: some View {
        Canvas { ctx, size in
            let values = Self.dotValues(center: center, spread: spread,
                                        range: range, count: dotCount)
            guard !values.isEmpty else { return }
            let span = max(1e-9, range.upperBound - range.lowerBound)
            // A dot per horizontal slot; collisions stack upward from the baseline.
            let dotR = min(size.height / 2, max(3, size.width / CGFloat(dotCount) / 2))
            let diameter = dotR * 2

            // Baseline + centre tick (the point estimate), faint.
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: size.height - 1))
            axis.addLine(to: CGPoint(x: size.width, y: size.height - 1))
            ctx.stroke(axis, with: .color(.white.opacity(0.12)), lineWidth: 1)
            let cx = CGFloat((center - range.lowerBound) / span) * size.width
            var tick = Path()
            tick.move(to: CGPoint(x: cx, y: 0))
            tick.addLine(to: CGPoint(x: cx, y: size.height))
            ctx.stroke(tick, with: .color(.white.opacity(0.18)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

            var columnStack: [Int: Int] = [:]
            for v in values {
                let x = CGFloat((v - range.lowerBound) / span) * size.width
                let col = Int((x / diameter).rounded(.down))
                let stack = columnStack[col, default: 0]
                columnStack[col] = stack + 1
                let dotX = (CGFloat(col) + 0.5) * diameter
                let dotY = size.height - dotR - CGFloat(stack) * diameter
                let rect = CGRect(x: dotX - dotR, y: dotY - dotR, width: diameter, height: diameter)
                ctx.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.85)))
            }
        }
    }

    /// The dot VALUES (before pixel-mapping) — factored out so it is directly testable.
    /// Dot `i` sits at quantile `p = (i + 0.5) / count` of `Normal(center, spread)`,
    /// clamped into `range`. With `spread == 0` every dot is `center` (a tight cluster).
    static func dotValues(center: Double, spread: Double,
                          range: ClosedRange<Double>, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let s = max(0, spread)
        var out: [Double] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let p = (Double(i) + 0.5) / Double(count)
            let z = s > 0 ? probit(p) : 0
            let v = min(range.upperBound, max(range.lowerBound, center + s * z))
            out.append(v)
        }
        return out
    }

    /// Inverse standard-normal CDF (probit), Acklam's rational approximation. Accurate to
    /// ~1e-9 across the central region the dotplot uses (p ≈ 0.03…0.97 for 15 dots).
    static func probit(_ p: Double) -> Double {
        if p <= 0 { return -Double.greatestFiniteMagnitude }
        if p >= 1 { return Double.greatestFiniteMagnitude }
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                 3.754408661907416e+00]
        let plow = 0.02425, phigh = 1 - 0.02425
        if p < plow {
            let q = (-2 * log(p)).squareRoot()
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                   ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        } else if p <= phigh {
            let q = p - 0.5, r = q * q
            return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
                   (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        } else {
            let q = (-2 * log(1 - p)).squareRoot()
            return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                    ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
    }
}

// MARK: - ForkedMeter (a designed ambiguity display)

/// One trunk that splits into two labeled prongs — the visual grammar for a
/// directionally-AMBIGUOUS reading (a single signal that supports two interpretations).
/// The trunk length shows `magnitude`; `balance ∈ [−1, +1]` tilts emphasis toward prong
/// A (negative) or prong B (positive). It commits to NEITHER reading — it shows both, by
/// design (PRD §6.5 forked/split-label meter).
struct ForkedMeter: View {
    /// 0…1 — how much signal there is (the trunk length).
    let magnitude: Double
    /// The negative-lean (top) prong label.
    let forkA: String
    /// The positive-lean (bottom) prong label.
    let forkB: String
    /// −1 (leans A) … 0 (evenly forked) … +1 (leans B).
    let balance: Double
    var tintA: Color = .cyan
    var tintB: Color = .orange

    var body: some View {
        let bal = min(1, max(-1, balance))
        let mag = min(1, max(0, magnitude))
        // Emphasis weights: the leaned side is bright/thick, the other stays present but faint.
        let aWeight = bal <= 0 ? 1.0 : max(0.25, 1 - bal)
        let bWeight = bal >= 0 ? 1.0 : max(0.25, 1 + bal)
        return VStack(alignment: .leading, spacing: 5) {
            Canvas { ctx, size in
                let midY = size.height / 2
                let splitX = size.width * (0.15 + 0.35 * mag)   // trunk grows with magnitude
                let tipX = size.width - 6

                var trunk = Path()
                trunk.move(to: CGPoint(x: 0, y: midY))
                trunk.addLine(to: CGPoint(x: splitX, y: midY))
                ctx.stroke(trunk, with: .color(.secondary),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round))

                var pa = Path()
                pa.move(to: CGPoint(x: splitX, y: midY))
                pa.addLine(to: CGPoint(x: tipX, y: 5))
                ctx.stroke(pa, with: .color(tintA.opacity(0.35 + 0.65 * aWeight)),
                           style: StrokeStyle(lineWidth: 2 + 3 * aWeight, lineCap: .round))

                var pb = Path()
                pb.move(to: CGPoint(x: splitX, y: midY))
                pb.addLine(to: CGPoint(x: tipX, y: size.height - 5))
                ctx.stroke(pb, with: .color(tintB.opacity(0.35 + 0.65 * bWeight)),
                           style: StrokeStyle(lineWidth: 2 + 3 * bWeight, lineCap: .round))
            }
            .frame(height: 38)

            HStack(alignment: .top) {
                Text(forkA).font(.caption2).foregroundStyle(tintA)
                Spacer(minLength: 8)
                Text(forkB).font(.caption2).foregroundStyle(tintB)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - MultiLabelChip (the conformal-set look)

/// "likely {A, B}" — a small chip that shows the top-2 posterior labels together when
/// they're too close to separate, and a single label when the top-1 clearly wins. This is
/// the conformal-set LOOK; the true calibrated set arrives next item and will feed the
/// same `topLabels` gate.
struct MultiLabelChip: View {
    /// The label set to render (1 ⇒ a single confident label; 2 ⇒ an ambiguous pair).
    let labels: [Emotion]

    /// The documented top-2 margin below which the pair is shown. 0.15 of posterior
    /// probability — narrow enough that a clear winner isn't hedged, wide enough that a
    /// near-tie honestly shows both.
    static let defaultMargin = 0.15

    /// The gate: `[top1]` when the top-2 margin ≥ `margin`, else `[top1, top2]`. Pure and
    /// directly testable; a display of the existing posterior, not new inference.
    static func topLabels(for distribution: EmotionDistribution,
                          margin: Double = defaultMargin) -> [Emotion] {
        let ranked = distribution.ranked
        guard let first = ranked.first else { return [] }
        guard ranked.count > 1 else { return [first.emotion] }
        let second = ranked[1]
        return (first.probability - second.probability) < margin
            ? [first.emotion, second.emotion]
            : [first.emotion]
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(HonestyPhrases.multiLabelPrefix)
            if labels.count > 1 {
                Text("{\(labels.map(\.displayName).joined(separator: ", "))}")
            } else {
                Text(labels.first?.displayName ?? "—")
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - StateOfMindRamp (fused-aura hue; Apple Health "State of Mind" palette)

/// Maps valence (−1 unpleasant … +1 pleasant) onto an Apple State-of-Mind-style hue ramp:
/// **purple (−1) → blue (0) → orange (+1)**, interpolated piecewise-linearly through three
/// documented anchors. Hue decreases monotonically from purple to orange, so the ordering
/// (purple hue > blue hue > orange hue) is a stable, testable property. Pure and clamped.
nonisolated enum StateOfMindRamp {
    /// Hue/sat/brightness anchor at valence −1 (unpleasant): a deep violet.
    static let unpleasant: (h: Double, s: Double, b: Double) = (0.78, 0.66, 0.85)
    /// Anchor at valence 0 (neutral): a calm blue.
    static let neutral: (h: Double, s: Double, b: Double) = (0.58, 0.55, 0.82)
    /// Anchor at valence +1 (pleasant): a warm orange.
    static let pleasant: (h: Double, s: Double, b: Double) = (0.08, 0.82, 0.96)

    /// Interpolated `(h, s, b)` for a valence in [−1, 1] (clamped).
    static func color(valence: Double) -> (h: Double, s: Double, b: Double) {
        let v = min(1, max(-1, valence))
        if v <= 0 {
            let t = v + 1                     // −1 → 0 (unpleasant), 0 → 1 (neutral)
            return lerp(unpleasant, neutral, t)
        } else {
            return lerp(neutral, pleasant, v) // 0 → 0 (neutral), 1 → 1 (pleasant)
        }
    }

    private static func lerp(_ a: (h: Double, s: Double, b: Double),
                             _ b: (h: Double, s: Double, b: Double),
                             _ t: Double) -> (h: Double, s: Double, b: Double) {
        let u = min(1, max(0, t))
        return (a.h + (b.h - a.h) * u,
                a.s + (b.s - a.s) * u,
                a.b + (b.b - a.b) * u)
    }
}

// MARK: - CombinedArousal (fused-aura pulse)

/// The reliability-weighted mean of the LIVE channels' arousal meters — the "combined
/// activation" the fused aura pulses on. A channel with no meter (nil) or reliability
/// `r ≤ 0` is EXCLUDED (a dark channel changes nothing); the remaining weights renormalize.
/// Returns `nil` when nothing contributes (the honest "nothing to fuse" state). Pure.
nonisolated enum CombinedArousal {
    /// - meters: each channel's published arousal `Meter` (nil ⇒ that channel isn't
    ///   contributing an arousal estimate).
    /// - reliabilities: each channel's live reliability `r_k`; absent or `≤ 0` ⇒ excluded.
    /// - Returns: `(value, confidence)` where `value` is the r-weighted mean arousal and
    ///   `confidence` is the mean reliability of the contributing channels (epistemic — how
    ///   trustworthy the inputs are, NOT how much they agree; agreement is the congruence
    ///   ring's job). `nil` when no channel contributes.
    static func compute(meters: [Channel: Meter?],
                        reliabilities: [Channel: Double]) -> (value: Double, confidence: Double)? {
        var weightedSum = 0.0
        var weight = 0.0
        var reliabilitySum = 0.0
        var count = 0
        for (channel, meterOpt) in meters {
            guard let meter = meterOpt else { continue }
            let r = reliabilities[channel] ?? meter.confidence
            guard r > 0 else { continue }
            weightedSum += r * meter.value
            weight += r
            reliabilitySum += r
            count += 1
        }
        guard count > 0, weight > 0 else { return nil }
        return (weightedSum / weight, reliabilitySum / Double(count))
    }
}

// MARK: - FusedAura (shared defaults key + documented mapping numbers)

/// The toggleable fused-aura mapping (PRD v2 §6.4). DEFAULT OFF — the face-driven aura is
/// byte-identical when this key is absent/false (the guard pattern in `ImmersiveView`).
/// All the aura's magic numbers live here so the mapping is auditable in one place.
nonisolated enum FusedAura {
    /// `@AppStorage` / `UserDefaults` key. Absent ⇒ `false` ⇒ the legacy face-driven aura.
    static let enabledKey = "aura.fusedMode.enabled"

    /// Pulse rate range (Hz): combined-arousal 0 → 0.2 Hz (a slow, calm breath), 1 → 1.2 Hz
    /// (a quicker, more activated pulse). A gentle periodic OPACITY modulation.
    static let pulseMinHz = 0.2
    static let pulseMaxHz = 1.2
    /// Max pulse depth (fraction of base opacity) at full arousal + full arousal-confidence.
    static let pulseMaxDepth = 0.5

    /// A recent BOCPD `.stateShift` briefly SWELLS the aura: a subtle bump that decays over
    /// `swellDuration` with time-constant `swellTau`, peaking at `+swellPeak` opacity.
    static let swellDuration = 1.5
    static let swellTau = 0.5
    static let swellPeak = 0.10

    /// Opacity envelope: base = `opacityFloor + opacitySpan × confidence` (dim + soft when
    /// unsure — "blurry is honestly unsure"; edge-softness is folded into opacity because
    /// the material's blur knob is heavy). Clamped to `opacityCeiling` after pulse + swell.
    static let opacityFloor = 0.04
    static let opacitySpan = 0.16
    static let opacityCeiling = 0.35
}

#endif
