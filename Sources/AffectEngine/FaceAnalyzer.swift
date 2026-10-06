//
//  FaceAnalyzer.swift
//  AffectLens
//
//  Off-main-actor Vision work: runs face landmark detection on a frame and
//  reduces it to a Sendable `FrameAnalysis` value for the emotion engine.
//

import Foundation
import CoreVideo
import CoreGraphics

#if os(visionOS) || os(macOS)
import Vision

nonisolated struct FrameAnalysis: Sendable {
    var extraction: FaceGeometry.Extraction?
    var imageSize: CGSize

    // MARK: Fan-out payload for windowed channel analyzers (US-B5a)
    //
    // Future windowed channels (eyes/blink, windowed head-pose) piggyback on the
    // face pipeline's per-frame ANALYSIS — there is no pixel-level distributor
    // (PRD v2 §7.1 / §7.3). These fields promote the cross-channel primitives to
    // the top level so a consumer never has to reach into the face-pipeline's
    // `FaceGeometry.Extraction`. All are snapshot-once and purely ADDITIVE:
    // `extraction` and `imageSize` are unchanged.

    /// When this frame was analyzed (stamped in `FaceAnalyzer.analyze`).
    var date: Date
    /// True when Vision detected a face this frame — the presence/absence signal
    /// blink & attention analyzers need. Broader than "usable geometry": it can be
    /// `true` while `extraction == nil` (a face turned too far to extract
    /// landmarks). Consumers that need measurable geometry should test
    /// `extraction != nil` (equivalently `eyeOpenLeft != nil`).
    var facePresent: Bool
    /// Palpebral-fissure height (eye openness), IOD-normalized & roll-corrected —
    /// visual-left / visual-right. `nil` when there is no usable face geometry.
    var eyeOpenLeft: Double?
    var eyeOpenRight: Double?
    /// Head pose in radians (Vision convention); `nil` when unavailable.
    var yaw: Double?
    var roll: Double?
    var pitch: Double?

    /// A no-face analysis at `date`: `facePresent == false`, no geometry. Downstream
    /// channels still receive this — absence is a signal, not a dropped frame.
    static func absent(at date: Date, imageSize: CGSize) -> FrameAnalysis {
        FrameAnalysis(extraction: nil, imageSize: imageSize, date: date,
                      facePresent: false, eyeOpenLeft: nil, eyeOpenRight: nil,
                      yaw: nil, roll: nil, pitch: nil)
    }
}

/// Serializes Vision requests on its own executor so landmark detection never
/// blocks the main actor.
actor FaceAnalyzer {

    private let landmarksRequest = VNDetectFaceLandmarksRequest()

    /// The simulator cannot create Vision's GPU / Neural Engine inference context
    /// ("Could not create inference context"), so it gets the CPU path.
    #if targetEnvironment(simulator)
    static let defaultCPUOnly = true
    #else
    static let defaultCPUOnly = false
    #endif

    /// `cpuOnly` pins every Vision stage to the CPU. On device the app leaves it off; the
    /// macOS `affect-replay` tool turns it on so batch runs stay off the GPU and Neural
    /// Engine (other jobs on the same Mac may own them).
    init(cpuOnly: Bool = FaceAnalyzer.defaultCPUOnly) {
        guard cpuOnly, let stages = try? landmarksRequest.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                try? landmarksRequest.setComputeDevice(cpu, for: stage)
            }
        }
    }

    func analyze(_ pixelBuffer: CVPixelBuffer) -> FrameAnalysis {
        let date = Date()
        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([landmarksRequest])
        } catch {
            return .absent(at: date, imageSize: size)
        }

        // Track the largest detected face (the user's Persona fills the frame).
        let face = (landmarksRequest.results ?? []).max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }
        guard let face else {
            return .absent(at: date, imageSize: size)
        }

        // A face was detected. `extract` may still return nil when the landmark set
        // is too sparse to measure — `facePresent` stays true (the face is there)
        // while the geometry-derived fields degrade to nil. The engine reads only
        // `extraction`, exactly as before; the rest is the additive fan-out payload.
        var extraction = FaceGeometry.extract(from: face, imageSize: size)
        #if targetEnvironment(simulator)
        // The simulator's CPU landmark model reports a landmark confidence of exactly 0 on
        // most frames even when the points track the face, which would gate every frame
        // out. Fall back to the detector's face confidence there; devices are unchanged.
        if extraction?.landmarkConfidence == 0 {
            extraction?.landmarkConfidence = Double(face.confidence)
        }
        #endif
        return FrameAnalysis(
            extraction: extraction,
            imageSize: size,
            date: date,
            facePresent: true,
            eyeOpenLeft: extraction.map { $0.metrics[.eyeOpenLeft] },
            eyeOpenRight: extraction.map { $0.metrics[.eyeOpenRight] },
            yaw: extraction?.yaw,
            roll: extraction?.roll,
            pitch: extraction?.pitch
        )
    }
}
#endif
