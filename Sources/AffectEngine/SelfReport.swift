//
//  SelfReport.swift
//  AffectLens
//
//  The ESM (experience-sampling) ground-truth loop (US-E17, PRD v2 §5.7 point 3 /
//  §6.8). A rare 1-tap in-app self-report of how the user ACTUALLY feels, which:
//    1. is written to a local append-only JSONL (`EsmStore`) — ground truth that is
//       NEVER lost, the honest export path, and the per-user calibration data; and
//    2. is ALSO written to Apple Health as an `HKStateOfMind` sample IF (and only if)
//       HealthKit is available + authorized at runtime (`HealthWriter`) — the PRD's
//       own §10 verify-item (HKStateOfMind WRITE on visionOS 26), so it degrades to
//       `.localOnly(reason)` with a visible, logged reason, never blocking the app.
//
//  THE HONEST PAIRING (PRD §5.7 / §9.1 M6): each report SNAPSHOTS the live inferred
//  reading AT REPORT TIME (valence / arousal / confidence / dominant / posterior).
//  That inferred-vs-felt pair is the only honest, per-user accuracy signal — it feeds
//  the CCC overlay AND the non-neutral split-conformal calibration set. Reports are
//  APPEND-ONLY: never backfilled, never edited (PRD hard constraint).
//

#if os(visionOS) || os(macOS)

import Foundation
import HealthKit

// MARK: - QuickMood (the app's 1-tap label vocabulary)

/// The compact self-report label set surfaced in the sheet — a small, honest subset
/// of Apple's own State-of-Mind vocabulary (PRD: "HKStateOfMind = Apple's own affect
/// ontology → per-user ground truth"). Each label maps two ways, both DOCUMENTED and
/// TOTAL over the shipped set:
///   • → `HKStateOfMind.Label` for the Health write (`HealthWriter.hkLabel`), and
///   • → the app's `Emotion` class for the conformal calibration (`emotion`).
/// Kept free of clinical framing (no "stressed"/"depressed"); "anxious" is retained
/// as Apple's own neutral vocabulary and maps to the fear family.
nonisolated enum QuickMood: String, CaseIterable, Codable, Sendable, Identifiable {
    case calm
    case content
    case happy
    case surprised
    case sad
    case anxious
    case frustrated
    case angry

    var id: String { rawValue }

    /// The chip label. Single honest words (swept through the banlist by the self-test).
    var displayName: String {
        switch self {
        case .calm: return "Calm"
        case .content: return "Content"
        case .happy: return "Happy"
        case .surprised: return "Surprised"
        case .sad: return "Sad"
        case .anxious: return "Anxious"
        case .frustrated: return "Frustrated"
        case .angry: return "Angry"
        }
    }

    /// Map to the app's discrete `Emotion` for split-conformal calibration (the true
    /// class of a report). TOTAL over the shipped set today; `nil` is the sanctioned
    /// "explicitly unmapped ⇒ excluded from calibration" escape hatch for any future
    /// label with no honest single-class analogue (PRD §5.4 label-mapping law).
    ///  • calm            → neutral   (low-arousal, near-neutral valence)
    ///  • content, happy  → happiness  (positive valence)
    ///  • surprised       → surprise
    ///  • sad             → sadness
    ///  • anxious         → fear       (anxiety sits in the fear family)
    ///  • frustrated, angry → anger    (frustration is negative-APPROACH, the anger family; §4.3)
    var emotion: Emotion? {
        switch self {
        case .calm: return .neutral
        case .content, .happy: return .happiness
        case .surprised: return .surprise
        case .sad: return .sadness
        case .anxious: return .fear
        case .frustrated, .angry: return .anger
        }
    }
}

// MARK: - SelfReport (one append-only ground-truth record)

/// One ESM self-report. `Codable` (the JSONL record + the CCC/conformal input),
/// `Sendable`, `Identifiable`. The `inferred*` fields are the SNAPSHOT of the live
/// reading at the instant the user tapped Save — the honest inferred-vs-felt pairing
/// (PRD §5.7). All are optional because there may be NO face at report time (then the
/// report still records the felt valence + labels — never imputed inference).
nonisolated struct SelfReport: Codable, Sendable, Identifiable, Equatable {
    /// Stable identity.
    let id: UUID
    /// When the user reported (report time — also the inferred-snapshot instant).
    let t: Date
    /// User-reported valence on the HK State-of-Mind scale, −1 (unpleasant) … +1 (pleasant).
    let valence: Double
    /// The selected quick-mood label ids (`QuickMood.rawValue`). May be EMPTY — the
    /// 1-tap path is the slider alone; labels are optional.
    let labels: [String]
    /// Inferred valence snapshot at report time (nil ⇒ no face then).
    let inferredValence: Double?
    /// Inferred arousal snapshot at report time (nil ⇒ no face then).
    let inferredArousal: Double?
    /// Inferred dominant-class confidence snapshot at report time (nil ⇒ no face then).
    let inferredConfidence: Double?
    /// Inferred dominant emotion snapshot (`Emotion.rawValue`, nil ⇒ no face then).
    let dominantEmotion: String?
    /// The 8-class posterior snapshot at report time — the split-conformal calibration
    /// input (nil ⇒ no face then). A trailing, defaulted optional (synthesized Codable
    /// `decodeIfPresent`), so any future schema addition and the field's absence both
    /// round-trip cleanly.
    let inferredPosterior: EmotionDistribution?
    /// Whether this sample was ALSO written to Apple Health (vs. kept local-only). The
    /// honest per-record flag; set once at authoring and never rewritten (append-only).
    let healthSaved: Bool

    init(id: UUID = UUID(),
         t: Date,
         valence: Double,
         labels: [String],
         inferredValence: Double?,
         inferredArousal: Double?,
         inferredConfidence: Double?,
         dominantEmotion: String?,
         inferredPosterior: EmotionDistribution?,
         healthSaved: Bool) {
        self.id = id
        self.t = t
        self.valence = valence
        self.labels = labels
        self.inferredValence = inferredValence
        self.inferredArousal = inferredArousal
        self.inferredConfidence = inferredConfidence
        self.dominantEmotion = dominantEmotion
        self.inferredPosterior = inferredPosterior
        self.healthSaved = healthSaved
    }

    /// The report's primary (first-selected) MAPPABLE label as an `Emotion` — the true
    /// class for conformal calibration. `nil` when no selected label maps (or none was
    /// selected). Deterministic: the first label in selection order that maps wins.
    var primaryEmotion: Emotion? {
        for raw in labels {
            if let mood = QuickMood(rawValue: raw), let emotion = mood.emotion {
                return emotion
            }
        }
        return nil
    }
}

// MARK: - HealthSaveResult

/// The typed outcome of an attempted Health write. `.localOnly` carries an honest,
/// banlist-clean reason that surfaces in the ground-truth section AND is logged — it
/// is the empirical answer to the PRD §10 verify-item (does HKStateOfMind WRITE work
/// on visionOS 26?).
nonisolated enum HealthSaveResult: Sendable, Equatable {
    case savedToHealth
    case localOnly(reason: String)

    var didSaveToHealth: Bool {
        if case .savedToHealth = self { return true }
        return false
    }

    /// The reason a write stayed local-only (nil when it reached Health).
    var reason: String? {
        if case .localOnly(let reason) = self { return reason }
        return nil
    }
}

// MARK: - HealthWriter (the runtime-checked HKStateOfMind path)

/// Writes an `HKStateOfMind` sample IF HealthKit is available AND the user authorizes
/// sharing — else returns `.localOnly(reason)`. Defensive at every step; it NEVER
/// throws to the caller and NEVER blocks the app (PRD hard constraint). Every outcome
/// is `print`-logged with a `[US-E17]` tag so a device run's console answers the
/// WRITE-availability verify-item empirically.
@MainActor
final class HealthWriter {
    /// Lazily created — only when Health data is actually available on the device, so a
    /// device that has no HealthKit store never allocates one.
    private var store: HKHealthStore?

    init() {}

    /// Attempt to save one momentary-emotion sample. Order (PRD §5.7):
    ///   1. `isHealthDataAvailable()` — THE runtime gate (the verify-item);
    ///   2. share authorization for the state-of-mind type (purpose-first, first use);
    ///   3. build the sample (valence passthrough, mapped labels, `.momentaryEmotion`);
    ///   4. `save` — a throw becomes `.localOnly`.
    /// The CALLER always writes the local JSONL regardless of this result, so ground
    /// truth is never lost.
    func save(valence: Double, labels: [QuickMood], date: Date) async -> HealthSaveResult {
        guard HKHealthStore.isHealthDataAvailable() else {
            return log(.localOnly(reason: HonestyPhrases.healthUnavailableReason))
        }
        let healthStore = store ?? HKHealthStore()
        store = healthStore

        let authorized = await Permissions.requestHealthIfNeeded(store: healthStore)
        guard authorized else {
            return log(.localOnly(reason: HonestyPhrases.healthDeniedReason))
        }

        let sample = HKStateOfMind(
            date: date,
            kind: .momentaryEmotion,
            valence: max(-1, min(1, valence)),
            labels: labels.map(Self.hkLabel(for:)),
            associations: []
        )
        do {
            try await healthStore.save(sample)
            return log(.savedToHealth)
        } catch {
            // The raw error is logged (below) for debugging, but NOT surfaced in UI
            // copy — the user-facing reason stays a fixed banlist-clean phrase.
            print("[US-E17] HealthWriter: save threw — \(error.localizedDescription)")
            return log(.localOnly(reason: HonestyPhrases.healthSaveFailedReason))
        }
    }

    /// Map a `QuickMood` to its `HKStateOfMind.Label`. TOTAL by exhaustive switch (the
    /// compiler enforces completeness); every case is a label VERIFIED to exist in the
    /// visionOS 26 SDK (`HKStateOfMind.h`).
    static func hkLabel(for mood: QuickMood) -> HKStateOfMind.Label {
        switch mood {
        case .calm: return .calm
        case .content: return .content
        case .happy: return .happy
        case .surprised: return .surprised
        case .sad: return .sad
        case .anxious: return .anxious
        case .frustrated: return .frustrated
        case .angry: return .angry
        }
    }

    /// Log + return, so every code path leaves a `[US-E17]` breadcrumb.
    @discardableResult
    private func log(_ result: HealthSaveResult) -> HealthSaveResult {
        switch result {
        case .savedToHealth:
            print("[US-E17] HealthWriter: saved an HKStateOfMind sample to Health.")
        case .localOnly(let reason):
            print("[US-E17] HealthWriter: local-only — \(reason)")
        }
        return result
    }
}

// MARK: - EsmPromptPolicy (the never-interruptive cooldown gate)

/// The pure decision of WHEN an optional self-report banner may surface after a BOCPD
/// state-shift (PRD §10 OQ14: fire on a state-shift WITH cooldown, never interruptive).
/// Two documented gates, both must pass:
///   • at least `postShiftDelay` (60 s) has elapsed SINCE the shift (let the new state
///     settle — never prompt mid-turbulence); and
///   • at least `promptCooldown` (5 min) has elapsed since the LAST prompt (so a second
///     shift inside the window is suppressed).
nonisolated enum EsmPromptPolicy {
    /// ≥ 60 s after the shift before a prompt is eligible.
    static let postShiftDelay: TimeInterval = 60
    /// ≥ 5 min since the last prompt.
    static let promptCooldown: TimeInterval = 300

    static func isEligible(shiftAt: Date?, lastPromptAt: Date?, now: Date) -> Bool {
        guard let shiftAt else { return false }
        guard now.timeIntervalSince(shiftAt) >= postShiftDelay else { return false }
        if let lastPromptAt, now.timeIntervalSince(lastPromptAt) < promptCooldown { return false }
        return true
    }
}

// MARK: - EsmStore (append-only local JSONL + prompt state)

/// The append-only local self-report store (PRD §5.7). `@MainActor @Observable` so
/// SwiftUI observes `reports` (the ground-truth section) live. Reuses the golden-trace
/// JSONL file idioms (`GoldenTraceCoding`, `FileHandle` append, `Documents/…`).
///
/// Ground truth is written LOCAL-FIRST and unconditionally (`append`), so a Health
/// failure can never lose it. Also holds the never-interruptive prompt state (the
/// latched pending shift + the last-prompt time) that `EsmPromptPolicy` decides on.
@MainActor
@Observable
final class EsmStore {
    /// All self-reports, oldest-first (load-on-init, append-on-report). Never mutated
    /// in place — append-only.
    private(set) var reports: [SelfReport] = []

    /// The latched pending state-shift time (nil once consumed by a prompt). Latched so
    /// rapid successive shifts don't keep pushing the 60 s countdown forward.
    private(set) var lastShiftAt: Date?
    /// When a prompt was last surfaced OR a report last submitted — starts the 5 min
    /// cooldown.
    private(set) var lastPromptAt: Date?

    /// The JSONL file, or nil for a MEMORY-ONLY store (the self-tests, so they never
    /// touch the app's real ESM file).
    @ObservationIgnored private let fileURL: URL?

    /// - Parameter persistenceDirectory: where `reports.jsonl` lives; `nil` ⇒ memory-only.
    init(persistenceDirectory: URL? = EsmStore.defaultDirectory) {
        fileURL = persistenceDirectory?.appendingPathComponent("reports.jsonl")
        load()
    }

    /// `Documents/ESM` — mirrors the golden-trace `Documents/GoldenTraces` idiom.
    /// `nonisolated` so it can seed the `init` default argument (a nonisolated context)
    /// — it touches only `FileManager`, no actor state.
    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ESM", isDirectory: true)
    }

    // MARK: Reports

    /// Append a report: in-memory FIRST, then persist the JSONL line. Append-only —
    /// existing records are never rewritten (so `healthSaved` must be correct at call).
    func append(_ report: SelfReport) {
        reports.append(report)
        persist(report)
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        reports = Self.parseReports(data)
    }

    private func persist(_ report: SelfReport) {
        guard let fileURL else { return }   // memory-only
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let line = try Self.encodeLine(report)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            print("[US-E17] EsmStore: could not persist report — \(error.localizedDescription)")
        }
    }

    // MARK: Prompt state (never-interruptive; PRD OQ14)

    /// Record a BOCPD state-shift. Latches only the FIRST shift of a quiet period (a
    /// no-op while one is already pending), so a burst of shifts doesn't keep resetting
    /// the 60 s countdown.
    func noteStateShift(at t: Date) {
        if lastShiftAt == nil { lastShiftAt = t }
    }

    /// Whether an optional prompt banner may surface now (delegates to the pure policy).
    func shouldSurfacePrompt(now: Date) -> Bool {
        EsmPromptPolicy.isEligible(shiftAt: lastShiftAt, lastPromptAt: lastPromptAt, now: now)
    }

    /// The banner just surfaced: start the cooldown and CONSUME the pending shift so it
    /// can't re-trigger from the same shift.
    func notePromptSurfaced(at t: Date) {
        lastPromptAt = t
        lastShiftAt = nil
    }

    /// A report was just submitted (manually or via the banner): also start the cooldown
    /// and consume any pending shift (don't nag right after a report).
    func noteReportSubmitted(at t: Date) {
        lastPromptAt = t
        lastShiftAt = nil
    }

    // MARK: JSONL (de)serialization — reused by the store AND the self-test

    /// Encode one report to a single JSONL line (compact JSON + newline), reusing the
    /// golden-trace encoder so the framing is identical.
    static func encodeLine(_ report: SelfReport) throws -> Data {
        try GoldenTraceCoding.line(report, using: GoldenTraceCoding.encoder())
    }

    /// Parse a JSONL document into reports, SKIPPING any malformed line (an append-only
    /// log tolerates a torn final write). Empty lines are ignored.
    static func parseReports(_ data: Data) -> [SelfReport] {
        let decoder = GoldenTraceCoding.decoder()
        return data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(SelfReport.self, from: Data($0)) }
    }
}

#endif
