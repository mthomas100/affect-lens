//
//  TraceRecorder.swift
//  AffectLens
//
//  The golden-trace flight recorder (US-E15, PRD v2 §5.7 / §6.8). A `@MainActor
//  @Observable` object the hub owns; INERT until `start()`. While recording it
//  registers as a hub analysis consumer and appends one `TraceTick` per fan-out
//  frame to `Documents/GoldenTraces/trace-<stamp>.jsonl` via a `FileHandle`.
//
//  FEATURES & EVENTS ONLY — NEVER PIXELS. The recorder can only write what the
//  `TraceTick` schema holds, and that schema has no image/buffer field (see
//  `GoldenTrace.swift`). Privacy- and App-Review-safe by construction.
//
//  FAN-OUT ORDERING (why the recorder registers LAST). The hub's analysis fan-out
//  fires AFTER `EmotionEngine.apply` (post-apply — `EmotionEngine.onAnalysis` docs),
//  so `hub.face.reading` / `.auVector` are already the frame's values. Registering
//  the recorder's consumer at `start()` (after the eyes + state-shift consumers were
//  registered in `AffectHub.init`) puts it LAST in registration order, so by the
//  time it runs THIS frame: (1) the eyes consumer has updated `hub.eyes.latest` — so
//  `eyesReading` is the just-updated value; (2) the state-shift consumer has already
//  appended any `.stateShift` for this frame — so the events delta captures it.
//  (Caveat: toggling the eyes lens ON *mid-recording* re-appends the eyes consumer
//  AFTER the recorder, so for the first frame after that toggle `eyesReading` lags by
//  one frame. Benign and documented; normal flow enables lenses before recording.)
//
//  COST: per frame = encode one small struct + append to a file handle — microseconds
//  at ~15 Hz, safe on the main actor (no buffering needed; the OS buffers the write).
//

#if os(visionOS) || os(macOS)

import Foundation

@MainActor
@Observable
final class TraceRecorder {

    /// Stable id for the hub's analysis-consumer registry (registered only while recording).
    static let consumerID = "hub.traceRecorder"

    // MARK: Published state (drives the recording indicator UI)

    private(set) var isRecording = false
    /// Frames written so far this recording.
    private(set) var tickCount = 0
    /// When the current recording began (nil while idle).
    private(set) var startedAt: Date?
    /// The file being written (nil while idle).
    private(set) var currentURL: URL?
    /// Last I/O error surfaced to the UI, if any.
    private(set) var lastErrorMessage: String?

    // MARK: Wiring / internals (observation-ignored)

    @ObservationIgnored private weak var hub: AffectHub?
    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private let encoder = GoldenTraceCoding.encoder()
    /// Read cursor into `hub.events` so each tick captures only that frame's new events.
    @ObservationIgnored private var eventsCursor = 0

    init() {}

    /// Wire the hub back-reference (called once by `AffectHub.init`). Weak — the hub
    /// owns the recorder (`let traceRecorder`), so this avoids a retain cycle.
    func connect(hub: AffectHub) {
        self.hub = hub
    }

    // MARK: Storage location

    /// `Documents/GoldenTraces` — where traces are written and enumerated.
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("GoldenTraces", isDirectory: true)
    }

    // MARK: Start / stop

    /// Begin recording: create the folder, open the file, write the header line, and
    /// register the fan-out consumer LAST. Returns false (and sets `lastErrorMessage`)
    /// if the file can't be opened or the hub is gone.
    @discardableResult
    func start(notes: String = "") -> Bool {
        guard !isRecording, let hub else { return false }

        let dir = Self.directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            lastErrorMessage = "Could not create trace folder: \(error.localizedDescription)"
            return false
        }

        let started = Date()
        let url = dir.appendingPathComponent("trace-\(Self.stamp(started)).jsonl")
        let header = TraceHeader(
            schemaVersion: TraceHeader.currentSchemaVersion,
            startedAt: started,
            appVersion: Self.appVersion,
            baselineFingerprint: hub.baselines.personaFingerprint,
            notes: notes
        )
        do {
            let headerLine = try GoldenTraceCoding.line(header, using: encoder)
            FileManager.default.createFile(atPath: url.path, contents: headerLine)
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            handle = h
        } catch {
            lastErrorMessage = "Could not open trace file: \(error.localizedDescription)"
            return false
        }

        currentURL = url
        startedAt = started
        tickCount = 0
        eventsCursor = hub.events.count
        lastErrorMessage = nil
        isRecording = true

        // Register LAST (see the fan-out-ordering note in the file header).
        hub.addAnalysisConsumer(Self.consumerID) { [weak self] analysis in
            self?.capture(analysis)
        }
        return true
    }

    /// Stop recording: unregister the consumer and close the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        hub?.removeAnalysisConsumer(Self.consumerID)
        try? handle?.close()
        handle = nil
        isRecording = false
    }

    // MARK: Capture (one TraceTick per fan-out frame)

    private func capture(_ analysis: FrameAnalysis) {
        guard isRecording, let hub, let handle else { return }

        // Events emitted at this frame = the delta since the previous recorded tick.
        // The recorder runs LAST in the fan-out, so a `.stateShift` emitted this frame
        // by the earlier state-shift consumer is already appended. Events are sparse
        // (a shift can fire at most once per cooldown), so the bus cap never trims
        // mid-tick; the clamp below is purely defensive.
        let count = hub.events.count
        let newEvents: [AffectEvent] = eventsCursor <= count
            ? Array(hub.events[eventsCursor..<count])
            : []
        eventsCursor = count

        let tick = TraceTick(
            t: analysis.date,
            facePresent: analysis.facePresent,
            eyeOpenLeft: analysis.eyeOpenLeft,
            eyeOpenRight: analysis.eyeOpenRight,
            yaw: analysis.yaw,
            roll: analysis.roll,
            pitch: analysis.pitch,
            auVector: Self.stringKeyed(hub.face.auVector),
            faceReading: hub.face.reading,
            // The just-updated eyes reading when the lens is on (its consumer ran
            // earlier in this same fan-out); nil when the lens is off.
            eyesReading: hub.eyes.isEnabled ? hub.eyes.latest : nil,
            eventsEmitted: newEvents,
            // The pre-fusion geometry + the FER+ appearance distributions this frame
            // (US-lab, §6.8 A/B replay). Read-only engine debug accessors; nil on a
            // no-face frame or when FER+ has produced nothing — additive, never pixels.
            geometryDistribution: hub.face.debugGeometryDistribution,
            mlDistribution: hub.face.debugMLDistribution,
            // The non-fan-out channels' as-of-this-frame published readings:
            // each publishes on its own cadence (gesture events / analyzer polls), so this
            // is its freshest value, nil while the lens is off. Features & meters only —
            // never pixels. These are what let replay exercise F7 + the hands/head/voice
            // proxies and votes on a recorded trace.
            interactionReading: hub.interaction.isEnabled ? hub.interaction.latest : nil,
            voiceReading: hub.voice.isEnabled ? hub.voice.latest : nil,
            handsReading: hub.hands.isEnabled ? hub.hands.latest : nil,
            headReading: hub.head.isEnabled ? hub.head.latest : nil
        )
        do {
            let line = try GoldenTraceCoding.line(tick, using: encoder)
            try handle.write(contentsOf: line)
            tickCount += 1
        } catch {
            lastErrorMessage = "Trace write failed: \(error.localizedDescription)"
            stop()
        }
    }

    // MARK: Minimal management

    /// The recorded trace files, newest first (filename stamps sort chronologically).
    func listTraces() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: Self.directory,
                                                      includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
    }

    /// Delete one recorded trace.
    func deleteTrace(url: URL) {
        try? FileManager.default.removeItem(at: url)
        if url == currentURL { currentURL = nil }
    }

    // MARK: Helpers

    /// `AUVector` → a portable `[String: Double]` keyed by `ActionUnit.rawValue`.
    private static func stringKeyed(_ au: AUVector) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: au.map { ($0.key.rawValue, $0.value) })
    }

    private static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// A filesystem-safe UTC stamp (`yyyyMMdd'T'HHmmss'Z'`) for the trace filename.
    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}

#endif
