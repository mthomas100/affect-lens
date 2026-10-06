//
//  VoiceAnalyzer.swift
//  AffectLens
//
//  The VOICE channel's off-main analyzer + its pure prosody math (US-D12, PRD v2
//  §3.5 / §7.4 / §8.0 K6). Two types live here:
//
//    • `ProsodyMath` — a `nonisolated struct`, the PURE, testable core: RMS
//      intensity, YIN F0 estimation, the energy+periodicity VOICED decision (this
//      IS the VAD), rolling aggregates, and the baseline-relative AROUSAL mapping.
//      No AVFoundation, no state beyond a rolling frame window — unit-tested off the
//      main actor (`EmotionSelfTests.prosodyMath()`).
//
//    • `VoiceAnalyzer` — an `actor` (the `FaceAnalyzer` idiom) owning an
//      `AVAudioEngine` input tap + a best-effort `SoundAnalysis` stream. Per tap
//      buffer it decimates toward a YIN-friendly rate and folds one frame into
//      `ProsodyMath`; it exposes an async `snapshot()`. START IS DEFENSIVE (K6): a
//      session/engine failure throws a typed reason and NEVER crashes; the channel
//      surfaces it as `.unavailable`.
//
//  Honesty law (PRD §3.5, Juslin & Laukka 2003): voice carries AROUSAL ONLY — never
//  valence, never a discrete emotion, never transcription. The VAD is energy /
//  periodicity based, so there is no `SFSpeechRecognizer` and no words are ever
//  recognized.
//

#if os(visionOS) || os(macOS)

import Foundation
import Accelerate
import AVFoundation
import SoundAnalysis

// MARK: - ProsodySnapshot (the Sendable value crossing the actor hop)

/// One async snapshot of the analyzer's rolling prosody state (PRD §7.4). A pure
/// `Sendable` value so it crosses from the `VoiceAnalyzer` actor to the `@MainActor`
/// `VoiceChannel` cleanly. Carries arousal-bearing prosody + engine status + any
/// on-device sound event — NEVER a valence or a discrete-emotion field (there is no
/// such field to carry: the honesty bar is structural).
nonisolated struct ProsodySnapshot: Sendable, Equatable {
    /// When the snapshot was taken.
    var date: Date
    /// Whether the audio engine is currently running (the K6 coexistence flag).
    var engineRunning: Bool
    /// A typed reason the engine is NOT running (session/engine/no-input), else nil.
    var unavailableReason: String?

    /// Median voiced F0 (Hz) over the rolling window; nil with no voiced frames.
    var f0Median: Double?
    /// Variance of voiced F0 (Hz²) over the window — an arousal cue (Juslin & Laukka).
    var f0Variance: Double
    /// The most-recent voiced F0 (Hz), for the raw HUD sparkline; nil if unvoiced.
    var latestVoicedF0: Double?
    /// Median RMS intensity over the window (loudness proxy).
    var intensityMedian: Double
    /// Median RMS intensity over VOICED frames — the speaking-loudness the arousal delta
    /// uses (compares like-for-like with the per-user intensity baseline).
    var voicedIntensityMedian: Double
    /// The instantaneous RMS level of the most recent frame (the raw meter).
    var currentLevel: Double
    /// Fraction of window frames that were voiced (0…1) — a speaking-density proxy.
    var voicedFraction: Double
    /// Voiced ONSETS per second over the window — a coarse vocal-tempo proxy.
    var onsetRate: Double
    /// The current-frame voiced decision — the live VAD flag that gates blinks.
    var isSpeaking: Bool
    /// Frames / voiced frames currently in the window (maturity / density inputs).
    var frameCount: Int
    var voicedCount: Int

    /// A laughter-like sound registered since the last snapshot (SoundAnalysis) —
    /// corroboration only (F6 later), NEVER an emotion verdict.
    var laughter: Bool
    /// A crying/sobbing-like sound registered since the last snapshot (best-effort).
    var cry: Bool

    /// A quiet, engine-off snapshot (the pre-start / stopped state).
    static func off(reason: String?) -> ProsodySnapshot {
        ProsodySnapshot(date: Date(), engineRunning: false, unavailableReason: reason,
                        f0Median: nil, f0Variance: 0, latestVoicedF0: nil,
                        intensityMedian: 0, voicedIntensityMedian: 0, currentLevel: 0,
                        voicedFraction: 0, onsetRate: 0, isSpeaking: false,
                        frameCount: 0, voicedCount: 0, laughter: false, cry: false)
    }
}

// MARK: - ProsodyMath (the pure, testable core)

/// The prosody feature math, a `nonisolated` value type so it is pure and testable off
/// the main actor (the `VoiceAnalyzer` actor wraps it, the way `EmotionEngine` wraps
/// `FaceGeometry`/`AUComputer`). It keeps a rolling window of per-buffer frames and
/// derives arousal-bearing aggregates.
///
/// **Algorithm — YIN (de Cheveigné & Kawahara 2002).** F0 is estimated per analysis
/// window with YIN's cumulative-mean-normalized difference (CMND): the squared
/// difference function `d(τ)=Σ(x[j]−x[j+τ])²` is normalized to `d'(τ)=d(τ)·τ/Σd(1..τ)`,
/// the first `τ` in the voice band whose `d'` dips below `yinThreshold` (a local minimum)
/// is taken as the period, and a parabolic interpolation refines it to sub-sample
/// precision → `f0 = sampleRate/τ`. Chosen over bare autocorrelation because the CMND
/// suppresses the octave (half-period) errors autocorrelation is prone to.
///
/// **Window / hop.** The analysis window is one decimated tap buffer (~4096 native
/// frames ≈ 85 ms at 48 kHz — several pitch periods, the minimum YIN needs); the hop is
/// the tap cadence. Rolling aggregates span `windowDuration` (3 s — prosody is slow, so
/// a few seconds of voiced frames give a stable median without lag).
///
/// **VAD (voiced/unvoiced).** A frame is VOICED iff its RMS clears `energyFloor`
/// (silence gate) AND YIN found a periodic pitch with aperiodicity below `yinThreshold`
/// (periodicity gate). Requiring BOTH is the whole voice-activity decision: energy alone
/// admits noise, periodicity alone can latch onto a quiet hum.
nonisolated struct ProsodyMath {

    // MARK: Configuration (documented constants)

    /// Rolling window for the aggregates (median/variance/fraction/onset rate).
    var windowDuration: TimeInterval = 3.0
    /// RMS below this reads as silence (unvoiced). Tuned for `.measurement`-mode float
    /// PCM, where speech sits well above this and room tone below it.
    var energyFloor: Double = 0.006
    /// YIN CMND aperiodicity threshold: a window with a CMND minimum below this is
    /// periodic enough to call VOICED. 0.15 is YIN's canonical operating point.
    var yinThreshold: Double = 0.15
    /// Human voiced-speech F0 search band (Hz) — bass male ~70 to child/high ~500.
    var minF0: Double = 70
    var maxF0: Double = 500

    // MARK: Frame + rolling state

    /// One analyzed window's result.
    struct Frame: Sendable, Equatable {
        var date: Date
        var rms: Double
        /// The voiced F0 (Hz), or nil when the frame is unvoiced.
        var f0: Double?
        var voiced: Bool
    }

    private var frames: [Frame] = []

    /// All stored properties are defaulted; the explicit init keeps `ProsodyMath()`
    /// available despite the `private` window (a synthesized init would inherit private).
    init() {}

    // MARK: - Pure statics (unit-tested directly)

    /// RMS of a float buffer: `sqrt(mean(x²))`. For a sine of amplitude A this is the
    /// analytic `A/√2`. Uses vDSP where natural.
    static func rms(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return 0 }
        return Double(vDSP.rootMeanSquare(x))
    }

    /// Box-averaging stride decimator: averages each run of `factor` samples then keeps
    /// one. The box filter is a light anti-alias before downsampling — sufficient because
    /// F0 lives at the low end we're keeping. `factor <= 1` (or a too-short buffer) passes
    /// the input through unchanged.
    static func decimate(_ x: [Float], factor: Int) -> [Float] {
        guard factor > 1, x.count >= factor else { return x }
        let outCount = x.count / factor
        var out = [Float](repeating: 0, count: outCount)
        let inv = 1 / Float(factor)
        for i in 0..<outCount {
            var acc: Float = 0
            let base = i * factor
            for k in 0..<factor { acc += x[base + k] }
            out[i] = acc * inv
        }
        return out
    }

    /// YIN F0 estimation. Returns the estimated F0 (Hz) and the minimum aperiodicity
    /// (CMND value) found in the search band; `f0` is nil (UNVOICED) when no CMND minimum
    /// falls below `threshold`. See the type doc for the algorithm.
    static func estimateF0(_ x: [Float], sampleRate: Double,
                           minF0: Double, maxF0: Double,
                           threshold: Double) -> (f0: Double?, aperiodicity: Double) {
        let n = x.count
        guard sampleRate > 0, n > 3, maxF0 > minF0, minF0 > 0 else { return (nil, 1) }
        let tauMin = max(1, Int((sampleRate / maxF0).rounded(.down)))
        let tauMax = min(n - 1, Int((sampleRate / minF0).rounded(.up)))
        guard tauMax > tauMin + 1 else { return (nil, 1) }

        // Difference function d(τ), τ = 1…tauMax (from 1 so the CMND running mean is exact).
        var d = [Double](repeating: 0, count: tauMax + 1)
        for tau in 1...tauMax {
            var sum = 0.0
            let limit = n - tau
            var j = 0
            while j < limit {
                let diff = Double(x[j]) - Double(x[j + tau])
                sum += diff * diff
                j += 1
            }
            d[tau] = sum
        }

        // Cumulative-mean-normalized difference d'(τ) = d(τ)·τ / Σ_{k=1..τ} d(k).
        var cmnd = [Double](repeating: 1, count: tauMax + 1)
        var running = 0.0
        for tau in 1...tauMax {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Double(tau) / running : 1
        }

        // Absolute-threshold pick: first band τ that dips below threshold, walked to the
        // local minimum of that dip. This is what suppresses YIN's octave errors.
        var bestTau = -1
        var tau = tauMin
        while tau <= tauMax {
            if cmnd[tau] < threshold {
                var t = tau
                while t + 1 <= tauMax && cmnd[t + 1] < cmnd[t] { t += 1 }
                bestTau = t
                break
            }
            tau += 1
        }

        guard bestTau >= 0 else {
            // No sub-threshold dip → unvoiced. Report the band minimum as the aperiodicity.
            var minVal = Double.greatestFiniteMagnitude
            for t in tauMin...tauMax where cmnd[t] < minVal { minVal = cmnd[t] }
            return (nil, minVal)
        }

        let aperiodicity = cmnd[bestTau]
        let tauInterp = parabolicMinimum(cmnd, at: bestTau, lo: tauMin, hi: tauMax)
        let f0 = sampleRate / tauInterp
        // Reject an out-of-band interpolation artifact.
        guard f0 >= minF0 * 0.9, f0 <= maxF0 * 1.1 else { return (nil, aperiodicity) }
        return (f0, aperiodicity)
    }

    /// Parabolic interpolation of the sub-sample minimum around index `i` (bounded to a
    /// ±1-sample nudge), for sub-sample F0 precision.
    private static func parabolicMinimum(_ y: [Double], at i: Int, lo: Int, hi: Int) -> Double {
        guard i > lo, i < hi else { return Double(i) }
        let y0 = y[i - 1], y1 = y[i], y2 = y[i + 1]
        let denom = y0 + y2 - 2 * y1
        guard abs(denom) > 1e-12 else { return Double(i) }
        let delta = 0.5 * (y0 - y2) / denom
        return Double(i) + max(-1, min(1, delta))
    }

    /// Map baseline-relative prosody to a voice AROUSAL `Meter` — arousal ONLY (Juslin &
    /// Laukka 2003: arousal rides F0 mean/variance, intensity and tempo; valence is
    /// markedly inconsistent, so voice never produces valence or a discrete emotion).
    ///
    /// `value` is a 0…1 activation LEVEL centred at 0.5 for a baseline-calm voice — above
    /// 0.5 when pitch/loudness climb over the user's own baseline, below when they fall.
    /// It is MONOTONE increasing in both `f0Delta` and `intensityDelta` (until the ±scale
    /// clamps saturate) and clamped to [0, 1]. `confidence` is capped by `maxConfidence`
    /// and scaled by `maturity × availability`, so it can never exceed the maturity
    /// ceiling — an unlearned baseline reads honestly low.
    static func arousal(f0Delta: Double, intensityDelta: Double,
                        f0Scale: Double, intensityScale: Double,
                        maturity: Double, availability: Double,
                        maxConfidence: Double,
                        f0Weight: Double = 0.5, intensityWeight: Double = 0.5) -> Meter {
        let f0n = max(-1, min(1, f0Delta / f0Scale))
        let intn = max(-1, min(1, intensityDelta / intensityScale))
        let activation = f0Weight * f0n + intensityWeight * intn        // roughly [-1, 1]
        let value = max(0, min(1, 0.5 + 0.5 * activation))
        let m = max(0, min(1, maturity))
        let a = max(0, min(1, availability))
        let confidence = max(0, min(1, maxConfidence * m * a))
        return Meter(value: value, confidence: confidence)
    }

    // MARK: - Ingest (per analysis window)

    /// Fold one analysis window (a decimated tap buffer at `sampleRate`) into the rolling
    /// state: compute RMS + F0 + the VOICED decision (the VAD), append the frame, and
    /// prune the window. Returns the frame for inspection/testing.
    @discardableResult
    mutating func ingest(samples: [Float], sampleRate: Double, date: Date) -> Frame {
        let level = Self.rms(samples)
        let (f0, aperiodicity) = Self.estimateF0(samples, sampleRate: sampleRate,
                                                 minF0: minF0, maxF0: maxF0,
                                                 threshold: yinThreshold)
        let voiced = level >= energyFloor && f0 != nil && aperiodicity < yinThreshold
        let frame = Frame(date: date, rms: level, f0: voiced ? f0 : nil, voiced: voiced)
        frames.append(frame)
        prune(now: date)
        return frame
    }

    /// Advance the rolling window WITHOUT a new sample (so aggregates age between polls).
    mutating func age(now: Date) { prune(now: now) }

    /// Drop all rolling state (used on (re)activation and stop).
    mutating func clear() { frames.removeAll() }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-windowDuration)
        frames.removeAll { $0.date < cutoff }
    }

    // MARK: - Rolling aggregates

    private var voicedF0s: [Double] { frames.compactMap { $0.voiced ? $0.f0 : nil } }

    /// Median voiced F0 (Hz) over the window; nil with no voiced frames.
    var f0Median: Double? {
        let fs = voicedF0s.sorted()
        guard !fs.isEmpty else { return nil }
        let mid = fs.count / 2
        return fs.count.isMultiple(of: 2) ? (fs[mid - 1] + fs[mid]) / 2 : fs[mid]
    }

    /// Variance of voiced F0 (Hz²) over the window; 0 with < 2 voiced frames.
    var f0Variance: Double {
        let fs = voicedF0s
        guard fs.count > 1 else { return 0 }
        let mean = fs.reduce(0, +) / Double(fs.count)
        return fs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(fs.count)
    }

    /// Median RMS intensity over ALL window frames (quiet gaps included) — a loudness
    /// display value.
    var intensityMedian: Double {
        let rs = frames.map { $0.rms }.sorted()
        guard !rs.isEmpty else { return 0 }
        let mid = rs.count / 2
        return rs.count.isMultiple(of: 2) ? (rs[mid - 1] + rs[mid]) / 2 : rs[mid]
    }

    /// Median RMS intensity over VOICED frames only — the loudness both the arousal
    /// reading and the per-user intensity baseline use, so they compare like-for-like
    /// (quiet gaps don't drag the speaking-loudness down). 0 with no voiced frames.
    var voicedIntensityMedian: Double {
        let rs = frames.compactMap { $0.voiced ? $0.rms : nil }.sorted()
        guard !rs.isEmpty else { return 0 }
        let mid = rs.count / 2
        return rs.count.isMultiple(of: 2) ? (rs[mid - 1] + rs[mid]) / 2 : rs[mid]
    }

    /// The instantaneous level of the most recent frame (the raw meter).
    var currentLevel: Double { frames.last?.rms ?? 0 }

    /// Fraction of window frames that are voiced (0…1) — a speaking-density proxy.
    var voicedFraction: Double {
        guard !frames.isEmpty else { return 0 }
        return Double(frames.filter { $0.voiced }.count) / Double(frames.count)
    }

    /// Voiced ONSETS per second over the window (unvoiced→voiced transitions ÷ span) — a
    /// coarse vocal-tempo proxy (syllable-ish onset rate), NOT a true syllabic rate.
    var onsetRate: Double {
        guard frames.count > 1, let first = frames.first, let last = frames.last else { return 0 }
        var onsets = 0
        for i in 1..<frames.count where frames[i].voiced && !frames[i - 1].voiced { onsets += 1 }
        let span = max(0.001, last.date.timeIntervalSince(first.date))
        return Double(onsets) / span
    }

    /// The current-frame voiced decision — the live VAD flag.
    var isSpeaking: Bool { frames.last?.voiced ?? false }

    /// The most-recent voiced F0 (Hz) for the raw HUD; nil if unvoiced.
    var latestVoicedF0: Double? { frames.reversed().first { $0.voiced }?.f0 }

    var frameCount: Int { frames.count }
    var voicedCount: Int { frames.filter { $0.voiced }.count }
}

// MARK: - VoiceAnalyzer (the off-main actor owning the mic + SoundAnalysis)

/// Owns an `AVAudioEngine` input tap + a best-effort `SoundAnalysis` stream, running
/// prosody off the main actor (the `FaceAnalyzer` idiom). Every tap buffer is decimated
/// toward a YIN-friendly rate and folded into `ProsodyMath`; `snapshot()` exposes the
/// rolling state. START IS DEFENSIVE (K6, PRD §8.0): any session/engine/input failure
/// throws a typed `.startFailed` reason and never crashes; the channel maps that to
/// `.unavailable`. Foreground-only: `stop()` removes the tap, stops the engine, and
/// deactivates the session so no idle mic remains.
actor VoiceAnalyzer {

    /// A typed, human-readable failure reason for a defensive start (surfaced on the
    /// snapshot + the K6 HUD — never thrown past the channel). `nonisolated` so it is
    /// constructed/thrown from the actor's own (non-MainActor) executor cleanly under the
    /// project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` regime.
    nonisolated enum StartError: Error, CustomStringConvertible {
        case audioSession(String)
        case noInput
        case engineStart(String)
        var description: String {
            switch self {
            case .audioSession(let m): return "Audio session unavailable (\(m))"
            case .noInput: return "No microphone input available"
            case .engineStart(let m): return "Audio engine failed to start (\(m))"
            }
        }
    }

    // MARK: Configuration (documented)

    /// Decimate the native input toward ~16 kHz for YIN: it still resolves the ≤500 Hz
    /// voiced band with room to spare while cutting the difference-function cost ~3× vs
    /// 48 kHz. The channel polls at ~3 Hz, so per-buffer cost is not the bottleneck, but
    /// a lean YIN keeps the tap thread light.
    private let targetSampleRate: Double = 16_000
    /// ~85 ms at 48 kHz — several pitch periods (YIN's minimum) per analysis window.
    private let tapBufferSize: AVAudioFrameCount = 4096

    // MARK: State

    private var engine: AVAudioEngine?
    private var math = ProsodyMath()
    private(set) var running = false
    /// The last defensive failure reason (nil while healthy) — surfaced on `snapshot()`.
    private(set) var lastReason: String?
    /// Best-effort on-device laughter/cry detection; nil when SoundAnalysis is unavailable.
    private var soundEvents: VoiceSoundEvents?

    // MARK: - Lifecycle

    /// Configure the audio session for mic-while-camera, install the input tap, and start
    /// the engine. Throws a typed `StartError` on any failure (the defensive K6 posture);
    /// on success `running == true` and buffers begin flowing into `ProsodyMath`.
    ///
    /// Audio-session choice: `.playAndRecord` + `.measurement` mode + `.mixWithOthers`.
    /// `.measurement` disables the system input processing (AGC/EQ) so F0 and intensity
    /// are read from RAW audio (honest prosody, relative to the user's own baseline);
    /// `.mixWithOthers` lets the mic tap COEXIST with the live Persona `AVCaptureSession`
    /// (video-only) and any system audio without interrupting them — exactly the K6
    /// coexistence the keystone verifies. `.playAndRecord` (over `.record`) is the most
    /// permissive routing that reliably shares the input while capture runs.
    func start() throws {
        if running { return }

        #if os(visionOS) // macOS has no AVAudioSession; the engine runs there only in affect-replay
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            lastReason = StartError.audioSession(error.localizedDescription).description
            throw StartError.audioSession(error.localizedDescription)
        }
        #endif

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateSession()
            lastReason = StartError.noInput.description
            throw StartError.noInput
        }

        // Best-effort sound events (a failure here leaves prosody fully intact).
        let sounds = VoiceSoundEvents(format: format)
        soundEvents = sounds

        math.clear()
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { [weak self] buffer, when in
            // Feed SoundAnalysis SYNCHRONOUSLY on the tap thread — the tap is serial and
            // this avoids capturing the non-Sendable buffer across any queue boundary
            // (zero Sendable warnings). Then copy mono samples into a Sendable array and
            // hop into the actor for the prosody math.
            sounds?.analyze(buffer, at: when.sampleTime)
            guard let self, let mono = VoiceAnalyzer.monoSamples(from: buffer) else { return }
            let rate = buffer.format.sampleRate
            let at = Date()
            Task { await self.ingest(samples: mono, sampleRate: rate, date: at) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            soundEvents = nil
            deactivateSession()
            lastReason = StartError.engineStart(error.localizedDescription).description
            throw StartError.engineStart(error.localizedDescription)
        }

        self.engine = engine
        running = true
        lastReason = nil
    }

    /// Fully release the mic: remove the tap, stop the engine, drop SoundAnalysis, clear
    /// the window, and deactivate the session (no idle mic while disabled/backgrounded).
    func stop() {
        running = false
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        soundEvents = nil
        math.clear()
        deactivateSession()
    }

    private func deactivateSession() {
        #if os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    // MARK: - Ingest / snapshot

    /// Fold one tap buffer into `ProsodyMath` (decimated toward the YIN target rate).
    private func ingest(samples: [Float], sampleRate: Double, date: Date) {
        guard running else { return }
        let factor = max(1, Int((sampleRate / targetSampleRate).rounded()))
        let decimated = ProsodyMath.decimate(samples, factor: factor)
        let effectiveRate = sampleRate / Double(factor)
        math.ingest(samples: decimated, sampleRate: effectiveRate, date: date)
    }

    /// The current rolling snapshot (async — crosses back to the `@MainActor` channel).
    /// Ages the window to `now` first so a poll during a speech gap sees a fresh (decaying)
    /// state, and drains any pending sound events.
    func snapshot() -> ProsodySnapshot {
        guard running else { return .off(reason: lastReason) }
        let now = Date()
        math.age(now: now)
        let events = soundEvents?.drain() ?? (laughter: false, cry: false)
        return ProsodySnapshot(
            date: now,
            engineRunning: true,
            unavailableReason: nil,
            f0Median: math.f0Median,
            f0Variance: math.f0Variance,
            latestVoicedF0: math.latestVoicedF0,
            intensityMedian: math.intensityMedian,
            voicedIntensityMedian: math.voicedIntensityMedian,
            currentLevel: math.currentLevel,
            voicedFraction: math.voicedFraction,
            onsetRate: math.onsetRate,
            isSpeaking: math.isSpeaking,
            frameCount: math.frameCount,
            voicedCount: math.voicedCount,
            laughter: events.laughter,
            cry: events.cry
        )
    }

    // MARK: - Helpers

    /// Extract a mono `[Float]` (a Sendable snapshot) from a PCM buffer, averaging any
    /// extra channels. `nonisolated` so it runs on the tap thread before the actor hop.
    nonisolated static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let ch = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let channels = Int(buffer.format.channelCount)
        if channels <= 1 {
            return Array(UnsafeBufferPointer(start: ch[0], count: frames))
        }
        var out = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let p = ch[c]
            for i in 0..<frames { out[i] += p[i] }
        }
        let inv = 1 / Float(channels)
        for i in 0..<frames { out[i] *= inv }
        return out
    }
}

// MARK: - VoiceSoundEvents (best-effort laughter / cry, off the actor)

/// On-device sound-event detection (laughter / crying) for CORROBORATION ONLY (US-D12;
/// F6 consumes it later). A `nonisolated final class @unchecked Sendable` — the
/// `CoreMLEmotionScorer` idiom — owning a `SoundAnalysis` stream analyzer + a results
/// observer, accumulating detected events behind a lock and handing them to the actor on
/// `drain()`. It NEVER produces a verdict: a laughter tick is corroboration framing, never
/// a discrete-emotion claim. If the classifier can't be created, `init?` returns nil and
/// the channel simply runs prosody-only.
private nonisolated final class VoiceSoundEvents: @unchecked Sendable {
    private let analyzer: SNAudioStreamAnalyzer
    private let observer = Observer()
    private let lock = NSLock()
    private var laughter = false
    private var cry = false
    private var installed = false

    init?(format: AVAudioFormat) {
        analyzer = SNAudioStreamAnalyzer(format: format)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try analyzer.add(request, withObserver: observer)
            installed = true
        } catch {
            return nil
        }
        observer.onEvent = { [weak self] kind in
            guard let self else { return }
            self.lock.lock()
            switch kind {
            case .laughter: self.laughter = true
            case .cry: self.cry = true
            }
            self.lock.unlock()
        }
    }

    /// Analyze one buffer synchronously (called on the serial tap thread — see the tap
    /// block's note on avoiding a non-Sendable cross-queue capture).
    func analyze(_ buffer: AVAudioPCMBuffer, at frame: AVAudioFramePosition) {
        guard installed else { return }
        analyzer.analyze(buffer, atAudioFramePosition: frame)
    }

    /// Read and clear the events accumulated since the last drain.
    func drain() -> (laughter: Bool, cry: Bool) {
        lock.lock(); defer { lock.unlock() }
        let out = (laughter, cry)
        laughter = false
        cry = false
        return out
    }

    nonisolated enum Kind { case laughter, cry }

    /// The `SNResultsObserving` sink. Fires `onEvent` when laughter/crying clears a
    /// documented confidence threshold — the built-in v1 classifier is noisy, so 0.5
    /// trades away marginal detections to keep false corroboration low. `nonisolated`
    /// because SoundAnalysis invokes it off the main actor.
    private nonisolated final class Observer: NSObject, SNResultsObserving {
        var onEvent: ((Kind) -> Void)?
        static let threshold = 0.5

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult else { return }
            for c in classification.classifications where c.confidence >= Observer.threshold {
                let id = c.identifier.lowercased()
                if id.contains("laugh") { onEvent?(.laughter); return }
                if id.contains("cry") || id.contains("sob") { onEvent?(.cry); return }
            }
        }
        func request(_ request: SNRequest, didFailWithError error: Error) {}
        func requestDidComplete(_ request: SNRequest) {}
    }
}

#endif
