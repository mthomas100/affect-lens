//
//  MacStubs.swift
//  affect-replay
//
//  macOS stand-ins for the two visionOS-only seams the engine touches. Hand tracking
//  and the device pose need ARKit in an immersive space, which macOS does not have, so
//  on the Mac the hands channel simply stays unavailable (the engine already treats that
//  as a typed state, not an error).
//

#if os(macOS)
import Foundation

@MainActor
final class ImmersiveSensingCoordinator {
    init() {}
    func connect(hub: AffectHub) {}
    func setPollHz(_ hz: Double) {}
    func startIfNeeded() {}
    func stop() {}
}
#endif

#if os(macOS)
/// The app's composition root, reduced to what the engine and its self-tests touch.
/// (The visionOS app's `AppModel` adds the immersive-space state.)
@MainActor
@Observable
final class AppModel {
    let affectHub = AffectHub()
    var emotionEngine: EmotionEngine { affectHub.face }
}
#endif
