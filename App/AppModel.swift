//
//  AppModel.swift
//  AffectLens
//
//  App-wide state shared by the window and the immersive aura space.
//

import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let auraSpaceID = "EmotionAura"

    enum AuraState {
        case closed
        case transitioning
        case open
    }

    /// Whether the optional mixed-immersion aura space is showing.
    var auraState: AuraState = .closed

    /// The affect-sensing composition root (PRD v2 §7.3). Owns the always-on
    /// face lens today; later items grow it with the eyes/hands/head/voice/
    /// interaction channels, fusion, and an events log. Deliberately a SEPARATE
    /// object from `EmotionEngine` — PRD §5.2 REJECTS growing the face pipeline
    /// into the hub.
    let affectHub = AffectHub()

    /// Shared emotion-recognition engine (camera frames in, emotion readings
    /// out). Now a back-compat alias onto `affectHub.face`, so every existing
    /// `appModel.emotionEngine` consumer resolves through the hub with ZERO
    /// call-site changes and identical behavior.
    var emotionEngine: EmotionEngine { affectHub.face }

    /// The one frame source for the whole app. Only the main window starts it, so there
    /// is never more than one capture session.
    let camera = CameraFeed(source: DemoVideo.url.map { .video($0) } ?? .camera)
}

/// A video file that stands in for the camera, for the simulator and for demos.
/// Pass `-demo-video <path>` as a launch argument (or set `AFFECT_DEMO_VIDEO`); the
/// file plays on a loop in real time and goes through exactly the live pipeline.
enum DemoVideo {
    static var url: URL? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demo-video"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1])
        }
        if let path = ProcessInfo.processInfo.environment["AFFECT_DEMO_VIDEO"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
