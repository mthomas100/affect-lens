//
//  MLEmotionScorer.swift
//  AffectLens
//
//  Optional appearance-based expert. If a Core ML facial-expression classifier
//  is present in the app bundle, it scores an expanded face crop and its
//  distribution is fused with the geometric (FACS) expert. The app is fully
//  functional without a model — this returns nil and the engine runs
//  geometry-only.
//

import Foundation
import CoreML
@preconcurrency import CoreVideo
import CoreGraphics

#if os(visionOS) || os(macOS)
@preconcurrency import Vision

/// Runs a bundled Core ML emotion classifier on face crops.
nonisolated final class CoreMLEmotionScorer: @unchecked Sendable {

    /// Compiled-model base names probed in the bundle, in preference order.
    private static let modelNames = ["EmotionAppearance", "FERPlus", "EmotionClassifier", "CNNEmotions"]

    /// FER+ canonical output order — used when the model emits an unlabeled
    /// 8-way score vector instead of labeled classifications.
    private static let ferPlusOrder: [Emotion] = [
        .neutral, .happiness, .surprise, .sadness, .anger, .disgust, .fear, .contempt,
    ]

    private let vnModel: VNCoreMLModel

    init?() {
        var found: VNCoreMLModel?
        for name in Self.modelNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
               let ml = try? MLModel(contentsOf: url),
               let vn = try? VNCoreMLModel(for: ml) {
                found = vn
                break
            }
        }
        guard let found else { return nil }
        vnModel = found
    }

    /// Loads a classifier from an explicit `.mlpackage` / `.mlmodel` / `.mlmodelc` path
    /// (compiling it first when needed). Used by the macOS `affect-replay` tool, which has
    /// no app bundle; `computeUnits` lets batch runs stay on the CPU.
    init?(modelURL: URL, computeUnits: MLComputeUnits = .all) {
        let compiled: URL
        if modelURL.pathExtension == "mlmodelc" {
            compiled = modelURL
        } else if let c = try? MLModel.compileModel(at: modelURL) {
            compiled = c
        } else {
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        guard let ml = try? MLModel(contentsOf: compiled, configuration: config),
              let vn = try? VNCoreMLModel(for: ml) else { return nil }
        vnModel = vn
    }

    /// `faceRect` is the Vision-normalized (bottom-left origin) face box.
    func score(pixelBuffer: CVPixelBuffer, faceRect: CGRect) async -> EmotionDistribution? {
        await withCheckedContinuation { continuation in
            // Safe: the buffer is only read by Vision on the worker queue.
            nonisolated(unsafe) let buffer = pixelBuffer
            DispatchQueue.global(qos: .userInitiated).async { [vnModel] in
                let request = VNCoreMLRequest(model: vnModel)
                request.imageCropAndScaleOption = .centerCrop
                request.regionOfInterest = Self.expandedROI(faceRect, factor: 1.35)
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
                do {
                    try handler.perform([request])
                    continuation.resume(returning: Self.distribution(from: request.results))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Result decoding

    private static func distribution(from results: [VNObservation]?) -> EmotionDistribution? {
        guard let results, !results.isEmpty else { return nil }

        // Path 1: classifier models with embedded labels.
        let classifications = results.compactMap { $0 as? VNClassificationObservation }
        if !classifications.isEmpty {
            var scores = [Emotion: Double]()
            for obs in classifications {
                if let emotion = emotion(fromLabel: obs.identifier) {
                    scores[emotion, default: 0] += Double(obs.confidence)
                }
            }
            guard !scores.isEmpty else { return nil }
            return EmotionDistribution(normalizing: scores)
        }

        // Path 2: raw score vector (e.g. FER+ logits) — assume canonical order.
        if let feature = results.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first,
           let array = feature.featureValue.multiArrayValue {
            let count = array.count
            guard count == ferPlusOrder.count else { return nil }
            var values = [Double]()
            for i in 0..<count { values.append(array[i].doubleValue) }
            let probs = probabilities(from: values)
            var scores = [Emotion: Double]()
            for (i, emotion) in ferPlusOrder.enumerated() { scores[emotion] = probs[i] }
            return EmotionDistribution(normalizing: scores)
        }

        return nil
    }

    private static func emotion(fromLabel label: String) -> Emotion? {
        let l = label.lowercased()
        if l.contains("neutral") { return .neutral }
        if l.contains("happ") || l.contains("joy") || l.contains("smil") { return .happiness }
        if l.contains("sad") { return .sadness }
        if l.contains("surpris") { return .surprise }
        if l.contains("fear") || l.contains("afraid") || l.contains("scared") { return .fear }
        if l.contains("ang") || l.contains("mad") { return .anger }
        if l.contains("disgust") { return .disgust }
        if l.contains("contempt") { return .contempt }
        return nil
    }

    /// Softmax when the vector looks like logits; pass through when it already
    /// looks like a probability distribution.
    private static func probabilities(from values: [Double]) -> [Double] {
        let sum = values.reduce(0, +)
        let looksNormalized = values.allSatisfy { $0 >= -1e-6 && $0 <= 1 + 1e-6 } && abs(sum - 1) < 0.02
        if looksNormalized { return values }
        let maxV = values.max() ?? 0
        let exps = values.map { exp($0 - maxV) }
        let total = exps.reduce(0, +)
        guard total > 0 else { return values.map { _ in 1.0 / Double(values.count) } }
        return exps.map { $0 / total }
    }

    private static func expandedROI(_ rect: CGRect, factor: CGFloat) -> CGRect {
        let cx = rect.midX, cy = rect.midY
        let w = rect.width * factor, h = rect.height * factor
        let expanded = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        return expanded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
#endif
