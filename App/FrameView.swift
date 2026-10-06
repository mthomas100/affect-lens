//
//  FrameView.swift
//  AffectLens
//
//  Shows a CVPixelBuffer aspect-fit, matching `FaceLandmarkOverlay.fittedRect`.
//

import CoreImage
import SwiftUI

struct FrameView: View {
    let pixelBuffer: CVPixelBuffer?

    private static let context = CIContext(options: [.cacheIntermediates: false])

    var body: some View {
        if let pixelBuffer, let image = Self.image(from: pixelBuffer) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
        } else {
            Rectangle()
                .fill(.black.opacity(0.25))
                .overlay {
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private static func image(from buffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(ci, from: ci.extent)
    }
}
