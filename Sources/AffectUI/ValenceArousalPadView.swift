//
//  ValenceArousalPadView.swift
//  AffectLens
//
//  The circumplex model of affect: a 2D pad plotting valence (x) against
//  arousal (y) with a fading trail of recent readings.
//

import SwiftUI

#if os(visionOS)

/// One channel's GHOST VOTE on the circumplex (US-C10a, PRD v2 §6.2). A per-channel
/// arousal (and, for the face, valence) vote drawn behind the fused dot, its opacity
/// the channel's live reliability `r_k` — so the visualization doubles as an AUDIT of
/// the fusion math. Arousal-only channels carry `valence == nil` and render as AXIS
/// MARKERS on the vertical arousal axis (never a fabricated valence — the honesty law
/// of this view).
nonisolated struct PadGhostVote {
    /// The voting channel.
    var channel: Channel
    /// The vote's valence, or `nil` for an arousal-only channel (⇒ axis marker).
    var valence: Double?
    /// The vote's arousal position on the axis (−1…1).
    var arousal: Double
    /// The channel's live reliability `r_k` (0…1) ⇒ marker opacity (the audit property).
    var reliability: Double
    /// Marker/line hue (face = its emotion hue; arousal-only channels = a channel tint).
    var tint: Color
}

struct ValenceArousalPadView: View {
    let valence: Double
    let arousal: Double
    /// Recent (valence, arousal) points, oldest first, each in −1…1.
    let trail: [CGPoint]
    let color: Color
    /// Per-channel ghost votes (US-C10a §6.2). EMPTY by default, so every existing call
    /// site renders EXACTLY as before; the fusion dashboard passes the live votes.
    var ghostVotes: [PadGhostVote] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Circumplex — Valence · Arousal")
                .font(.footnote.bold())
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    Canvas { ctx, sz in
                        // Axes.
                        var axes = Path()
                        axes.move(to: CGPoint(x: sz.width / 2, y: 0))
                        axes.addLine(to: CGPoint(x: sz.width / 2, y: sz.height))
                        axes.move(to: CGPoint(x: 0, y: sz.height / 2))
                        axes.addLine(to: CGPoint(x: sz.width, y: sz.height / 2))
                        ctx.stroke(axes, with: .color(.white.opacity(0.15)), lineWidth: 1)

                        // Unit circle guide.
                        let inset = CGRect(x: sz.width * 0.08, y: sz.height * 0.08,
                                           width: sz.width * 0.84, height: sz.height * 0.84)
                        ctx.stroke(Path(ellipseIn: inset), with: .color(.white.opacity(0.10)), lineWidth: 1)

                        // Fading trail.
                        if trail.count > 1 {
                            for i in 1..<trail.count {
                                var segment = Path()
                                segment.move(to: Self.mapped(trail[i - 1], in: sz))
                                segment.addLine(to: Self.mapped(trail[i], in: sz))
                                let alpha = 0.45 * Double(i) / Double(trail.count)
                                ctx.stroke(segment, with: .color(color.opacity(alpha)), lineWidth: 2)
                            }
                        }

                        // Per-channel GHOST votes + pull-lines (US-C10a §6.2), drawn
                        // BEHIND the fused (main) dot. Opacity ∝ each vote's reliability
                        // r_k (the audit property). Arousal-only channels (valence == nil)
                        // are AXIS MARKERS on the vertical arousal axis — never given a
                        // fabricated valence (the honesty law of this view).
                        let mainPt = Self.mapped(CGPoint(x: valence, y: arousal), in: sz)
                        for g in ghostVotes {
                            let gx = g.valence ?? 0        // arousal-only ⇒ on the axis
                            let gp = Self.mapped(CGPoint(x: gx, y: g.arousal), in: sz)
                            let op = 0.15 + 0.7 * max(0, min(1, g.reliability))
                            // Faint pull-line toward the fused dot.
                            var pull = Path()
                            pull.move(to: gp)
                            pull.addLine(to: mainPt)
                            ctx.stroke(pull, with: .color(g.tint.opacity(op * 0.4)), lineWidth: 1)
                            if g.valence == nil {
                                // Axis marker — a small hollow diamond (no valence).
                                let s: CGFloat = 5
                                var diamond = Path()
                                diamond.move(to: CGPoint(x: gp.x, y: gp.y - s))
                                diamond.addLine(to: CGPoint(x: gp.x + s, y: gp.y))
                                diamond.addLine(to: CGPoint(x: gp.x, y: gp.y + s))
                                diamond.addLine(to: CGPoint(x: gp.x - s, y: gp.y))
                                diamond.closeSubpath()
                                ctx.stroke(diamond, with: .color(g.tint.opacity(op)), lineWidth: 1.5)
                            } else {
                                // Channel ghost dot (e.g. face, in its emotion hue).
                                let r: CGFloat = 4.5
                                let rect = CGRect(x: gp.x - r, y: gp.y - r, width: 2 * r, height: 2 * r)
                                ctx.fill(Path(ellipseIn: rect), with: .color(g.tint.opacity(op)))
                            }
                        }
                    }

                    Circle()
                        .fill(color)
                        .frame(width: 14, height: 14)
                        .shadow(color: color.opacity(0.9), radius: 8)
                        .position(Self.mapped(CGPoint(x: valence, y: arousal), in: size))
                        .animation(.smooth(duration: 0.25), value: valence)
                        .animation(.smooth(duration: 0.25), value: arousal)

                    // Quadrant labels.
                    Text("Excited").font(.caption2).foregroundStyle(.tertiary)
                        .position(x: size.width / 2, y: 10)
                    Text("Calm").font(.caption2).foregroundStyle(.tertiary)
                        .position(x: size.width / 2, y: size.height - 10)
                    Text("−").font(.caption2).foregroundStyle(.tertiary)
                        .position(x: 10, y: size.height / 2)
                    Text("+").font(.caption2).foregroundStyle(.tertiary)
                        .position(x: size.width - 10, y: size.height / 2)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Map circumplex coordinates (−1…1, y-up) into view space.
    private static func mapped(_ va: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (va.x + 1) / 2 * size.width,
            y: (1 - (va.y + 1) / 2) * size.height
        )
    }
}
#endif
