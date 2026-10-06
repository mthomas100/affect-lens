//
//  FaceGeometry.swift
//  AffectLens
//
//  Converts Vision face landmarks into a scale/rotation-invariant set of
//  facial measurements ("metrics"). All values are expressed in interocular
//  distance (IOD) units after roll correction, so they are comparable across
//  distances, positions, and head tilt — the foundation for stable Action
//  Unit estimation.
//

import Foundation
import CoreGraphics

#if os(visionOS) || os(macOS)
import Vision

/// A named scalar facial measurement, in IOD units, roll-corrected, y-up.
nonisolated enum FacialMetric: String, CaseIterable, Codable, Sendable {
    case eyeOpenLeft          // palpebral fissure height, visual-left eye
    case eyeOpenRight
    case browInnerLeft        // inner brow height above eye-center line
    case browInnerRight
    case browOuterLeft        // outer brow height above eye-center line
    case browOuterRight
    case browGapX             // horizontal gap between inner brow points
    case mouthWidth           // lip corner to lip corner
    case cornerLiftLeft       // lip corner height relative to mouth centroid
    case cornerLiftRight
    case outerLipHeight       // total outer-lip vertical extent
    case innerLipGap          // inner-lip aperture (mouth openness)
    case philtrum             // nose base to upper-lip top distance
    case chinDrop             // mouth centroid to chin distance
}

/// A complete measurement set for one frame.
nonisolated struct FacialMetrics: Sendable, Codable {
    var values: [FacialMetric: Double]

    subscript(_ m: FacialMetric) -> Double {
        get { values[m] ?? 0 }
        set { values[m] = newValue }
    }

    /// Typical neutral-face values in IOD units (population prior).
    /// Used until per-user calibration replaces them.
    static let defaultNeutral = FacialMetrics(values: [
        .eyeOpenLeft: 0.17, .eyeOpenRight: 0.17,
        .browInnerLeft: 0.35, .browInnerRight: 0.35,
        .browOuterLeft: 0.30, .browOuterRight: 0.30,
        .browGapX: 0.42,
        .mouthWidth: 0.80,
        .cornerLiftLeft: -0.02, .cornerLiftRight: -0.02,
        .outerLipHeight: 0.28,
        .innerLipGap: 0.02,
        .philtrum: 0.22,
        .chinDrop: 0.55,
    ])

    /// Per-metric median across samples — robust baseline estimator.
    static func median(of samples: [FacialMetrics]) -> FacialMetrics? {
        guard !samples.isEmpty else { return nil }
        var out = [FacialMetric: Double]()
        for m in FacialMetric.allCases {
            let sorted = samples.map { $0[m] }.sorted()
            let mid = sorted.count / 2
            out[m] = sorted.count.isMultiple(of: 2)
                ? (sorted[mid - 1] + sorted[mid]) / 2
                : sorted[mid]
        }
        return FacialMetrics(values: out)
    }

    func lerp(toward target: FacialMetrics, alpha: Double) -> FacialMetrics {
        var out = [FacialMetric: Double]()
        for m in FacialMetric.allCases {
            out[m] = self[m] * (1 - alpha) + target[m] * alpha
        }
        return FacialMetrics(values: out)
    }
}

/// Landmark points prepared for drawing on top of the video preview.
/// Coordinates are normalized to the image with origin at TOP-left (SwiftUI-ready).
nonisolated struct FaceOverlayData: Sendable, Equatable {
    var faceRect: CGRect
    var points: [CGPoint]
    var imageAspect: CGFloat   // width / height of the source image
}

/// Extracts `FacialMetrics` + overlay data from a `VNFaceObservation`.
nonisolated enum FaceGeometry {

    struct Extraction: Sendable {
        var metrics: FacialMetrics
        var overlay: FaceOverlayData
        var landmarkConfidence: Double
        var yaw: Double?
        var roll: Double?
        var pitch: Double?
    }

    static func extract(from observation: VNFaceObservation, imageSize: CGSize) -> Extraction? {
        guard let landmarks = observation.landmarks,
              let leftEyeRegion = landmarks.leftEye,
              let rightEyeRegion = landmarks.rightEye,
              let leftBrowRegion = landmarks.leftEyebrow,
              let rightBrowRegion = landmarks.rightEyebrow,
              let outerLipsRegion = landmarks.outerLips,
              imageSize.width > 1, imageSize.height > 1
        else { return nil }

        // Vision gives pixel coordinates with a bottom-left origin (y-up).
        var leftEye = leftEyeRegion.pointsInImage(imageSize: imageSize)
        var rightEye = rightEyeRegion.pointsInImage(imageSize: imageSize)
        var leftBrow = leftBrowRegion.pointsInImage(imageSize: imageSize)
        var rightBrow = rightBrowRegion.pointsInImage(imageSize: imageSize)
        let outerLips = outerLipsRegion.pointsInImage(imageSize: imageSize)
        let innerLips = landmarks.innerLips?.pointsInImage(imageSize: imageSize) ?? []
        let nose = landmarks.nose?.pointsInImage(imageSize: imageSize) ?? []
        let contour = landmarks.faceContour?.pointsInImage(imageSize: imageSize) ?? []

        guard leftEye.count >= 3, rightEye.count >= 3,
              leftBrow.count >= 2, rightBrow.count >= 2,
              outerLips.count >= 4
        else { return nil }

        // Re-label so "left" is always visual left (smaller x), independent of
        // Vision's subject-relative naming.
        if centroid(leftEye).x > centroid(rightEye).x {
            swap(&leftEye, &rightEye)
            swap(&leftBrow, &rightBrow)
        }

        let eyeL = centroid(leftEye)
        let eyeR = centroid(rightEye)
        let iod = hypot(eyeR.x - eyeL.x, eyeR.y - eyeL.y)
        guard iod > 8 else { return nil } // face too small to measure reliably

        // Roll-corrected, IOD-normalized frame: origin at eye midpoint,
        // x along the eye line, y perpendicular (up).
        let mid = CGPoint(x: (eyeL.x + eyeR.x) / 2, y: (eyeL.y + eyeR.y) / 2)
        let angle = atan2(eyeR.y - eyeL.y, eyeR.x - eyeL.x)
        let cosA = cos(-angle), sinA = sin(-angle)
        func t(_ p: CGPoint) -> CGPoint {
            let dx = p.x - mid.x, dy = p.y - mid.y
            return CGPoint(
                x: (dx * cosA - dy * sinA) / iod,
                y: (dx * sinA + dy * cosA) / iod
            )
        }

        let leftEyeT = leftEye.map(t)
        let rightEyeT = rightEye.map(t)
        let leftBrowT = leftBrow.map(t)
        let rightBrowT = rightBrow.map(t)
        let outerT = outerLips.map(t)
        let innerT = innerLips.map(t)
        let noseT = nose.map(t)
        let contourT = contour.map(t)

        // Eye openness.
        let eyeOpenL = vExtent(leftEyeT)
        let eyeOpenR = vExtent(rightEyeT)

        // Brows: inner point = closest to the midline (x = 0), outer = farthest.
        guard let browInL = leftBrowT.max(by: { $0.x < $1.x }),
              let browOutL = leftBrowT.min(by: { $0.x < $1.x }),
              let browInR = rightBrowT.min(by: { $0.x < $1.x }),
              let browOutR = rightBrowT.max(by: { $0.x < $1.x })
        else { return nil }

        // Mouth.
        guard let cornerL = outerT.min(by: { $0.x < $1.x }),
              let cornerR = outerT.max(by: { $0.x < $1.x })
        else { return nil }
        let mouthCenter = centroid(outerT)
        let mouthWidth = hypot(cornerR.x - cornerL.x, cornerR.y - cornerL.y)

        // Central upper-lip top: highest outer-lip point near the mouth's center column.
        let centralBand = outerT.filter { abs($0.x - mouthCenter.x) < 0.25 * max(0.05, mouthWidth) }
        let upperLipTopY = (centralBand.map(\.y).max() ?? mouthCenter.y)

        // Nose base = lowest nose point; chin = lowest contour point.
        let noseBottomY = noseT.map(\.y).min()
        let chinY = contourT.map(\.y).min()

        var metrics = FacialMetrics(values: [:])
        metrics[.eyeOpenLeft] = eyeOpenL
        metrics[.eyeOpenRight] = eyeOpenR
        metrics[.browInnerLeft] = Double(browInL.y)
        metrics[.browInnerRight] = Double(browInR.y)
        metrics[.browOuterLeft] = Double(browOutL.y)
        metrics[.browOuterRight] = Double(browOutR.y)
        metrics[.browGapX] = Double(browInR.x - browInL.x)
        metrics[.mouthWidth] = Double(mouthWidth)
        metrics[.cornerLiftLeft] = Double(cornerL.y - mouthCenter.y)
        metrics[.cornerLiftRight] = Double(cornerR.y - mouthCenter.y)
        metrics[.outerLipHeight] = vExtent(outerT)
        metrics[.innerLipGap] = innerT.isEmpty ? 0 : vExtent(innerT)
        if let noseBottomY {
            metrics[.philtrum] = Double(noseBottomY - upperLipTopY)
        } else {
            metrics[.philtrum] = FacialMetrics.defaultNeutral[.philtrum]
        }
        if let chinY {
            metrics[.chinDrop] = Double(mouthCenter.y - chinY)
        } else {
            metrics[.chinDrop] = FacialMetrics.defaultNeutral[.chinDrop]
        }

        // Overlay data (normalized, top-left origin for SwiftUI).
        let allImagePoints = [leftEye, rightEye, leftBrow, rightBrow, outerLips, innerLips, nose, contour]
            .flatMap { $0 }
        let uiPoints = allImagePoints.map { p in
            CGPoint(x: p.x / imageSize.width, y: 1 - (p.y / imageSize.height))
        }
        let bb = observation.boundingBox // normalized, bottom-left origin
        let uiRect = CGRect(
            x: bb.origin.x,
            y: 1 - bb.origin.y - bb.size.height,
            width: bb.size.width,
            height: bb.size.height
        )
        let overlay = FaceOverlayData(
            faceRect: uiRect,
            points: uiPoints,
            imageAspect: imageSize.width / imageSize.height
        )

        return Extraction(
            metrics: metrics,
            overlay: overlay,
            landmarkConfidence: Double(landmarks.confidence),
            yaw: observation.yaw?.doubleValue,
            roll: observation.roll?.doubleValue,
            pitch: observation.pitch?.doubleValue
        )
    }

    // MARK: - Small geometry helpers

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sx = points.reduce(0) { $0 + $1.x }
        let sy = points.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(points.count), y: sy / CGFloat(points.count))
    }

    private static func vExtent(_ points: [CGPoint]) -> Double {
        guard let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return 0 }
        return Double(maxY - minY)
    }
}
#endif
