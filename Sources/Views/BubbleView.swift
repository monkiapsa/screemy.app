import SwiftUI
import AVFoundation
import AppKit

// MARK: - Camera preview (AVCaptureVideoPreviewLayer wrapped in NSViewRepresentable)

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        if let session {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            v.layer = layer
        } else {
            v.layer?.backgroundColor = NSColor.black.cgColor
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let layer = nsView.layer as? AVCaptureVideoPreviewLayer, let session {
            if layer.session !== session { layer.session = session }
        }
    }
}

// MARK: - BubbleView

struct BubbleView: View {
    let previewSession: AVCaptureSession?
    let shape: CameraShape
    let borderColor: Color

    private var clipShape: AnyShape {
        switch shape {
        case .circle:   return AnyShape(Circle())
        case .square:   return AnyShape(RoundedRectangle(cornerRadius: 20))
        case .portrait: return AnyShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    var body: some View {
        CameraPreview(session: previewSession)
            .clipShape(clipShape)
            .overlay(clipShape.stroke(borderColor, lineWidth: 4))
            .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
    }
}

// MARK: - AnyShape helper

struct AnyShape: Shape, @unchecked Sendable {
    private let _path: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { _path = shape.path(in:) }
    func path(in rect: CGRect) -> Path { _path(rect) }
}
