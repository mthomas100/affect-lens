//
//  Permissions.swift
//  AffectLens
//
//  One place for every permission the sensing channels need: camera (face),
//  microphone (voice), HealthKit State of Mind (ESM write-back) and the ARKit
//  hand-tracking grant (recorded here by the immersive sensing coordinator).
//

#if os(visionOS) || os(macOS)

import AVFoundation
import HealthKit

enum Permissions {
    // MARK: - Camera

    /// Camera access for the face channel: asks on first use, then reports the stored
    /// decision. `false` covers both a refusal and a device restriction.
    static func cameraAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return status == .authorized
    }

    // MARK: - Hand tracking

    /// ARKit hand-tracking authorization state (US-D13a, PRD v2 §7.4 point 6). Unlike
    /// camera / mic, ARKit auth is NOT requested here — it is requested via
    /// `ARKitSession.requestAuthorization(for: [.handTracking])` at immersive-space open
    /// (only then can hand tracking run). The `ImmersiveSensingCoordinator` writes the
    /// grant result here so ONE status view can read it through the same `Permissions`
    /// surface as the other permissions. `nil` = not yet requested (space never opened
    /// this launch); `true` / `false` = the last grant result.
    static var handTrackingAuthorized: Bool?

    // MARK: - Microphone

    /// Returns `true` if the microphone is authorized (the voice channel, US-D12).
    static func isMicrophoneAuthorized() -> Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Requests microphone access if status is `.undetermined` and returns whether it is
    /// authorized — the microphone counterpart of `cameraAccess()`.
    ///
    /// Uses `AVAudioApplication.requestRecordPermission` (the iOS 17 / visionOS-era
    /// replacement for the deprecated `AVAudioSession.requestRecordPermission`; verified
    /// spelling — the nested enum is lower-cased `recordPermission`). The voice channel's
    /// VAD is ENERGY/PERIODICITY based (see `ProsodyMath`), so there is **no**
    /// `SFSpeechRecognizer` and therefore **no** speech-recognition permission — fewer
    /// permissions and, by construction, no transcription surface.
    static func requestMicIfNeeded() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    // MARK: - HealthKit (US-E17, PRD v2 §5.7 / §6.8)

    /// Whether Health data is available on THIS device — the runtime gate that answers
    /// the PRD §10 verify-item (HKStateOfMind WRITE on visionOS 26). `false` ⇒ the ESM
    /// loop stays local-only.
    static func isHealthAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Request SHARE (write) authorization for the State-of-Mind type if needed, and
    /// report whether the app is authorized to save afterwards. Purpose-first: the
    /// system consent sheet is driven by `NSHealthUpdateUsageDescription`
    /// (Info.plist). Never throws to the caller — a thrown auth error reads as "not
    /// authorized" ⇒ the write stays local-only.
    ///
    /// Like `cameraAccess()`/`requestMicIfNeeded`: no-op when already
    /// authorized. Only WRITE (share) is requested — no read — so there is no health
    /// data read surface. (For sharing types `authorizationStatus(for:)` reports the
    /// real grant, unlike read types.)
    static func requestHealthIfNeeded(store: HKHealthStore) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let type = HKObjectType.stateOfMindType()
        if store.authorizationStatus(for: type) == .sharingAuthorized { return true }
        do {
            try await store.requestAuthorization(toShare: [type], read: [])
        } catch {
            return false
        }
        return store.authorizationStatus(for: type) == .sharingAuthorized
    }
}

#endif
