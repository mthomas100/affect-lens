//
//  ToggleImmersiveSpaceButton.swift
//  AffectLens
//
//  Opens or closes the emotion aura (the optional mixed-immersion space).
//

import SwiftUI

struct ToggleImmersiveSpaceButton: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Button {
            Task { @MainActor in await toggle() }
        } label: {
            Label(appModel.auraState == .open ? "Hide Aura" : "Show Aura",
                  systemImage: appModel.auraState == .open ? "circle.dashed" : "circle.hexagongrid.fill")
        }
        .disabled(appModel.auraState == .transitioning)
    }

    private func toggle() async {
        switch appModel.auraState {
        case .open:
            appModel.auraState = .transitioning
            await dismissImmersiveSpace()
            // ImmersiveView.onDisappear sets the final .closed state.
        case .closed:
            appModel.auraState = .transitioning
            switch await openImmersiveSpace(id: AppModel.auraSpaceID) {
            case .opened:
                appModel.auraState = .open
            default:
                appModel.auraState = .closed
            }
        case .transitioning:
            break
        }
    }
}
