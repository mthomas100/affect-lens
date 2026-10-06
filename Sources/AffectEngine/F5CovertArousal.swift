//
//  F5CovertArousal.swift
//  AffectLens
//
//  F5 — CORROBORATED AROUSAL across multiple channels (US-D14b, PRD v2 §4.2 F5). The
//  arousal-specific SIBLING of F1 (composure-under-load): F1 marries a CALM face to ONE
//  behavioral arousal proxy; F5 drops the face entirely and asks whether ≥2 NON-FACE arousal
//  proxies are elevated TOGETHER — corroborated arousal, regardless of the face state.
//
//  DISTINCT FROM F1 (state it plainly). F1 REQUIRES the calm face (its whole point is the
//  divergence FROM a composed face). F5 has NO calm-face requirement — it fires on multiple
//  agreeing NON-FACE channels whether the face is calm, expressive, or absent. So an
//  expressive face does NOT block F5 (the opposite of F1). Anchor: Kreibig 2010 (arousal
//  manifests across multiple response channels) — corroboration across channels, not one.
//
//  THE ≥2 GUARD (the construct). One elevated proxy is just that one channel's arousal (F5
//  refuses to speak from a single channel). TWO or more elevated NON-FACE proxies, held
//  together, are corroborated arousal. `fuse` reuses F1's SAME behavioral-proxy list
//  (`F1ComposureMode.proxySources` — eyes blink-rate↑, hand energy / self-touch↑, head
//  motion↑, vocal F0↑) but WITHOUT the calm-face gate, and requires ≥2 DISTINCT proxy
//  CHANNELS elevated concurrently. With only the eyes lens on there is no second channel — the
//  availability / ladder copy says "needs a second arousal channel" (the honest low-signal state).
//
//  HONESTY. The surfaced state is "corroborated arousal (multiple channels)" — arousal is a
//  LEVEL, never a direction or a felt emotion, and never "concealment" (this is a divergence
//  of behavioral proxies, not a hidden-feeling claim — the F1 boundary, §4.5 #3). The internal
//  name "covert / suppressed arousal" never reaches the user (it would over-claim concealment).
//
//  DIMENSIONAL VETO. F5 is a NAMED STATE + insight + ladder only. It does NOT move the
//  published valence/arousal (`FusionOutput.valence`/`arousal` stay nil; the hub leaves
//  `EmotionEngine.vaTransform` nil). Off by default; ceiling ≤ 0.6.
//

#if os(visionOS) || os(macOS)

import Foundation

/// F5 Corroborated arousal — the E×(H/Hd/V) windowed construct (PRD §4.2 F5). A `nonisolated`
/// value type: its metadata, `fuse` math, and ladder builder are pure and self-testable off the
/// main actor, per the project's MainActor-default regime.
nonisolated struct F5CovertArousalMode: FusionMode {

    // MARK: Identity / honesty metadata

    var id: String { ConstructID.covertArousal }        // toggle key: fusion.f5-covert-arousal.enabled
    var title: String { "Corroborated arousal (multiple channels)" }
    /// Availability requires the EYES lens; the ≥2-proxy-CHANNEL requirement is an IN-FUSE
    /// guard (below), NOT an availability gate — so with only eyes on the mode is available but
    /// quiescent, and the ladder says "needs a second arousal channel" (the honest low-signal
    /// state). Hands / head / voice join the corroboration automatically the moment they are live.
    var requires: Set<Channel> { [.eyes] }

    var rationale: String { HonestyPhrases.covertArousalRationale }
    var confound: String { HonestyPhrases.covertArousalConfound }
    var citation: String? { "Kreibig 2010" }
    /// A proxy-of-proxies corroboration (behavioral arousal channels, no autonomic sensor) —
    /// the same epistemic weakness as F1, so the ceiling matches F1's 0.6.
    var confidenceCeiling: Double { 0.6 }

    // MARK: Hysteresis (documented band + dwell, ~15 Hz ticks)

    /// A SUSTAINED corroboration (a momentary co-spike of two channels can't trip it): enter
    /// 0.40 / exit 0.25 is a real band; enter-dwell 30 ≈ 2 s; exit-dwell 15 ≈ 1 s.
    var hysteresis: ConstructHysteresis {
        ConstructHysteresis(enter: 0.40, exit: 0.25, enterDwellTicks: 30, exitDwellTicks: 15)
    }

    // MARK: Tunables (documented thresholds)

    /// A per-channel proxy elevation at/above which that channel COUNTS as "elevated" (a
    /// contributor to the ≥2 guard). A small floor so tracking jitter isn't a corroboration.
    static let elevationFloor = 0.10
    /// The number of DISTINCT elevated proxy channels required to speak at all (the guard).
    static let minProxyChannels = 2
    /// A construct is at most as trustworthy as its weakest contributing channel, discounted
    /// because a corroboration of behavioral proxies is inherently uncertain (mirror F1).
    static let confidenceDamping = 0.85

    // MARK: Fuse

    /// Fuse the current readings into F5's corroborated-arousal score, or `nil` when the eyes
    /// lens isn't live this tick (never a fabricated read — §4.2). Reads `.eyes` (required) plus
    /// whichever of `.hands` / `.head` / `.voice` are live, via F1's proxy-source list. Score is
    /// 0 (never latches) unless ≥2 DISTINCT proxy channels are elevated — the in-fuse guard. Pure
    /// over inputs; NO face is read (the calm-face-free F1 sibling).
    func fuse(_ readings: [Channel: ChannelReading]) -> FusionOutput? {
        guard let eyes = readings[.eyes], eyes.availability != .unavailable else { return nil }
        _ = eyes   // required for availability; its blink proxy is read below via proxySources

        // Per-CHANNEL max upward elevation across F1's SAME behavioral arousal proxies — but
        // WITHOUT F1's calm-face component (the distinction). Track the driving signal +
        // confidence per channel for the evidence / confidence below.
        var hits: [Channel: (elevation: Double, signal: SignalRef, conf: Double)] = [:]
        for src in F1ComposureMode.proxySources {
            guard let r = readings[src.channel], r.availability != .unavailable,
                  let raw = r.features[src.feature] else { continue }
            let elevation = clamp01(max(0, raw) / src.scale)   // only UPWARD divergence counts
            if elevation > (hits[src.channel]?.elevation ?? 0) {
                hits[src.channel] = (elevation, src.signal, r.arousal?.confidence ?? r.quality)
            }
        }

        // The elevated proxy CHANNELS (≥ the floor) — the contributors to the guard.
        let elevated = hits.filter { $0.value.elevation >= Self.elevationFloor }

        // CONTRIBUTIONS + EVIDENCE — only the elevated channels (the legible-fusion audit +
        // ladder count). Evidence sorted for determinism.
        var contributions: [Channel: Double] = [:]
        var evidence: [SignalRef] = []
        for (ch, hit) in elevated {
            contributions[ch] = hit.elevation
            evidence.append(hit.signal)
        }
        evidence.sort { $0.rawValue < $1.rawValue }

        // SCORE — the ≥2 guard: below `minProxyChannels` distinct elevated channels the score
        // is 0 (never latches — a single channel is just that channel's arousal). At/above it,
        // the GEOMETRIC MEAN of the two STRONGEST elevations — high only when two channels genuinely
        // agree (a lone strong channel with a weak second stays modest).
        let sorted = elevated.values.map(\.elevation).sorted(by: >)
        let score = sorted.count >= Self.minProxyChannels ? (sorted[0] * sorted[1]).squareRoot() : 0

        // CONFIDENCE — the WEAKEST contributing channel's confidence, damped, capped. Epistemic.
        let baseConf = elevated.values.map(\.conf).min() ?? 0
        let confidence = min(confidenceCeiling, baseConf * Self.confidenceDamping)

        return FusionOutput(
            namedState: nil,                    // the hub names it once latched
            valence: nil, arousal: nil,         // F5 does NOT move the published V/A
            contributions: contributions,
            confidence: confidence,
            score: score,
            evidence: evidence
        )
    }

    // MARK: Disambiguation ladder (§6.6 — the honesty widget)

    /// F5's rungs for the current published state. Delegates to the pure
    /// `ladder(output:isActive:)` so the mapping is self-testable without a hub.
    nonisolated func ladder(for state: FusionModeState) -> [LadderStep] {
        Self.ladder(output: state.output, isActive: state.isActive)
    }

    /// Pure builder: the mode's live state → the narrowing ladder. L0 the ≥2-channel guard
    /// ("needs a second arousal channel" when unmet) → L1 sustained → the corroborated-arousal
    /// verdict. `nil` output ⇒ no ladder.
    static func ladder(output: FusionOutput?, isActive: Bool) -> [LadderStep] {
        guard let out = output else { return [] }
        let enough = out.contributions.count >= minProxyChannels

        var steps: [LadderStep] = []
        func add(_ claim: String, _ status: LadderStep.Status) {
            steps.append(LadderStep(id: steps.count, claim: claim, status: status))
        }

        add(HonestyPhrases.covertArousalL0,
            enough ? .resolved : .ambiguous(HonestyPhrases.covertArousalNeedsSecond))
        add(isActive ? HonestyPhrases.covertArousalVerdict : HonestyPhrases.covertArousalL1,
            isActive ? .resolved : .ambiguous(HonestyPhrases.covertArousalL1Fork))
        return steps
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

#endif
