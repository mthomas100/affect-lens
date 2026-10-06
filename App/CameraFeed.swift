//
//  CameraFeed.swift
//  AffectLens
//
//  The app's one frame source: the Vision Pro's front (Persona) camera through
//  AVFoundation, or a video file played on a loop in real time (the simulator has no
//  camera). Either way frames arrive on the main actor through `onFrame` and the last
//  one is kept for the preview.
//
//  Capture work never runs on the main actor: AVCaptureSession's start/stop calls
//  block, so they run on the capture queue and only the results hop back.
//

import AVFoundation
import CoreMedia
import SwiftUI

@MainActor
@Observable
final class CameraFeed {
    enum Source: Equatable {
        case camera
        case video(URL)
    }

    enum FeedError: LocalizedError {
        case permissionDenied
        case noCamera
        case cannotConfigure(String)
        case unreadableVideo(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Camera access was denied. Allow it in Settings."
            case .noCamera: return "No front camera is available on this device."
            case .cannotConfigure(let why): return "Could not configure the camera: \(why)"
            case .unreadableVideo(let why): return "Could not read the demo video: \(why)"
            }
        }
    }

    let source: Source
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// The most recent frame, for the preview.
    private(set) var latestPixelBuffer: CVPixelBuffer?

    /// Called on the main actor for every delivered frame.
    @ObservationIgnored var onFrame: (@MainActor (CVPixelBuffer, CMTime) -> Void)?

    @ObservationIgnored private var capture: CaptureSessionBox?
    @ObservationIgnored private var playback: Task<Void, Never>?

    init(source: Source) {
        self.source = source
    }

    var isDemoVideo: Bool {
        if case .video = source { return true }
        return false
    }

    func start() async throws {
        guard !isRunning else { return }
        lastError = nil
        do {
            switch source {
            case .camera:
                try await startCamera()
            case .video(let url):
                try await startVideo(url)
            }
            isRunning = true
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() {
        isRunning = false
        playback?.cancel()
        playback = nil
        capture?.stop()
    }

    private func deliver(_ buffer: CVPixelBuffer, _ time: CMTime) {
        guard isRunning else { return }
        latestPixelBuffer = buffer
        onFrame?(buffer, time)
    }

    // MARK: - Camera

    private func startCamera() async throws {
        guard await Permissions.cameraAccess() else { throw FeedError.permissionDenied }
        let box = capture ?? CaptureSessionBox()
        capture = box
        box.onSample = { [weak self] buffer, time in
            nonisolated(unsafe) let buffer = buffer
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(buffer, time) }
            }
        }
        try await box.start()
    }

    // MARK: - Demo video

    private func startVideo(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw FeedError.unreadableVideo(error.localizedDescription)
        }
        guard let track = tracks.first else { throw FeedError.unreadableVideo("no video track") }

        playback = Task { [weak self] in
            while !Task.isCancelled {
                guard let reader = try? AVAssetReader(asset: asset) else { return }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ])
                reader.add(output)
                guard reader.startReading() else { return }
                let clock = ContinuousClock()
                let loopStart = clock.now
                // Real-time pacing: each frame is shown at its presentation time.
                while !Task.isCancelled, let sample = output.copyNextSampleBuffer() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                    try? await clock.sleep(until: loopStart + .milliseconds(Int(pts.seconds * 1000)))
                    self?.deliver(buffer, pts)
                }
                reader.cancelReading()
            }
        }
    }
}

/// Owns the AVCaptureSession and its delegate. Everything here runs on `queue`.
nonisolated private final class CaptureSessionBox: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                                   @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "AffectLens.CameraFeed.capture")
    private var configured = false
    var onSample: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .front)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
            throw CameraFeed.FeedError.noCamera
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraFeed.FeedError.cannotConfigure(error.localizedDescription)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw CameraFeed.FeedError.cannotConfigure("input rejected") }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraFeed.FeedError.cannotConfigure("output rejected") }
        session.addOutput(output)
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onSample?(buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
