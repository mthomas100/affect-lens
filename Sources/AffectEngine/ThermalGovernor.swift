//
//  ThermalGovernor.swift
//  AffectLens
//
//  THE SENSING GOVERNOR (US-D13b, PRD v2 §8.1 cross-cutting / §8.5) — the thermal state
//  as a REAL scheduler. `ProcessInfo.thermalState` drives a pure policy map that trims
//  compute as the device warms, so continuous Vision + FER+ + immersive ARKit stays
//  within a sustainable thermal envelope instead of thermal-throttling uncontrolled.
//
//  It lands with the first immersive channel (the head/hands wave) and is OWNED by
//  `AffectHub`. It observes the thermal state (initial read + the change notification),
//  maps each tier to a `SensingPolicy`, and asks the hub to apply it: the engine's face
//  cadence + FER+ enable, the immersive poll rate, and whether the aux channels
//  (eyes/hands/voice/head) run at all. On a real POLICY change it narrates ONE honest,
//  non-alarming insight; a return to `.nominal` restores everything.
//
//  BYTE-IDENTICAL DEFAULT (the law): the `.nominal` policy is exactly today's behavior
//  (face 1/15 s, FER+ on, poll 10 Hz, aux on), so at a cool device the governor changes
//  NOTHING — applying the nominal policy is a no-op and no insight is narrated.
//
//  The policy map is a PURE, `nonisolated` value type — deterministic and self-testable
//  off the main actor (the project's MainActor-default regime); the governor class that
//  reads `ProcessInfo` and mutates the hub is `@MainActor`.
//

#if os(visionOS) || os(macOS)

import Foundation

// MARK: - SensingPolicy (the pure tier → knobs map)

/// The sensing knobs for one thermal tier (PRD v2 §8.1). Pure value type; the mapping
/// `policy(for:)` is the single source of truth the governor applies and the self-test
/// asserts exactly.
nonisolated struct SensingPolicy: Equatable, Sendable {
    /// The face pipeline's analysis-cadence cap (`EmotionEngine.minProcessInterval`).
    var faceInterval: TimeInterval
    /// Whether the FER+ Core ML expert scores this tier (`EmotionEngine.mlScoringEnabled`).
    var ferPlusEnabled: Bool
    /// The immersive device-anchor poll rate (`ImmersiveSensingCoordinator.setPollHz`).
    var immersivePollHz: Double
    /// Whether the aux channels (eyes / hands / voice / head) process at all. False ⇒
    /// face + baseline ONLY (the `.critical` floor).
    var auxChannelsEnabled: Bool

    /// The FULL-sensing policy = today's exact behavior (the byte-identical anchor).
    static let full = SensingPolicy(faceInterval: 1.0 / 15.0, ferPlusEnabled: true,
                                    immersivePollHz: 10, auxChannelsEnabled: true)

    /// Map a thermal tier → its policy (PRD v2 §8.1 cross-cutting):
    ///   • `.nominal` → all on (the byte-identical default).
    ///   • `.fair`    → SAME core knobs as nominal. The PRD's "`.fair` FM off" is RESERVED:
    ///     the FoundationModels narrator (§8.5, gated on K5) does not exist yet, so there
    ///     is nothing to switch off here — documented, not silently dropped.
    ///   • `.serious` → drop FER+, halve the face cadence (15→8 Hz), immersive poll → 5 Hz.
    ///   • `.critical`→ face + baseline only: FER+ off, 8 Hz face, poll → 2 Hz, aux channels
    ///     gated off.
    /// A future `@unknown` tier defaults to FULL sensing (fail toward no-behavior-change,
    /// never an accidental degradation on an OS that adds a case).
    static func policy(for tier: ProcessInfo.ThermalState) -> SensingPolicy {
        switch tier {
        case .nominal:
            return SensingPolicy(faceInterval: 1.0 / 15.0, ferPlusEnabled: true,
                                 immersivePollHz: 10, auxChannelsEnabled: true)
        case .fair:
            // Same core as nominal; FM-off is reserved (no FM narrator yet — §8.5).
            return SensingPolicy(faceInterval: 1.0 / 15.0, ferPlusEnabled: true,
                                 immersivePollHz: 10, auxChannelsEnabled: true)
        case .serious:
            return SensingPolicy(faceInterval: 1.0 / 8.0, ferPlusEnabled: false,
                                 immersivePollHz: 5, auxChannelsEnabled: true)
        case .critical:
            return SensingPolicy(faceInterval: 1.0 / 8.0, ferPlusEnabled: false,
                                 immersivePollHz: 2, auxChannelsEnabled: false)
        @unknown default:
            return .full
        }
    }
}

// MARK: - ThermalGovernor (the @Observable scheduler)

/// The sensing governor (US-D13b, PRD v2 §8.1 / §8.5). `@MainActor @Observable` so it can
/// be observed (a HUD may surface the live tier later) and so it mutates the hub's
/// MainActor channels directly. Owned by `AffectHub`, wired once in `AffectHub.init`.
@MainActor
@Observable
final class ThermalGovernor {

    /// The live thermal tier.
    private(set) var tier: ProcessInfo.ThermalState = .nominal
    /// The policy currently applied.
    private(set) var policy: SensingPolicy = .full

    @ObservationIgnored private weak var hub: AffectHub?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {}

    /// Called once by `AffectHub.init` after the channels exist. Reads the initial thermal
    /// state, applies its policy (a no-op at `.nominal` — byte-identical), and subscribes to
    /// `thermalStateDidChangeNotification`. The initial apply passes `changedFrom: nil`, so
    /// no insight is narrated for merely starting up (only a real change is news).
    func connect(hub: AffectHub) {
        self.hub = hub
        tier = ProcessInfo.processInfo.thermalState
        policy = SensingPolicy.policy(for: tier)
        hub.applyThermalPolicy(policy, changedFrom: nil, tier: tier)
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            // The notification may post off-main; upgrade the weak ref (a reference op, valid
            // off-main) then hop to the MainActor to touch the hub.
            guard let self else { return }
            Task { @MainActor in self.thermalStateChanged() }
        }
    }

    /// Re-read the tier and, if it changed, recompute + apply the policy.
    private func thermalStateChanged() {
        let newTier = ProcessInfo.processInfo.thermalState
        guard newTier != tier else { return }
        let old = tier
        tier = newTier
        policy = SensingPolicy.policy(for: newTier)
        hub?.applyThermalPolicy(policy, changedFrom: old, tier: newTier)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

#endif
