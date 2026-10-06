//
//  AffectLensApp.swift
//  AffectLens
//
//  A window in the shared space hosts the emotion lenses and Lab Mode; an optional
//  mixed-immersion space adds the emotion aura around the wearer.
//

import SwiftUI

@main
struct AffectLensApp: App {
    @State private var appModel = AppModel()

    init() {
        #if os(visionOS) && DEBUG
        EmotionSelfTests.runAll()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .defaultSize(width: 1120, height: 780)

        // Detachable lens window (US-lab, PRD v2 §6.8): a plain second WindowGroup keyed
        // by `Lens` so a Lab channel column (or a lens focus view) can pop a lens out
        // beside the main window for live congruence/conflict comparison.
        // `UIApplicationSupportsMultipleScenes` is already YES in Info.plist, so NO
        // scene-manifest change is needed. The detached window is READ-ONLY: it never owns
        // the camera (the main window keeps the single `CameraFeed`), so there is no
        // capture contention.
        WindowGroup(id: "lens-detail", for: Lens.self) { $lens in
            LensDetailWindow(lens: lens)
                .environment(appModel)
        }
        .defaultSize(width: 560, height: 720)

        ImmersiveSpace(id: AppModel.auraSpaceID) {
            ImmersiveView()
                .environment(appModel)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
