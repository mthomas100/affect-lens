//
//  ActionUnits.swift
//  AffectLens
//
//  FACS (Facial Action Coding System) Action Unit estimation from facial
//  metrics. Each AU intensity is computed as a calibrated delta from the
//  user's neutral baseline, scaled into 0…1. Baseline calibration is what
//  makes the downstream emotion classification accurate for a specific face.
//

import Foundation

#if os(visionOS) || os(macOS)

/// The Action Units the engine estimates from 2D landmarks.
enum ActionUnit: String, CaseIterable, Sendable, Identifiable {
    case au1   // inner brow raiser
    case au2   // outer brow raiser
    case au4   // brow lowerer
    case au5   // upper lid raiser
    case au6   // cheek raiser (proxy: lid narrowing during smile)
    case au7   // lid tightener (narrowing without smile)
    case au9   // nose wrinkler / upper lip raiser proxy
    case au12  // lip corner puller (smile)
    case au15  // lip corner depressor
    case au20  // lip stretcher
    case au23  // lip tightener / pressor
    case au25  // lips part
    case au26  // jaw drop
    case auUnilateral // asymmetric corner pull (smirk — contempt evidence)

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .au1: return "AU1"
        case .au2: return "AU2"
        case .au4: return "AU4"
        case .au5: return "AU5"
        case .au6: return "AU6"
        case .au7: return "AU7"
        case .au9: return "AU9"
        case .au12: return "AU12"
        case .au15: return "AU15"
        case .au20: return "AU20"
        case .au23: return "AU23"
        case .au25: return "AU25"
        case .au26: return "AU26"
        case .auUnilateral: return "Asym"
        }
    }

    var facsName: String {
        switch self {
        case .au1: return "Inner Brow Raiser"
        case .au2: return "Outer Brow Raiser"
        case .au4: return "Brow Lowerer"
        case .au5: return "Upper Lid Raiser"
        case .au6: return "Cheek Raiser"
        case .au7: return "Lid Tightener"
        case .au9: return "Nose Wrinkler"
        case .au12: return "Lip Corner Puller"
        case .au15: return "Corner Depressor"
        case .au20: return "Lip Stretcher"
        case .au23: return "Lip Presser"
        case .au25: return "Lips Part"
        case .au26: return "Jaw Drop"
        case .auUnilateral: return "Unilateral Smirk"
        }
    }
}

typealias AUVector = [ActionUnit: Double]

/// Runtime-tunable parameters for the AU4 head-pitch correction (US-A0).
///
/// Looking DOWN foreshortens the brow-to-eye distance, which inflates the
/// apparent brow-lower and fakes AU4 → a false "anger" read (the Witkower &
/// Tracy 2019/2020 "AU4 imposter"; PRD §3.4, §7.2). This bundles the
/// correction's tunables as a plain value type: the actual `UserDefaults` read
/// lives at the call site (`EmotionEngine`), keeping `AUComputer` pure so the
/// self-tests can drive it deterministically.
nonisolated struct PitchCorrection: Sendable {
    /// Fraction of AU4 removed per radian of downward pitch past the deadband.
    var slope: Double
    /// Downward pitch (radians) below which no correction is applied — absorbs
    /// the small incidental head-down of ordinary expression.
    var deadband: Double
    /// Hard cap on the fraction of AU4 the correction may remove, so a genuine
    /// brow-lower is only ever attenuated, never erased.
    var clampMaxFraction: Double
    /// Sign of `VNFaceObservation.pitch` when the head tilts DOWN. See the note
    /// at the correction site in `compute`; flip to `+1` if K3 on-device tuning
    /// shows the opposite convention on the Persona virtual camera.
    var downSign: Double

    // Conservative, literature-informed defaults. The pitch→AU4 magnitude is
    // ultimately empirical (PRD §7.2, gated on K3/K4); these are the starting
    // point an on-device pass refines via the UserDefaults keys below.
    static let defaultSlope = 1.0            // remove ~1.0 · (rad past deadband) of AU4
    static let defaultDeadband = 0.15        // rad (~8.6°) — ignore minor head bobs
    static let defaultClampMaxFraction = 0.6 // never remove >60% of AU4
    static let defaultDownSign = -1.0        // ASSUMPTION: head-down ⇒ negative pitch

    static let `default` = PitchCorrection(
        slope: defaultSlope,
        deadband: defaultDeadband,
        clampMaxFraction: defaultClampMaxFraction,
        downSign: defaultDownSign
    )
}

/// Computes AU intensities from metrics relative to a neutral baseline.
enum AUComputer {

    /// Full-scale delta (in IOD units) for each AU's driving measurement.
    /// A delta of `range` (past the dead zone) maps to intensity 1.0.
    private struct Range {
        static let browRaiseInner = 0.10
        static let browRaiseOuter = 0.10
        static let browLower = 0.06
        static let browKnit = 0.07
        static let eyeWiden = 0.055
        static let lidTighten = 0.055
        static let noseWrinkle = 0.045
        static let cornerPull = 0.075
        static let cornerDepress = 0.06
        static let lipStretch = 0.09
        static let lipPress = 0.055
    }

    /// Fraction of each range treated as noise dead zone.
    private static let deadZoneFraction = 0.15

    static func compute(
        metrics m: FacialMetrics,
        baseline b: FacialMetrics,
        pitch: Double? = nil,
        pitchCorrection: PitchCorrection = .default
    ) -> AUVector {
        func delta(_ metric: FacialMetric) -> Double { m[metric] - b[metric] }

        /// Map a signed delta into 0…1 given a full-scale range (with dead zone).
        func intensity(_ d: Double, range: Double) -> Double {
            let dz = range * deadZoneFraction
            guard d > dz else { return 0 }
            return min(1, (d - dz) / (range - dz))
        }

        let browInnerDelta = (delta(.browInnerLeft) + delta(.browInnerRight)) / 2
        let browOuterDelta = (delta(.browOuterLeft) + delta(.browOuterRight)) / 2
        let eyeOpenDelta = (delta(.eyeOpenLeft) + delta(.eyeOpenRight)) / 2
        let cornerLiftL = delta(.cornerLiftLeft)
        let cornerLiftR = delta(.cornerLiftRight)
        let cornerLiftAvg = (cornerLiftL + cornerLiftR) / 2

        var au = AUVector()

        au[.au1] = intensity(browInnerDelta, range: Range.browRaiseInner)
        au[.au2] = intensity(browOuterDelta, range: Range.browRaiseOuter)

        // AU4 = brows pulled DOWN and TOGETHER.
        let lower = intensity(-browInnerDelta, range: Range.browLower)
        let knit = intensity(-delta(.browGapX), range: Range.browKnit)
        var au4 = min(1, 0.6 * lower + 0.5 * knit)

        // US-A0 head-pitch correction ("AU4 imposter", Witkower & Tracy
        // 2019/2020). Looking down foreshortens the brow and inflates AU4 into a
        // false "anger". When a pitch is supplied and the head tilts down past
        // the deadband, remove a linear, clamped, SUBTRACT-ONLY fraction of AU4.
        //
        // SIGN: Apple does not document `VNFaceObservation.pitch`'s sign for the
        // Persona virtual camera. ASSUMPTION (downSign = -1): head-down yields a
        // NEGATIVE pitch, so the downward magnitude is max(0, -pitch). Trivially
        // flippable via `PitchCorrection.defaultDownSign`; K3 on-device tuning
        // validates it. `pitch == nil` skips the correction entirely, so the
        // default call is byte-identical to the pre-US-A0 behavior.
        //
        // NB the attenuation scales the whole AU4 (spec: "cap the max fraction
        // of AU4 it can remove"); the clamp keeps a genuine brow-lower alive
        // even under a strong head-down.
        au4 *= (1 - au4PitchRemovalFraction(pitch: pitch, config: pitchCorrection))
        au[.au4] = au4

        au[.au5] = intensity(eyeOpenDelta, range: Range.eyeWiden)

        // Lid narrowing splits into AU6 (with smile) vs AU7 (without).
        let narrowing = intensity(-eyeOpenDelta, range: Range.lidTighten)
        let smileNow = intensity(cornerLiftAvg, range: Range.cornerPull)
        let smileGate = min(1, smileNow / 0.35)
        au[.au6] = narrowing * smileGate
        au[.au7] = narrowing * (1 - smileGate)

        au[.au9] = intensity(-delta(.philtrum), range: Range.noseWrinkle)

        // AU12 — corner lift plus a small widening term (smiles widen the mouth).
        let widen = intensity(delta(.mouthWidth), range: Range.lipStretch)
        au[.au12] = min(1, smileNow + 0.25 * widen * smileGate)

        au[.au15] = intensity(-cornerLiftAvg, range: Range.cornerDepress)

        // AU20 — horizontal stretch WITHOUT corner raise (fear grimace).
        au[.au20] = widen * (1 - smileGate)

        // AU23/24 — lips pressed: outer lip column compresses, aperture closed.
        let pressed = intensity(-delta(.outerLipHeight), range: Range.lipPress)
        let apertureClosed = m[.innerLipGap] < b[.innerLipGap] + 0.015 ? 1.0 : 0.25
        au[.au23] = pressed * apertureClosed

        // AU25/26 — mouth aperture tiers, jaw drop supported by chin travel.
        let gapDelta = delta(.innerLipGap)
        au[.au25] = smoothstep(gapDelta, from: 0.015, to: 0.08)
        let jawByGap = smoothstep(gapDelta, from: 0.08, to: 0.28)
        let jawByChin = smoothstep(delta(.chinDrop), from: 0.05, to: 0.22)
        au[.au26] = min(1, 0.7 * jawByGap + 0.4 * jawByChin)

        // Unilateral smirk: one corner clearly pulled while the other is not.
        let pullL = intensity(cornerLiftL, range: Range.cornerPull)
        let pullR = intensity(cornerLiftR, range: Range.cornerPull)
        let unilateral = max(pullL - 0.6 * pullR, pullR - 0.6 * pullL, 0)
        let strongEnough = max(pullL, pullR) > 0.25 ? 1.0 : 0.0
        au[.auUnilateral] = unilateral * strongEnough

        return au
    }

    /// The linear, clamped, subtract-only fraction of AU4 to remove for a given
    /// head `pitch`. Returns 0 when `pitch` is nil, non-downward, or within the
    /// deadband, and is bounded to `[0, clampMaxFraction]` so the correction can
    /// only ever *lower* AU4 (never raise it, even with a mistuned slope). Pure —
    /// the single home of the pitch→AU4 formula (also used by `EmotionEngine` to
    /// surface AU4-raw in the debug HUD without a second AU pass).
    static func au4PitchRemovalFraction(pitch: Double?, config: PitchCorrection) -> Double {
        guard let pitch else { return 0 }
        let downPitch = max(0, config.downSign * pitch)
        let excess = max(0, downPitch - config.deadband)
        return max(0, min(config.clampMaxFraction, config.slope * excess))
    }

    private static func smoothstep(_ x: Double, from a: Double, to b: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}

/// The user's calibrated neutral face, with persistence.
struct NeutralBaseline: Sendable {
    var metrics: FacialMetrics
    var isCalibrated: Bool

    static let `default` = NeutralBaseline(metrics: .defaultNeutral, isCalibrated: false)

    private static let storageKey = "EmotionEngine.NeutralBaseline.v1"

    static func loadSaved() -> NeutralBaseline? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([FacialMetric: Double].self, from: data)
        else { return nil }
        return NeutralBaseline(metrics: FacialMetrics(values: values), isCalibrated: true)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(metrics.values) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
#endif
