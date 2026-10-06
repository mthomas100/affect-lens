//
//  ContentView.swift
//  AffectLens
//
//  The main window: the Emotion lens grid and Lab Mode, sharing one camera feed and
//  one engine. Frames go straight from the feed into `EmotionEngine.ingest`, which
//  throttles to its analysis cadence and fans each analysis out through the hub.
//

import SwiftUI

struct ContentView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case emotion = "Emotion"
        case lab = "Lab"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var appModel
    @State private var tab: Tab = ProcessInfo.processInfo.arguments.contains("-lab") ? .lab : .emotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                if appModel.camera.isDemoVideo {
                    Label("Demo video in place of the camera", systemImage: "film")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = appModel.camera.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding([.horizontal, .top], 16)

            switch tab {
            case .emotion:
                EmotionLensHomeView(hub: appModel.affectHub, camera: appModel.camera)
                    .padding(10)
            case .lab:
                LabModeView(hub: appModel.affectHub)
                    .padding(10)
            }
        }
        .frame(minWidth: 1010, minHeight: 640, alignment: .topLeading)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            ToggleImmersiveSpaceButton()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassBackgroundEffect()
        }
        .task { await startFeed() }
        .onDisappear {
            appModel.camera.onFrame = nil
            appModel.camera.stop()
        }
    }

    private func startFeed() async {
        let engine = appModel.emotionEngine
        appModel.camera.onFrame = { pixelBuffer, _ in
            engine.ingest(pixelBuffer)
        }
        try? await appModel.camera.start()
    }
}
