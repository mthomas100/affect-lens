//
//  BaselineStore.swift
//  AffectLens
//
//  The generalized per-channel baseline layer (US-A4, PRD v2 §5.4). Generalizes
//  the face's `NeutralBaseline` (`ActionUnits.swift`) into a `Codable` store
//  keyed by `Channel`, each entry holding per-feature ROBUST statistics
//  (median + MAD) instead of a bare neutral value. This is the persistence /
//  statistics substrate that LATER items (eyes / hands / head / voice /
//  interaction lenses) consume for their own per-Persona baselining — the face
//  pipeline is untouched (PRD §5.4 keeps the engine's naive subtract-the-neutral
//  path; zero face regression is the law of Phase A).
//
//  Honesty framing (PRD law): the `.face` entry baselines the rendered **Persona**
//  avatar's neutral geometry — never "your face."
//
//  Why robust stats (median + MAD), not mean + variance: the calibration ritual
//  already takes a MEDIAN of 36 samples (`FacialMetrics.median`); MAD is the
//  matching robust scale. The robust-z `(x − median) / (1.4826·mad)` puts every
//  feature on a comparable, outlier-resistant scale, and the MAD SPREAD doubles
//  as the low-expresser detector for free (PRD §5.4: Kargarandehkordi 2023 —
//  personalization under-performs for low-expressers → when the calibration
//  spread is small, later items WIDEN confidences).
//

#if os(visionOS) || os(macOS)

import Foundation

/// Robust location + scale statistics for a single baselined feature.
///
/// `median` is the robust center (the calibration median); `mad` is the median
/// absolute deviation, a robust analogue of the standard deviation.
nonisolated struct RobustStat: Codable, Sendable, Equatable {
    /// Robust center — the per-Persona calibration median for this feature.
    var median: Double
    /// Median absolute deviation — robust scale (spread) of the calibration.
    var mad: Double

    /// MAD→σ consistency constant: for Gaussian data `1.4826·MAD` is a consistent
    /// estimator of the standard deviation, so `robustZ` is on the same scale as a
    /// textbook z-score.
    static let madToSigma = 1.4826
    /// Guards a division by a ~zero scale (a frozen or unknown-spread feature).
    static let epsilon = 1e-9
    /// The "unknown spread" marker used when a baseline carries a median but no
    /// measured spread (e.g. a value migrated from the v1 `NeutralBaseline`, which
    /// stored medians only). A `mad` of 0 makes `robustZ` collapse to a hard
    /// threshold at the median (any deviation reads as a large z) and drives the
    /// entry's `expressiveSeparability` toward 0 — i.e. maximum caution — until a
    /// fresh calibration supplies a real spread.
    static let unknownMAD = 0.0

    /// Robust z-score `(x − median) / (1.4826·mad)`, with an epsilon guard so a
    /// zero / near-zero MAD can never divide by zero. At `mad == 0` this returns 0
    /// exactly for `x == median` and a large (finite) magnitude otherwise.
    func robustZ(_ x: Double) -> Double {
        let sigma = Self.madToSigma * mad
        return (x - median) / max(sigma, Self.epsilon)
    }

    /// Robust median + MAD of a sample set — mirrors the face's median-of-36
    /// calibration ritual (`FacialMetrics.median`) and extends it with the spread.
    /// Returns `nil` for an empty sample set.
    static func from(samples: [Double]) -> RobustStat? {
        guard !samples.isEmpty else { return nil }
        let med = Self.median(of: samples)
        let deviations = samples.map { abs($0 - med) }
        return RobustStat(median: med, mad: Self.median(of: deviations))
    }

    /// Slow re-track toward an observation — generalizes the engine's
    /// verified-neutral lerp (`baseline.metrics.lerp(toward:alpha:)`, alpha 0.02).
    /// The median lerps toward `observed`; the MAD lerps toward the PRE-update
    /// absolute deviation `|observed − median|` at the SAME alpha, so the spread
    /// estimate self-heals against session drift alongside the center (PRD §5.4:
    /// "baselines self-heal … fatigue drifts blink in minutes").
    mutating func retrack(observed: Double, alpha: Double) {
        let deviation = abs(observed - median)
        median = median * (1 - alpha) + observed * alpha
        mad = mad * (1 - alpha) + deviation * alpha
    }

    private static func median(of xs: [Double]) -> Double {
        let sorted = xs.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}

/// One channel's baseline: robust stats for each of its named features.
///
/// **Keyed by `String`, deliberately.** The face baselines its 14 `FacialMetric`
/// cases (raw IOD geometry); future channels baseline their own `FeatureKey`
/// cases (blinkRate, headPitch, …). Those two enums are DISJOINT — a
/// `[FeatureKey: RobustStat]` model literally cannot hold `FacialMetric.eyeOpenLeft`,
/// and vice-versa. Both are `String`-raw enums, so a `[String: RobustStat]` keyed
/// on `rawValue` is the one model that cleanly serves BOTH sets (and any future
/// named metric). Typed subscripts below keep call sites free of `.rawValue`.
nonisolated struct ChannelBaseline: Codable, Sendable, Equatable {
    /// Robust stats keyed by feature/metric name (`FacialMetric` / `FeatureKey`
    /// raw value).
    var stats: [String: RobustStat]

    static let empty = ChannelBaseline(stats: [:])

    /// Reference MAD scale for `expressiveSeparability`. Calibrated for the face's
    /// IOD-normalized metrics (typical calibration MADs ≈ 0.005–0.03 IOD); a
    /// feature spread of this magnitude sits near the middle of the score. Later
    /// channel items with differently-scaled features may supply a per-feature
    /// normalization — noted as a known limitation below.
    static let separabilityReferenceMAD = 0.02

    /// A per-entry "expressive separability" score in [0, 1], monotone increasing
    /// in the aggregate calibration spread (PRD §5.4). LOW spread ⇒ low score ⇒
    /// low-expresser ⇒ later items widen confidences; WIDE spread ⇒ high score.
    ///
    /// Formula: `1 − exp(−meanMAD / referenceMAD)`, where `meanMAD` is the mean of
    /// the entry's feature MADs. Simple, saturating, strictly monotone in every
    /// MAD, and bounded to [0, 1). An empty entry (and a v1-migrated entry, whose
    /// MADs are all the `unknownMAD` marker) scores 0.
    ///
    /// Known limitation: `meanMAD` aggregates raw MADs, so it is only meaningful
    /// when an entry's features share a unit — true for the face (all IOD), not
    /// guaranteed across a future channel's heterogeneous features; that per-feature
    /// normalization is a later refinement.
    var expressiveSeparability: Double {
        guard !stats.isEmpty else { return 0 }
        let meanMAD = stats.values.reduce(0) { $0 + $1.mad } / Double(stats.count)
        return 1 - exp(-meanMAD / Self.separabilityReferenceMAD)
    }

    /// Primitive string-keyed access.
    subscript(_ key: String) -> RobustStat? {
        get { stats[key] }
        set { stats[key] = newValue }
    }

    /// Convenience access for the face's raw geometry features.
    subscript(_ metric: FacialMetric) -> RobustStat? {
        get { stats[metric.rawValue] }
        set { stats[metric.rawValue] = newValue }
    }

    /// Convenience access for a channel's derived features.
    subscript(_ feature: FeatureKey) -> RobustStat? {
        get { stats[feature.rawValue] }
        set { stats[feature.rawValue] = newValue }
    }
}

/// The generalized per-channel baseline store (PRD v2 §5.4) — `Codable` so it
/// persists whole and replays in the golden-trace harness. A pure value type
/// (`nonisolated`) so the statistics are testable as deterministic math; its
/// owner on `AffectHub` is `@MainActor`.
nonisolated struct BaselineStore: Codable, Sendable, Equatable {
    /// Schema version. Starts at 2 — v1 was the face-only `NeutralBaseline`
    /// (`ActionUnits.swift`), a different type this store MIGRATES from (below).
    var schemaVersion: Int
    /// A stable fingerprint of the Persona's neutral face, used to INVALIDATE the
    /// store when the Persona materially changes.
    ///
    /// There is no Apple API to identify a Persona, so this is pragmatic: a
    /// deterministic hash of the `.face` entry's calibration medians (rounded to
    /// 3 dp), stamped at calibration time. A materially different neutral face on
    /// recalibration ⇒ a different fingerprint (invalidate); tiny re-track drift
    /// (< 0.001 IOD) leaves it unchanged. Recalibration REFRESHES it via
    /// `refreshFingerprint()`; migration seeds it from the v1 medians.
    var personaFingerprint: String?
    /// Per-channel baselines. Absent channel ⇒ not yet calibrated.
    var channels: [Channel: ChannelBaseline]

    // MARK: - Persistence keys

    /// The v2 store's `UserDefaults` key (encoded JSON `Data`).
    static let storageKey = "AffectHub.BaselineStore.v2"
    /// The v1 face key this store migrates FROM. Mirrors the (private)
    /// `NeutralBaseline.storageKey` in `ActionUnits.swift`; kept in sync by the
    /// `baselineStore()` migration self-test, which writes the v1 blob through the
    /// exact `JSONEncoder().encode(metrics.values)` path `NeutralBaseline.save()`
    /// uses. NOT deleted on migration — the engine still reads it, so both coexist.
    static let v1FaceKey = "EmotionEngine.NeutralBaseline.v1"

    static let currentSchemaVersion = 2

    static let empty = BaselineStore(
        schemaVersion: currentSchemaVersion,
        personaFingerprint: nil,
        channels: [:]
    )

    // MARK: - Access

    func stat(_ channel: Channel, _ feature: String) -> RobustStat? {
        channels[channel]?[feature]
    }

    /// Robust z of `x` against `channel`'s `feature` baseline; `nil` if unbaselined.
    func robustZ(_ channel: Channel, _ feature: String, _ x: Double) -> Double? {
        channels[channel]?[feature]?.robustZ(x)
    }

    /// This channel's expressive-separability score (PRD §5.4); `nil` if unbaselined.
    func separability(for channel: Channel) -> Double? {
        channels[channel]?.expressiveSeparability
    }

    // MARK: - Mutation

    /// Slow per-channel re-track (PRD §5.4) — delegates to `RobustStat.retrack`,
    /// generalizing the engine's 2 s-verified-neutral lerp (alpha 0.02) to any
    /// channel/feature. No-op if the feature is not yet baselined (re-tracking only
    /// refines an existing baseline, exactly as the engine's lerp does).
    mutating func retrack(channel: Channel, feature: String, observed: Double, alpha: Double = 0.02) {
        guard var entry = channels[channel], var s = entry[feature] else { return }
        s.retrack(observed: observed, alpha: alpha)
        entry[feature] = s
        channels[channel] = entry
    }

    /// Recompute `personaFingerprint` from the current `.face` entry (the
    /// "recalibration refreshes it" path). No-op with no face entry.
    mutating func refreshFingerprint() {
        guard let face = channels[.face] else { return }
        personaFingerprint = Self.fingerprint(faceMedians: face.stats.mapValues { $0.median })
    }

    /// Deterministic (process-independent) fingerprint of the Persona neutral.
    /// FNV-1a over the medians rounded to 3 dp and sorted by key — NOT Swift's
    /// per-process-seeded `Hasher`, so it is stable across launches.
    static func fingerprint(faceMedians: [String: Double]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325           // FNV offset basis
        let prime: UInt64 = 0x100000001b3               // FNV prime
        for key in faceMedians.keys.sorted() {
            let rounded = (faceMedians[key]! * 1000).rounded() / 1000
            for byte in "\(key):\(rounded);".utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
        }
        return String(hash, radix: 16)
    }

    // MARK: - Load / save (injectable defaults for testability)

    /// Load the store, injecting `UserDefaults` so self-tests can use a throwaway
    /// suite and never touch the app's real persisted baseline (defaults to
    /// `.standard` in production).
    ///
    /// Order: (1) decode the v2 store if present; else (2) MIGRATE the v1 face
    /// `NeutralBaseline` into the `.face` entry (median = the stored neutral value,
    /// MAD = `unknownMAD`) WITHOUT deleting the v1 key; else (3) an empty store.
    /// Migration is re-derived on each load until a `save` writes the v2 key — this
    /// keeps the loader free of write side-effects; it is idempotent and cheap.
    static func loaded(from defaults: UserDefaults = .standard) -> BaselineStore {
        if let data = defaults.data(forKey: storageKey),
           let store = try? JSONDecoder().decode(BaselineStore.self, from: data) {
            return store
        }

        var store = BaselineStore.empty
        if let v1 = defaults.data(forKey: v1FaceKey),
           let values = try? JSONDecoder().decode([FacialMetric: Double].self, from: v1) {
            var face = ChannelBaseline.empty
            for (metric, median) in values {
                face[metric] = RobustStat(median: median, mad: RobustStat.unknownMAD)
            }
            store.channels[.face] = face
            store.refreshFingerprint()
        }
        return store
    }

    /// Persist as encoded JSON `Data` under `storageKey`.
    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

#endif
