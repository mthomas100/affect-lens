//
//  FaceLandmarkOverlay.swift
//  AffectLens
//
//  Draws the detected face box and landmark constellation over the video
//  preview, correctly mapped onto the aspect-fitted image rect.
//

import SwiftUI

#if os(visionOS)
struct FaceLandmarkOverlay: View {
    let overlay: FaceOverlayData?
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            if let overlay {
                let fitted = Self.fittedRect(imageAspect: overlay.imageAspect, in: geo.size)
                Canvas { ctx, _ in
                    let faceRect = CGRect(
                        x: fitted.minX + overlay.faceRect.minX * fitted.width,
                        y: fitted.minY + overlay.faceRect.minY * fitted.height,
                        width: overlay.faceRect.width * fitted.width,
                        height: overlay.faceRect.height * fitted.height
                    )
                    ctx.stroke(
                        Path(roundedRect: faceRect, cornerRadius: 10),
                        with: .color(tint.opacity(0.55)),
                        lineWidth: 1.5
                    )
                    for p in overlay.points {
                        let cp = CGPoint(
                            x: fitted.minX + p.x * fitted.width,
                            y: fitted.minY + p.y * fitted.height
                        )
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: cp.x - 1.4, y: cp.y - 1.4, width: 2.8, height: 2.8)),
                            with: .color(tint.opacity(0.85))
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The rect a `scaledToFit` image of the given aspect occupies in a view.
    static func fittedRect(imageAspect: CGFloat, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, imageAspect > 0 else { return .zero }
        let viewAspect = size.width / size.height
        if viewAspect > imageAspect {
            let h = size.height
            let w = h * imageAspect
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: h)
        } else {
            let w = size.width
            let h = w / imageAspect
            return CGRect(x: 0, y: (size.height - h) / 2, width: w, height: h)
        }
    }
}
#endif
