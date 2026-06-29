import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreImage
import CoreMedia
import AppKit

private final class Protected<T> {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    func get() -> T { lock.withLock { _value } }
    func set(_ v: T) { lock.withLock { _value = v } }
}

@MainActor
class ScreenRecorder: NSObject, ObservableObject {
    @Published var isRecording = false

    var selectedCameraId: String?
    var selectedMicId: String?
    weak var bubblePanel: BubblePanel?

    private(set) var tempOutputURL: URL?

    private var stream: SCStream?
    private var captureSession: AVCaptureSession?

    nonisolated(unsafe) private var assetWriter: AVAssetWriter?
    nonisolated(unsafe) private var videoInput:  AVAssetWriterInput?
    nonisolated(unsafe) private var audioInput:  AVAssetWriterInput?
    nonisolated(unsafe) private var adaptor:     AVAssetWriterInputPixelBufferAdaptor?

    private let latestCameraFrame = Protected<CMSampleBuffer?>(nil)
    private let sessionStartTime  = Protected<CMTime?>(nil)
    private let bubblePosition    = Protected<CGPoint>(CGPoint(x: 0.85, y: 0.25))

    private let videoQueue = DispatchQueue(label: "fi.screemy.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "fi.screemy.audio", qos: .userInitiated)
    private let ciContext  = CIContext()
    private var positionTimer: Timer?
    nonisolated(unsafe) var selectedShape: CameraShape = .circle
    nonisolated(unsafe) var selectedBorderColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    nonisolated(unsafe) var selectedBubbleScale: CGFloat = 1.0
    nonisolated(unsafe) weak var laserManager: LaserPointerManager?
    nonisolated(unsafe) weak var clickManager: ClickManager?
    var recordedScreenFrame: CGRect = .zero

    // The capture session that owns the camera during recording.
    // Exposed so AppDelegate can pass it to BubbleView for live preview.
    var recordingCaptureSession: AVCaptureSession? { captureSession }

    // MARK: - Prewarm

    func prewarmCompositor() {
        videoQueue.async { [ciContext] in
            let sz = 64
            let cs = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(data: nil, width: sz, height: sz,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let maskImg = { ctx.setFillColor(gray: 1, alpha: 1)
                                  ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: sz, height: sz))
                                  return ctx.makeImage() }()
            else { return }

            let cam    = CIImage(color: CIColor.black).cropped(to: CGRect(x: 0, y: 0, width: sz, height: sz))
            let screen = CIImage(color: CIColor.gray).cropped(to:  CGRect(x: 0, y: 0, width: sz, height: sz))
            let result = cam.applyingFilter("CIBlendWithMask", parameters: [
                "inputBackgroundImage": screen,
                "inputMaskImage": CIImage(cgImage: maskImg)
            ])
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, sz, sz, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buf = pb else { return }
            ciContext.render(result, to: buf)
            print("[ScreeMy] compositor prewarmed")
        }
    }

    // MARK: - Start

    func start(filter: SCContentFilter, outputURL: URL) async throws {
        guard !isRecording else { return }
        tempOutputURL = outputURL

        let (w, h) = filterDimensions(filter)
        print("[ScreeMy] start: \(w)x\(h)")

        try setupAssetWriter(url: outputURL, width: w, height: h)
        print("[ScreeMy] start: writer ready")

        let session = buildCaptureSession()
        await Task.detached(priority: .userInitiated) {
            session.startRunning()
        }.value
        captureSession = session
        print("[ScreeMy] start: capture session running")

        try await startScreenStream(filter: filter, width: w, height: h)
        print("[ScreeMy] start: stream started")

        isRecording = true
        startPositionTracking()
        print("[ScreeMy] start: recording!")
    }

    // MARK: - Stop

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        positionTimer?.invalidate()
        positionTimer = nil

        if let stream { try? await stream.stopCapture() }
        self.stream = nil

        // Drain in-flight screen frames before marking the input finished
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            videoQueue.async { c.resume() }
        }

        let session = captureSession
        captureSession = nil
        await Task.detached(priority: .userInitiated) {
            session?.stopRunning()
        }.value

        // Drain in-flight audio samples before marking the input finished
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            audioQueue.async { c.resume() }
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        if let writer = assetWriter {
            print("[ScreeMy] finishWriting: status before=\(writer.status.rawValue)")
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                writer.finishWriting { c.resume() }
            }
            let err = writer.error?.localizedDescription ?? "nil"
            print("[ScreeMy] finishWriting: status after=\(writer.status.rawValue) error=\(err)")
            if let url = tempOutputURL {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                print("[ScreeMy] output file size: \(size) bytes at \(url.lastPathComponent)")
            }
        }

        assetWriter = nil
        videoInput  = nil
        audioInput  = nil
        adaptor     = nil
        sessionStartTime.set(nil)
        latestCameraFrame.set(nil)
    }

    // MARK: - Capture session (camera + mic)

    private func buildCaptureSession() -> AVCaptureSession {
        let session = AVCaptureSession()
        session.beginConfiguration()

        if let cam = findDevice(mediaType: .video, uniqueID: selectedCameraId),
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
        }
        let camOut = AVCaptureVideoDataOutput()
        camOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        camOut.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(camOut) { session.addOutput(camOut) }

        if let mic = findDevice(mediaType: .audio, uniqueID: selectedMicId),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
        }
        let micOut = AVCaptureAudioDataOutput()
        micOut.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(micOut) { session.addOutput(micOut) }

        session.commitConfiguration()
        return session
    }


    private func findDevice(mediaType: AVMediaType, uniqueID: String?) -> AVCaptureDevice? {
        if let id = uniqueID {
            let types: [AVCaptureDevice.DeviceType] = mediaType == .video
                ? [.builtInWideAngleCamera, .externalUnknown]
                : [.builtInMicrophone, .externalUnknown]
            if let found = AVCaptureDevice.DiscoverySession(
                deviceTypes: types, mediaType: mediaType, position: .unspecified
            ).devices.first(where: { $0.uniqueID == id }) { return found }
        }
        return AVCaptureDevice.default(for: mediaType)
    }

    // MARK: - Asset writer

    private func filterDimensions(_ filter: SCContentFilter) -> (Int, Int) {
        var w = 1920, h = 1080
        if #available(macOS 14.0, *) {
            let rect  = filter.contentRect
            let scale = CGFloat(filter.pointPixelScale)
            if rect.width > 10 && rect.height > 10 && scale > 0 {
                w = Int(rect.width  * scale)
                h = Int(rect.height * scale)
            }
        }
        return (w & ~1, h & ~1)
    }

    private func setupAssetWriter(url: URL, width: Int, height: Int) throws {
        let writer = try AVAssetWriter(url: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:      12_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        writer.add(vInput)

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey  as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adp = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput,
                                                       sourcePixelBufferAttributes: poolAttrs)

        // sourceFormatHint poistettu — AVCaptureAudioDataOutput voi toimittaa
        // näytteet eri formaatissa kuin laite raportoi, jolloin hint aiheuttaa
        // writerin kaatumisen heti ensimmäisellä näytteellä.
        let audioSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey:   256_000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        writer.add(aInput)

        writer.startWriting()
        assetWriter = writer
        videoInput  = vInput
        audioInput  = aInput
        adaptor     = adp
    }

    // MARK: - Screen stream

    private func startScreenStream(filter: SCContentFilter, width: Int, height: Int) async throws {
        let cfg = SCStreamConfiguration()
        cfg.width  = max(width, 32)
        cfg.height = max(height, 32)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.capturesAudio = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA  // ensure BGRA to match our pipeline

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await s.startCapture()
        stream = s
    }

    // MARK: - Bubble position tracking

    private func startPositionTracking() {
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBubblePosition() }
        }
    }

    private var _posLogCount = 0
    private func updateBubblePosition() {
        guard let panel = bubblePanel else { return }
        let screen = recordedScreenFrame.isEmpty
            ? (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
            : recordedScreenFrame
        let relX = (panel.frame.midX - screen.minX) / screen.width
        let relY = (panel.frame.midY - screen.minY) / screen.height
        let clamped = CGPoint(x: max(0, min(1, relX)), y: max(0, min(1, relY)))
        bubblePosition.set(clamped)
        _posLogCount += 1
        if _posLogCount <= 5 || _posLogCount % 90 == 0 {
            print("[ScreeMy] pos#\(_posLogCount): panel=\(panel.frame) screen=\(screen) relX=\(String(format:"%.3f",relX)) relY=\(String(format:"%.3f",relY)) clamped=\(clamped)")
        }
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreeMy] SCStream error: \(error)")
    }
}

// MARK: - SCStreamOutput

extension ScreenRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                             didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                             of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let writer = assetWriter, writer.status == .writing,
              let vInput = videoInput, vInput.isReadyForMoreMediaData,
              let adaptor = adaptor,
              let screenPB = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStartTime.get() == nil {
            writer.startSession(atSourceTime: pts)
            sessionStartTime.set(pts)
        }

        let fw  = CGFloat(CVPixelBufferGetWidth(screenPB))
        let fh  = CGFloat(CVPixelBufferGetHeight(screenPB))
        let out = composite(screen: screenPB,
                            camera: latestCameraFrame.get(),
                            size: CGSize(width: fw, height: fh),
                            pos: bubblePosition.get())
        var vErr: NSString?
        if !SCMSafeAppendPixelBuffer(adaptor, out, pts, &vErr) {
            if let e = vErr { print("[ScreeMy] video error: \(e)") }
        }
    }

    nonisolated private func composite(screen: CVPixelBuffer,
                                        camera: CMSampleBuffer?,
                                        size: CGSize,
                                        pos: CGPoint) -> CVPixelBuffer {
        let screenCI = CIImage(cvPixelBuffer: screen)

        var resultCI: CIImage
        if let cam = camera, let camPB = CMSampleBufferGetImageBuffer(cam) {
            resultCI = cameraBlend(screenCI: screenCI, camPB: camPB,
                                   frameSize: size, pos: pos, shape: selectedShape)
        } else {
            resultCI = screenCI
        }

        if let laser = laserManager {
            let pts = laser.snapshotPoints()
            if !pts.isEmpty { resultCI = overlayLaser(on: resultCI, points: pts, size: size) }
        }

        if let click = clickManager {
            let evts = click.snapshotEvents()
            if !evts.isEmpty { resultCI = overlayClicks(on: resultCI, events: evts, size: size) }
        }

        var out: CVPixelBuffer?
        if let pool = adaptor?.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        }
        guard let output = out else { return screen }
        ciContext.render(resultCI, to: output)
        return output
    }

    nonisolated private func overlayLaser(on image: CIImage,
                                           points: [(CGPoint, Date)],
                                           size: CGSize) -> CIImage {
        let now = Date()
        let fade = 2.0
        guard let ctx = CGContext(data: nil,
                                   width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        let scale = size.width / 1920.0
        let w = size.width, h = size.height
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for i in 1..<points.count {
            let (p0, t0) = points[i - 1]
            let (p1, t1) = points[i]
            let age = now.timeIntervalSince(t1)
            guard age < fade, t1.timeIntervalSince(t0) < 0.12 else { continue }
            let alpha = CGFloat(1.0 - age / fade)
            let r = (0.95 + 0.55 * alpha) * scale
            let x0 = p0.x * w, y0 = p0.y * h
            let x1 = p1.x * w, y1 = p1.y * h

            ctx.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0, alpha: alpha * 0.35))
            ctx.setLineWidth(r * 2 * 2.2)
            ctx.move(to: CGPoint(x: x0, y: y0)); ctx.addLine(to: CGPoint(x: x1, y: y1))
            ctx.strokePath()

            ctx.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0, alpha: alpha))
            ctx.setLineWidth(r * 2)
            ctx.move(to: CGPoint(x: x0, y: y0)); ctx.addLine(to: CGPoint(x: x1, y: y1))
            ctx.strokePath()
        }

        guard let cgImg = ctx.makeImage() else { return image }
        return CIImage(cgImage: cgImg).applyingFilter("CISourceOverCompositing", parameters: [
            "inputBackgroundImage": image
        ])
    }

    nonisolated private func overlayClicks(on image: CIImage,
                                            events: [ClickEvent],
                                            size: CGSize) -> CIImage {
        let now = Date()
        let animDuration = 0.85
        guard let ctx = CGContext(data: nil,
                                   width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        let scale = size.width / 1920.0
        let radius = 26.0 * scale
        let lineWidth = 4.0 * scale

        for event in events {
            let age = now.timeIntervalSince(event.timestamp)
            guard age >= 0, age < animDuration else { continue }
            let progress = age / animDuration
            let opacity: CGFloat = progress < 0.55
                ? 0.9
                : 0.9 * CGFloat(1.0 - (progress - 0.55) / 0.45)

            let cx = event.point.x * size.width
            let cy = event.point.y * size.height
            let rect = CGRect(x: cx - radius, y: cy - radius,
                              width: radius * 2, height: radius * 2)
            let color: CGColor = event.isRight
                ? CGColor(red: 0.0,  green: 0.478, blue: 1.0, alpha: opacity)
                : CGColor(red: 1.0,  green: 0.8,   blue: 0.0, alpha: opacity)

            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.strokeEllipse(in: rect)
        }

        guard let cgImg = ctx.makeImage() else { return image }
        return CIImage(cgImage: cgImg).applyingFilter("CISourceOverCompositing", parameters: [
            "inputBackgroundImage": image
        ])
    }

    /// Composites the camera onto the screen using the given shape mask.
    /// Using screenCI as inputBackgroundImage avoids transparent/black corners
    /// in the encoded video (H.264 discards alpha).
    nonisolated private func cameraBlend(screenCI: CIImage,
                                          camPB: CVPixelBuffer,
                                          frameSize: CGSize,
                                          pos: CGPoint,
                                          shape: CameraShape) -> CIImage {
        let (camW, camH): (CGFloat, CGFloat)
        switch shape {
        case .circle, .square:
            let s = frameSize.width * 0.18 * selectedBubbleScale
            camW = s; camH = s
        case .portrait:
            let w = frameSize.width * 0.13 * selectedBubbleScale
            camW = w; camH = w * 1.5
        }

        let bX = pos.x * frameSize.width  - camW / 2
        let bY = pos.y * frameSize.height - camH / 2

        var cam   = CIImage(cvPixelBuffer: camPB)
        let scale = max(camW / cam.extent.width, camH / cam.extent.height)
        cam = cam.transformed(by: CGAffineTransform(scaleX: -scale, y: scale))
        cam = cam.cropped(to: CGRect(x: cam.extent.midX - camW/2,
                                     y: cam.extent.midY - camH/2,
                                     width: camW, height: camH))
        cam = cam.transformed(by: CGAffineTransform(
            translationX: bX - cam.extent.minX,
            y:            bY - cam.extent.minY))

        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil,
                                   width:  Int(frameSize.width),
                                   height: Int(frameSize.height),
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let maskImg = {
                  ctx.setFillColor(gray: 1, alpha: 1)
                  let r = CGRect(x: bX, y: bY, width: camW, height: camH)
                  switch shape {
                  case .circle:
                      ctx.fillEllipse(in: r)
                  case .square, .portrait:
                      let cr = camW * 0.15
                      ctx.addPath(CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: nil))
                      ctx.fillPath()
                  }
                  return ctx.makeImage()
              }()
        else { return screenCI }

        let camOnScreen = cam.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": screenCI,
            "inputMaskImage": CIImage(cgImage: maskImg)
        ])

        // Border ring: proportional to camera size (6pt / 220pt panel width)
        let borderWidth = camW * (4.0 / 220.0)
        guard let ringCtx = CGContext(data: nil,
                                       width:  Int(frameSize.width),
                                       height: Int(frameSize.height),
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: cs,
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return camOnScreen
        }
        // White outer ring
        ringCtx.setFillColor(gray: 1, alpha: 1)
        let outerRect = CGRect(x: bX - borderWidth, y: bY - borderWidth,
                               width: camW + 2*borderWidth, height: camH + 2*borderWidth)
        switch shape {
        case .circle:
            ringCtx.fillEllipse(in: outerRect)
        case .square, .portrait:
            let cr = (camW + 2*borderWidth) * 0.15
            ringCtx.addPath(CGPath(roundedRect: outerRect, cornerWidth: cr, cornerHeight: cr, transform: nil))
            ringCtx.fillPath()
        }
        // Cut out camera area (black = transparent in mask)
        ringCtx.setFillColor(gray: 0, alpha: 1)
        switch shape {
        case .circle:
            ringCtx.fillEllipse(in: CGRect(x: bX, y: bY, width: camW, height: camH))
        case .square, .portrait:
            let cr = camW * 0.15
            ringCtx.addPath(CGPath(roundedRect: CGRect(x: bX, y: bY, width: camW, height: camH),
                                   cornerWidth: cr, cornerHeight: cr, transform: nil))
            ringCtx.fillPath()
        }
        guard let ringMask = ringCtx.makeImage() else { return camOnScreen }

        let borderCI = CIImage(color: CIColor(cgColor: selectedBorderColor))
            .cropped(to: CGRect(origin: .zero, size: frameSize))
        return borderCI.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": camOnScreen,
            "inputMaskImage": CIImage(cgImage: ringMask)
        ])
    }
}

// MARK: - AVCapture delegates

extension ScreenRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                    didOutput sampleBuffer: CMSampleBuffer,
                                    from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            latestCameraFrame.set(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput {
            guard let writer = assetWriter, writer.status == .writing,
                  let startTime = sessionStartTime.get(),
                  let aInput = audioInput,
                  aInput.isReadyForMoreMediaData else { return }
            // Skipataan puskurit joiden aika on ennen session alkua —
            // muuten AVAssetWriterInput heittää poikkeuksen ja kaataa sovelluksen.
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard CMTimeCompare(pts, startTime) >= 0 else { return }
            var errDesc: NSString?
            if !SCMSafeAppendSampleBuffer(aInput, sampleBuffer, &errDesc) {
                let exc = errDesc as String? ?? "(no exception)"
                let we  = writer.error?.localizedDescription ?? "nil"
                print("[ScreeMy] audio append failed: \(exc), writerStatus=\(writer.status.rawValue), writerError=\(we)")
            }
        }
    }
}
