//
//  GoldenTrace.swift
//  AffectLens
//
//  The golden-trace flight-recorder SCHEMA (US-E15, PRD v2 §5.7) — a roll-your-own
//  recorder, explicitly NOT the private-SPI `ARRecorder`. A trace is a JSONL
//  document: one header line then one JSON object per processed frame, serializing
//  the face pipeline's OUTPUTS (analysis primitives, AU vector, face reading, eyes
//  reading), the non-fan-out channels' as-of-frame readings (interaction / voice /
//  hands / head, when their lenses are on) plus the AffectEvents emitted that frame.
//
//  ┌─────────────────────────────────────────────────────────────────────────────┐
//  │ THE NEVER-PIXELS GUARANTEE IS BY TYPE DESIGN.                                 │
//  │ `TraceTick` has NO image / buffer field — no CVPixelBuffer, CGImage,          │
//  │ CMSampleBuffer, IOSurface, or raw Data. It cannot carry a pixel because the   │
//  │ schema has nowhere to put one. This is what makes golden-trace logging        │
//  │ privacy- and App-Review-safe BY CONSTRUCTION (features & events only).        │
//  │ `EmotionSelfTests.traceSchemaNoPixels()` asserts it with a Mirror sweep.      │
//  └─────────────────────────────────────────────────────────────────────────────┘
//
//  DETERMINISM: the face pipeline (Vision + FER+ + wall-clock throttling) is NOT
//  deterministically replayable and the PRD does not ask for that. The trace
//  records the face pipeline's OUTPUTS as ground truth; deterministic replay
//  (`TraceReplayer`) drives everything DOWNSTREAM of the face pipeline — the blink
//  detector and the change-point detectors today, fusion + narrator later — off the
//  recorded stream, using NO `Date()`/randomness, so replay is byte-stable.
//

#if os(visionOS) || os(macOS)

import Foundation

// MARK: - JSON coding

/// Shared JSON coding for golden traces.
///
/// DEFAULT date strategy ON PURPOSE: dates encode as full-precision
/// `timeIntervalSinceReferenceDate` doubles so the ~15 Hz (≈66 ms) tick spacing
/// round-trips EXACTLY. An `.iso8601` string would drop sub-second precision and
/// collapse distinct ticks onto the same instant, which would corrupt blink timing
/// and break deterministic replay. `.sortedKeys` makes the file bytes stable across
/// runs (nice for diffing goldens); compact output (no `.prettyPrinted`) keeps every
/// encoded value on ONE line, which is what makes the JSONL framing work.
nonisolated enum GoldenTraceCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func decoder() -> JSONDecoder { JSONDecoder() }

    /// Encode one value to a single JSONL line: compact JSON + a trailing newline.
    static func line<T: Encodable>(_ value: T, using encoder: JSONEncoder) throws -> Data {
        var data = try encoder.encode(value)   // compact ⇒ no interior newlines ⇒ one line
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

nonisolated enum TraceError: Error {
    case empty
}

// MARK: - Header

/// The first line of a trace file — provenance and schema versioning.
nonisolated struct TraceHeader: Codable, Sendable {
    /// Bumped on any incompatible `TraceTick` schema change (readers can gate on it).
    var schemaVersion: Int
    /// When recording began (wall clock at `start`).
    var startedAt: Date
    /// App marketing + build version string, for cross-version regression triage.
    var appVersion: String
    /// The per-Persona baseline fingerprint (`BaselineStore.personaFingerprint`) at
    /// record time — a trace is only comparable against the calibration it was made
    /// under. Optional: absent before the first calibration.
    var baselineFingerprint: String?
    /// Free-text notes (e.g. "forced-arousal blink probe").
    var notes: String

    static let currentSchemaVersion = 1
}

// MARK: - Tick

/// One processed frame, features & events ONLY (never pixels — see the file header).
///
/// The primitives (`t` / `facePresent` / `eyeOpen*` / `yaw` / `roll` / `pitch`) are
/// the `FrameAnalysis` fan-out payload; `auVector` is `EmotionEngine.auVector` keyed
/// by `ActionUnit.rawValue` (a portable string map); `faceReading` is the post-apply
/// `EmotionReading`; `eyesReading` is `EyeChannel.latest` (nil when the eyes lens is
/// off); `eventsEmitted` are the `AffectEvent`s appended to the bus at this frame.
nonisolated struct TraceTick: Codable, Sendable {
    /// When this frame was analyzed (`FrameAnalysis.date`).
    var t: Date
    /// Vision detected a face this frame (broader than "usable geometry").
    var facePresent: Bool
    /// IOD-normalized, roll-corrected eye openness (visual left / right); nil when
    /// there is no usable eye geometry.
    var eyeOpenLeft: Double?
    var eyeOpenRight: Double?
    /// Head pose in radians (Vision convention); nil when unavailable.
    var yaw: Double?
    var roll: Double?
    var pitch: Double?
    /// The 14 FACS AUs as computed deltas, keyed by `ActionUnit.rawValue`.
    var auVector: [String: Double]
    /// The face lens's post-apply reading (Codable — the golden-trace prerequisite).
    var faceReading: EmotionReading
    /// The eyes lens's channel-generic reading, or nil when the eyes lens is off.
    var eyesReading: ChannelReading?
    /// The AffectEvents emitted at (i.e. since the previous tick of) this frame.
    var eventsEmitted: [AffectEvent]
    /// The per-frame GEOMETRY distribution (`EmotionClassifier.classify(au)`) BEFORE the
    /// ML fusion and BEFORE smoothing (US-lab, §6.8 A/B replay). Together with
    /// `mlDistribution` it lets `TraceReplayer.replaySeries` RE-FUSE the categorical pool
    /// under a different `mlWeight` strategy (fixed 0.35 vs dynamic Aviezer) on the SAME
    /// recorded evidence — the "A/B fusion toggle on a replay" idiom. Captured from
    /// `EmotionEngine.debugGeometryDistribution` (a read-only accessor; no behavior change).
    /// A trailing, defaulted optional: NOT a pixel (an 8-class posterior), so the
    /// never-pixels guarantee holds; nil on no-face frames AND on every pre-US-lab trace,
    /// so old traces decode it as nil (params-only A/B) and the embedded golden fixture —
    /// which leaves it nil — serializes byte-for-byte as before (the ReplayResult goldens
    /// are untouched).
    var geometryDistribution: EmotionDistribution? = nil
    /// The FER+ appearance distribution as of this frame (the value the live fusion used),
    /// or nil when the expert produced none yet / is disabled (US-lab). Captured from
    /// `EmotionEngine.debugMLDistribution`. Same additive-optional / never-pixels /
    /// old-trace-nil properties as `geometryDistribution`.
    var mlDistribution: EmotionDistribution? = nil
    /// The non-fan-out channels' readings as of this frame:
    /// interaction / voice / hands / head each publish on their OWN cadence (view-fed
    /// gesture events, an ~3 Hz analyzer poll, a ~10 Hz immersive poll), so these are the
    /// "as of this frame" published values, nil while the lens is off. Additive trailing
    /// optionals: a `ChannelReading` is features & meters only (never a pixel), old traces
    /// decode them as nil, and the embedded golden fixture — which leaves them nil —
    /// serializes byte-for-byte as before (nil optionals are omitted keys). With them a
    /// recorded trace can exercise F7 (interaction) and the hands/head/voice F1 proxies +
    /// congruence votes in deterministic replay, which face+eyes-only traces could not.
    var interactionReading: ChannelReading? = nil
    var voiceReading: ChannelReading? = nil
    var handsReading: ChannelReading? = nil
    var headReading: ChannelReading? = nil
}

// MARK: - Trace (JSONL document)

/// A whole trace: a header plus its ticks, with JSONL (de)serialization. A JSONL
/// container, NOT a single JSON value — the recorder appends line-by-line to a
/// `FileHandle`, and this type is the in-memory / whole-file view the replayer reads.
nonisolated struct Trace: Sendable {
    var header: TraceHeader
    var ticks: [TraceTick]

    init(header: TraceHeader, ticks: [TraceTick]) {
        self.header = header
        self.ticks = ticks
    }

    /// Serialize to JSONL bytes: header line then one line per tick.
    func jsonlData() throws -> Data {
        let enc = GoldenTraceCoding.encoder()
        var out = try GoldenTraceCoding.line(header, using: enc)
        for tick in ticks {
            out.append(try GoldenTraceCoding.line(tick, using: enc))
        }
        return out
    }

    func jsonlString() throws -> String {
        String(decoding: try jsonlData(), as: UTF8.self)
    }

    /// Parse a JSONL document: the first non-empty line is the header, each
    /// remaining line is one `TraceTick`. Empty lines (e.g. a trailing newline) are
    /// ignored.
    init(jsonl data: Data) throws {
        let dec = GoldenTraceCoding.decoder()
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        guard let first = lines.first else { throw TraceError.empty }
        header = try dec.decode(TraceHeader.self, from: Data(first))
        ticks = try lines.dropFirst().map { try dec.decode(TraceTick.self, from: Data($0)) }
    }

    init(jsonlString string: String) throws {
        try self.init(jsonl: Data(string.utf8))
    }

    init(contentsOf url: URL) throws {
        try self.init(jsonl: Data(contentsOf: url))
    }
}

// MARK: - Embedded golden fixture (DEBUG)

#if DEBUG
/// The embedded golden fixture the full-pipeline regression self-test replays
/// (`EmotionSelfTests.goldenTraceReplay`). Built PROGRAMMATICALLY from documented
/// constants rather than pasted as a raw JSONL blob — deliberately, so it can never
/// drift out of sync with the schema, and using NO `Date()`/randomness so it is
/// byte-identical every run (the test serializes it to JSONL and decodes that back,
/// exercising the real file path). The scenario, in three segments:
///   • ticks `0 ..< blinkStart`      — stationary: eyes open, valence 0 → no blinks, no shifts.
///   • ticks `blinkStart ..< stepTick` — three well-separated short closures (blinks).
///   • ticks `stepTick ..< tickCount`  — an abrupt valence step 0 → `stepValence`.
/// The pre-step segment is ≥ `ChangePointDetector`'s `minRunToArm` (20) faceDetected
/// samples, so the detector is ARMED before the step and fires exactly once.
nonisolated enum GoldenTraceFixture {
    static let tickCount = 50
    static let blinkStart = 20
    static let stepTick = 32
    static let stepValence = 0.8
    static let expectedBlinks = 3
    /// The two consecutive "closed" frames preceding each of the three blink reopens
    /// (reopens land at 23 / 27 / 31 — spaced past the 0.2 s refractory).
    static let blinkShutTicks: Set<Int> = [21, 22, 25, 26, 29, 30]
    /// Inclusive tick window (relative to `stepTick`) the single valence state-shift
    /// must fall in. Measured BOCPD latency for a 0.8 step is 0–3 samples; the window
    /// is a documented, generous margin (matches the CPD self-test's ≤25 bound).
    static let shiftWindow = 0...16

    static let frameInterval: TimeInterval = 1.0 / 15.0
    static let openOpenness = 0.20
    static let shutOpenness = 0.02
    private static let t0 = Date(timeIntervalSinceReferenceDate: 400_000)

    static func build() -> Trace {
        var ticks: [TraceTick] = []
        ticks.reserveCapacity(tickCount)
        for i in 0..<tickCount {
            let t = t0.addingTimeInterval(Double(i) * frameInterval)
            let shut = blinkShutTicks.contains(i)
            let openness = shut ? shutOpenness : openOpenness
            let valence = i >= stepTick ? stepValence : 0.0
            let reading = EmotionReading(
                date: t,
                distribution: .neutralRest,
                dominant: .neutral,
                confidence: 0.5,
                intensity: 0,
                intensities: [:],
                valence: valence,
                arousal: 0,
                faceDetected: true,
                quality: 0.9
            )
            ticks.append(TraceTick(
                t: t,
                facePresent: true,
                eyeOpenLeft: openness,
                eyeOpenRight: openness,
                yaw: 0, roll: 0, pitch: 0,
                auVector: shut ? [:] : ["au4": 0.05],
                faceReading: reading,
                eyesReading: nil,
                eventsEmitted: []
            ))
        }
        let header = TraceHeader(
            schemaVersion: TraceHeader.currentSchemaVersion,
            startedAt: t0,
            appVersion: "fixture",
            baselineFingerprint: "golden-fixture",
            notes: "US-E15 embedded golden fixture: stationary → 3 blinks → valence step"
        )
        return Trace(header: header, ticks: ticks)
    }
}
#endif

#endif
