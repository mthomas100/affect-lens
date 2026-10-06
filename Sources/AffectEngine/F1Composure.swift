//
//  F1Composure.swift
//  AffectLens
//
//  F1 — COMPOSURE-UNDER-LOAD / CHANNEL-DIVERGENCE (US-C10,
//  PRD v2 §4.2 F1). The construct no single lens can measure: a Persona face that
//  reads CALM while a behavioral arousal proxy diverges UPWARD. Anchor: Gross &
//  Levenson 1993 (JPSP 64:970) — expressive suppression shows up as a flat face while
//  arousal rises.
//
//  ⚠️ THE HONEST FRAMING (never soften it). Gross's arousal Δ was ELECTRODERMAL. This
//  app has NO autonomic channel — no skin-conductance, no heart-rate, no pupils
//  (§2.2). So F1 does NOT detect suppression or "concealment." It detects the
//  DIVERGENCE OF BEHAVIORAL AROUSAL PROXIES from a calm face — the eyes' signed
//  blink-rate delta, hand energy / self-touch, head-motion energy, and vocal
//  F0 / intensity, whichever are live (see `proxySources`). That is a
//  proxy-of-a-proxy, and it is framed as exactly that: "composed but activated;
//  possible regulation" — NEVER "concealing," NEVER "suppression detected." The 15 Hz
//  fan-out deliberately cannot sample micro-expressions, which is the boundary that
//  keeps F1 clear of lie-detection (refused, §4.5 #3).
//
//  THE CONJUNCTION IS THE CONSTRUCT (mirror F7). A calm face WITHOUT an elevated proxy
//  is just calm; an elevated proxy WITHOUT a calm face is just arousal. Only the
//  co-occurrence is composure-under-load, so the score is a geometric mean that
//  collapses to 0 the instant either component is absent.
//
//  THE LOW-EXPRESSER GATE (§5.4, mandatory — what keeps F1 honest). F1's
//  signature false positive is a naturally-flat face (a low-expresser reads "calm" all
//  the time). So when the per-Persona expressive separability is narrow (or unknown),
//  F1 WIDENS: confidence multiplied down, the activation bar raised, and the output
//  MARKED so the disambiguation ladder shows the unresolved confound. It never hard-
//  blocks — a strong divergence still surfaces, tentatively.
//
//  DIMENSIONAL VETO. F1 is a NAMED STATE + insight + ladder only. It does NOT move the
//  published valence/arousal (`FusionOutput.valence`/`arousal` stay nil; the hub leaves
//  `EmotionEngine.vaTransform` nil). Dimensional blending is a later decision.
//

#if os(visionOS) || os(macOS)

import Foundation

/// F1 Composure-under-load — the `F×E` (→ +H/V) windowed-MVV fused construct. A
/// `nonisolated` value type: its metadata, `fuse` math, and ladder builder are pure and
/// self-testable off the main actor, per the project's MainActor-default regime.
nonisolated struct F1ComposureMode: FusionMode {

    // MARK: Identity / honesty metadata

    var id: String { ConstructID.composure }          // toggle key: fusion.f1-composure.enabled
    var title: String { "Composure under load" }
    /// F×E windowed MVV. Written generically over "arousal-proxy features present" (see
    /// `proxySources`), so a later item that adds hands/voice to `requires` needs no
    /// change to the fusion math — those proxies join automatically.
    var requires: Set<Channel> { [.face, .eyes] }

    var rationale: String { HonestyPhrases.composureRationale }
    var confound: String { HonestyPhrases.composureConfound }
    var citation: String? { "Gross & Levenson 1993" }
    /// F1 may claim LESS trust than F7 (0.7): it is a proxy-of-a-proxy — behavioral
    /// arousal proxies standing in for the autonomic arousal the hardware cannot sense —
    /// so it is epistemically weaker than F7's directly-observed task friction. Ceiling
    /// 0.6 < 0.7. (In practice the eyes' modest blink-arousal confidence caps the fused
    /// value well below this today; the ceiling binds once stronger proxies join.)
    var confidenceCeiling: Double { 0.6 }

    // MARK: Hysteresis (documented band + dwell, ~15 Hz ticks)

    /// Composure-under-load is a SUSTAINED regulation state (Gross's suppression is a
    /// maintained effort), and its confound (a naturally still face) is strong — so the
    /// latch demands a LONGER sustained divergence than F7 before it surfaces:
    ///   • enter 0.45 / exit 0.28 — a real hysteresis band, so a score wandering the
    ///     middle can't chatter the label;
    ///   • enter-dwell 45 ticks ≈ 3 s at the fan-out's ~15 Hz — a momentary calm-with-a-
    ///     blink can't trip it; the divergence must PERSIST;
    ///   • exit-dwell 15 ticks ≈ 1 s — once the proxy settles or the face emotes, drop
    ///     the (now stale) "composed but activated" attribution promptly.
    var hysteresis: ConstructHysteresis {
        ConstructHysteresis(enter: 0.45, exit: 0.28, enterDwellTicks: 45, exitDwellTicks: 15)
    }

    // MARK: Tunables (documented thresholds — all in the readings' own units)

    /// A Persona valence within ±`valenceDeadband` reads "near-neutral."
    static let valenceDeadband = 0.15
    /// Negativity/positivity past the deadband that drives the valence-calmness to 0 —
    /// by |v| ≈ 0.5 the face is clearly emoting, so calm on that axis is 0.
    static let valenceSpan = 0.35
    /// Expression intensity at/below this reads calm on the intensity axis…
    static let intensityDeadband = 0.15
    /// …and this much intensity past the deadband drives intensity-calmness to 0.
    static let intensitySpan = 0.35
    /// A construct is at most as trustworthy as its WEAKEST channel, discounted further
    /// because a conjunction of two proxies is inherently less certain (mirror F7).
    static let confidenceDamping = 0.85
    /// The calm-face contribution at/above which the ladder's L0 rung reads RESOLVED
    /// ("the face is more calm than not").
    static let calmResolvedThreshold = 0.5

    // MARK: Low-expresser gate (§5.4 widener)

    /// Face expressive-separability below this ⇒ the reading is held TENTATIVE (the
    /// output is marked, the ladder shows the confound). 0.35 corresponds — via
    /// `BaselineStore`'s `1 − exp(−meanMAD/0.02)` — to a narrow calibration spread
    /// (meanMAD ≈ 0.0086 IOD): a genuinely low-expressive Persona baseline.
    static let lowSeparabilityThreshold = 0.35
    /// The SCORE gate floor: at separability 0 the score is scaled to this fraction —
    /// raising the EFFECTIVE activation bar (equivalent, for a fixed latch band, to
    /// lifting `enter` 0.45 → 0.45/0.70 ≈ 0.64). Mild enough that a strong divergence
    /// still surfaces; ramps to 1 as separability → 1.
    static let scoreGateFloor = 0.70
    /// The CONFIDENCE gate floor: at separability 0 confidence is multiplied down to
    /// this fraction (a substantial cut); ramps to 1 as separability → 1.
    static let confGateFloor = 0.40
    /// Separability assumed when the reading carries none (a direct unit call). The hub
    /// ALWAYS injects the real value in the running app, so this only affects tests that
    /// don't set it — treated as ungated (1.0) so the base rule is exercised cleanly.
    static let ungatedSeparability = 1.0

    // MARK: Proxy sources (the documented arousal-proxy feature list — future-proof)

    /// The behavioral arousal proxies F1 reads, each as an UPWARD delta from the user's
    /// own baseline, normalized to [0, 1] by its `scale`. The extraction in `fuse`
    /// iterates this list over whatever readings are present, so hands/voice "Just Work"
    /// the moment those channels land — no fusion-math change.
    ///   • eyes/`blinkRate`: the signed blink-rate Δ per minute; the POSITIVE side is
    ///     exactly `EyeChannel.signedArousalDelta`'s positive side (same 12/min scale).
    ///   • hands/`gestureEnergy` (m/s Δ from resting) + hands/`selfTouchRate` (events/min) are
    ///     now TUNED by US-D13a to the hands channel's real scales — the literals below equal
    ///     `HandsChannel.energyDeltaScale` (0.5) and `HandsChannel.selfTouchRateScale` (3.0)
    ///     (kept literals because `HandsChannel`'s statics are MainActor-isolated and this list
    ///     is nonisolated, exactly as the eyes 12.0 mirrors `EyeChannel.arousalDeltaScale`).
    ///   • head/`headMotionEnergy` (rad/s Δ from resting) is TUNED by US-D13b to the head
    ///     channel's real scale — the literal equals `HeadChannel.energyDeltaScale` (1.0),
    ///     kept a literal for the same nonisolated reason as the hands/eyes scales above.
    ///   • voice/`vocalF0` (Hz Δ from the voiced baseline) + voice/`vocalIntensity` (RMS Δ)
    ///     are TUNED to the voice channel's real scales — the literals equal
    ///     `VoiceChannel.f0DeltaScale` (60 Hz → full) and `VoiceChannel.intensityDeltaScale`
    ///     (0.08 RMS → full), kept literals for the same nonisolated reason. (The PRD F1
    ///     spec names BOTH: "vocal F0/intensity↑".)
    static let proxySources: [(channel: Channel, feature: FeatureKey, signal: SignalRef, scale: Double)] = [
        (.eyes,  .blinkRate,        .blinkRate,        12.0),
        (.hands, .gestureEnergy,    .gestureEnergy,    0.5),   // == HandsChannel.energyDeltaScale (m/s Δ → full)
        (.hands, .selfTouchRate,    .selfTouchRate,    3.0),   // == HandsChannel.selfTouchRateScale (events/min → full)
        (.head,  .headMotionEnergy, .headMotionEnergy, 1.0),   // == HeadChannel.energyDeltaScale (rad/s Δ → full)
        (.voice, .vocalF0,          .vocalF0,          60.0),  // == VoiceChannel.f0DeltaScale (Hz Δ → full)
        (.voice, .vocalIntensity,   .vocalIntensity,   0.08)   // == VoiceChannel.intensityDeltaScale (RMS Δ → full)
    ]

    // MARK: Fuse

    /// Fuse the current per-channel readings into F1's output, or `nil` if the required
    /// face/eyes signals aren't present this tick (never a fabricated read — §4.2). The
    /// separability the low-expresser gate needs rides on the face reading
    /// (`expressiveSeparability`, injected by the hub); absent ⇒ ungated.
    func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
        guard let face = readings[.face], face.availability != .unavailable,
              let eyes = readings[.eyes], eyes.availability != .unavailable
        else { return nil }

        // CALM-FACE component — the conjunction of a near-neutral valence AND a low
        // expression intensity, each mapped to a [0,1] calm-ness. Geometric mean, so a
        // clearly-emoting face on EITHER axis collapses calm toward 0 (a calm face must
        // be calm on both).
        let v = face.valence?.value ?? 0
        let valenceCalm = clamp01(1 - (abs(v) - Self.valenceDeadband) / Self.valenceSpan)
        let intensityCalm = clamp01(1 - (face.intensity - Self.intensityDeadband) / Self.intensitySpan)
        let calmFace = (valenceCalm * intensityCalm).squareRoot()

        // PROXY-ELEVATION component — the MAX upward divergence across the available
        // behavioral arousal proxies. MAX, not a reliability-weighted mean: F1 fires on
        // ANY proxy diverging up from a calm face, and a mean would let a calm hand
        // DILUTE a genuinely racing blink — masking the divergence we exist to catch. A
        // lone spuriously-spiking proxy is guarded by the multi-second enter dwell and
        // the calm-face conjunction. `contributions` records each present proxy channel
        // for the legible-fusion audit (M5).
        var contributions: [Channel: Double] = [.face: calmFace]
        var evidence: [SignalRef] = calmFace > 0 ? [.valence] : []
        var proxyElevation = 0.0
        for src in Self.proxySources {
            guard let r = readings[src.channel], r.availability != .unavailable,
                  let raw = r.features[src.feature] else { continue }
            let elevation = clamp01(max(0, raw) / src.scale)       // only UPWARD counts
            contributions[src.channel] = max(contributions[src.channel] ?? 0, elevation)
            if elevation > 0 {
                proxyElevation = max(proxyElevation, elevation)
                if !evidence.contains(src.signal) { evidence.append(src.signal) }
            }
        }

        // RAW SCORE — geometric mean: the CONJUNCTION is the construct. Either component
        // at 0 forces the score to 0 (neither a calm face alone nor a racing proxy alone
        // is composure-under-load).
        let rawScore = (calmFace * proxyElevation).squareRoot()

        // LOW-EXPRESSER GATE (§5.4). Separability narrow/unknown ⇒ WIDEN: attenuate the
        // score (raise the effective activation bar), multiply confidence down, and MARK
        // the output. Continuous, never a hard block.
        let separability = clamp01(face.expressiveSeparability ?? Self.ungatedSeparability)
        let scoreGate = Self.scoreGateFloor + (1 - Self.scoreGateFloor) * separability
        let confGate = Self.confGateFloor + (1 - Self.confGateFloor) * separability
        let separabilityLimited = separability < Self.lowSeparabilityThreshold
        let score = rawScore * scoreGate

        // CONFIDENCE — min of the required channels' confidences (face's valence meter;
        // eyes' deliberately-modest blink arousal), damped, gated by separability, capped
        // at the ceiling. Epistemic — kept SEPARATE from `score`.
        let faceConf = face.valence?.confidence ?? face.arousal?.confidence ?? 0
        let eyesConf = eyes.arousal?.confidence ?? 0
        let confidence = min(confidenceCeiling,
                             min(faceConf, eyesConf) * Self.confidenceDamping * confGate)

        return FusionOutput(
            namedState: nil,                    // the hub names it once latched
            valence: nil, arousal: nil,         // F1 does NOT move the published V/A
            contributions: contributions,
            confidence: confidence,
            score: score,
            evidence: evidence,
            separabilityLimited: separabilityLimited
        )
    }

    // MARK: Disambiguation ladder (§6.6 — the honesty widget)

    /// F1's rungs for the current published state — the progressive-narrowing stepper
    /// (§6.6). Delegates to the pure `ladder(output:isActive:)` so the mapping is
    /// self-testable without a hub.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep] {
        Self.ladder(output: state.output, isActive: state.isActive)
    }

    /// Pure builder: the mode's live state → the ladder rungs. `nil` output (starved /
    /// off / no tick yet) ⇒ no ladder. Order narrows the claim: calm face → proxy
    /// elevated → divergence sustained; a tentative rung appears only under the §5.4
    /// gate; and a PERMANENT ruled-out rung refuses the concealment/lie-detection
    /// reading (greyed + struck — never a claim the app makes).
    static func ladder(output: FusionOutput?, isActive: Bool) -> [LadderStep] {
        guard let out = output else { return [] }
        let calm = (out.contributions[.face] ?? 0) >= calmResolvedThreshold
        let proxyUp = out.contributions.contains { $0.key != .face && $0.value > 0 }

        var steps: [LadderStep] = []
        func add(_ claim: String, _ status: LadderStep.Status) {
            steps.append(LadderStep(id: steps.count, claim: claim, status: status))
        }

        add(HonestyPhrases.composureLadderL0,
            calm ? .resolved : .ambiguous(HonestyPhrases.composureLadderL0Fork))
        add(HonestyPhrases.composureLadderL1,
            proxyUp ? .resolved : .ambiguous(HonestyPhrases.composureLadderL1Fork))
        add(HonestyPhrases.composureLadderL2,
            isActive ? .resolved : .ambiguous(HonestyPhrases.composureLadderL2Fork))
        if out.separabilityLimited {
            add(HonestyPhrases.composureLadderTentative,
                .ambiguous(HonestyPhrases.composureLadderTentativeFork))
        }
        add(HonestyPhrases.composureLadderRuledOut,
            .ruledOut(HonestyPhrases.composureLadderRuledOutReason))
        return steps
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

#endif
