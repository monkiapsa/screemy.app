import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

@MainActor
class DeviceManager: ObservableObject {
    @Published var cameras: [VideoDevice] = []
    @Published var microphones: [AudioDevice] = []
    @Published var availableDisplays: [RecordingDisplay] = []
    @Published var availableWindows: [RecordingWindow] = []
    @Published var selectedSourceTag: String = ""

    let previewSession = AVCaptureSession()
    private var previewDeviceId: String?
    private var selfSCApp: SCRunningApplication?

    func refresh() async {
        await requestPermissions()
        refreshAVDevices()
        await refreshSCContent()
    }

    private func requestPermissions() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .video)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
        // Macquoia (macOS 15) ei triggeraa SC-lupaa automaattisesti — pyydettävä erikseen.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    private func refreshAVDevices() {
        let videoSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        cameras = videoSession.devices.map { VideoDevice(id: $0.uniqueID, name: $0.localizedName) }

        let audioSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        microphones = audioSession.devices.map { AudioDevice(id: $0.uniqueID, name: $0.localizedName) }

        if let first = cameras.first { updatePreview(cameraId: first.id) }
    }

    func refreshSCContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableDisplays = content.displays.map { RecordingDisplay(display: $0) }
            availableWindows = content.windows
                .filter { $0.owningApplication != nil && !($0.title ?? "").isEmpty }
                .map { RecordingWindow(window: $0) }
            selfSCApp = content.applications.first(where: {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            })
            if selectedSourceTag.isEmpty, let first = availableDisplays.first {
                selectedSourceTag = "display:\(first.id)"
            }
        } catch {
            print("[ScreeMy] SCShareableContent: \(error)")
        }
    }

    func targetNSScreen() -> NSScreen? {
        let parts = selectedSourceTag.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "display",
              let id = UInt32(parts[1]),
              let rec = availableDisplays.first(where: { $0.id == id }) else { return nil }
        let displayID = rec.display.displayID

        // Primary: match by CGDirectDisplayID stored in NSScreen.deviceDescription
        if let match = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) { return match }

        // Fallback: match by display bounds (CGDisplayBounds uses same point space as NSScreen.frame,
        // but with y flipped; use center-distance heuristic to find the closest screen)
        let cgBounds = CGDisplayBounds(displayID)
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        let targetCenterX = cgBounds.midX
        let targetCenterY = mainH - cgBounds.midY  // flip to NSScreen coordinate system
        print("[ScreeMy] targetNSScreen fallback: displayID=\(displayID) cgBounds=\(cgBounds)")
        return NSScreen.screens.min(by: {
            let d1 = hypot($0.frame.midX - targetCenterX, $0.frame.midY - targetCenterY)
            let d2 = hypot($1.frame.midX - targetCenterX, $1.frame.midY - targetCenterY)
            return d1 < d2
        })
    }

    func buildContentFilter() -> SCContentFilter? {
        let parts = selectedSourceTag.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let kind = parts[0], idStr = parts[1]

        if kind == "display", let id = UInt32(idStr),
           let rec = availableDisplays.first(where: { $0.id == id }) {
            let excluded = selfSCApp.map { [$0] } ?? []
            return SCContentFilter(display: rec.display,
                                   excludingApplications: excluded, exceptingWindows: [])
        }
        if kind == "window", let id = UInt32(idStr),
           let rec = availableWindows.first(where: { $0.id == id }) {
            return SCContentFilter(desktopIndependentWindow: rec.window)
        }
        return nil
    }

    func updatePreview(cameraId: String?) {
        guard cameraId != previewDeviceId else { return }
        previewDeviceId = cameraId

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.previewSession.stopRunning()
            self.previewSession.beginConfiguration()
            self.previewSession.inputs.forEach { self.previewSession.removeInput($0) }

            if let id = cameraId {
                let discovered = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
                    mediaType: .video, position: .unspecified
                ).devices.first(where: { $0.uniqueID == id })

                if let device = discovered,
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.previewSession.canAddInput(input) {
                    self.previewSession.addInput(input)
                }
            }

            self.previewSession.commitConfiguration()
            self.previewSession.startRunning()
        }
    }

    func stopPreview() async {
        let session = previewSession
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
                cont.resume()
            }
        }
    }

    func startPreview() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if self?.previewSession.isRunning == false {
                self?.previewSession.startRunning()
            }
        }
    }
}
