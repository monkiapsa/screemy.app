import SwiftUI
import AppKit
import ScreenCaptureKit
import Darwin

// MARK: - BubblePanel

// Handles drag at the AppKit event level so SwiftUI gestures never conflict
// with the stop button. Strategy: pass mouseDown through (button can start
// tracking), consume mouseDragged + mouseUp once drag threshold is crossed
// so the button's action never fires during a drag.
final class BubblePanel: NSPanel {
    private var dragStartLocation: NSPoint?
    private var panelOriginAtDragStart: NSPoint?
    private var isDragging = false
    private let dragThreshold: CGFloat = 3
    private var eventMonitor: Any?

    func startDragMonitoring() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, event.window === self else { return event }
            return self.handle(event)
        }
    }

    override func close() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        super.close()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            dragStartLocation = NSEvent.mouseLocation
            panelOriginAtDragStart = frame.origin
            isDragging = false
            return event  // pass through so button can receive it

        case .leftMouseDragged:
            guard let start = dragStartLocation, let origin = panelOriginAtDragStart else { return event }
            let cur = NSEvent.mouseLocation
            if hypot(cur.x - start.x, cur.y - start.y) >= dragThreshold {
                isDragging = true
                setFrameOrigin(NSPoint(x: origin.x + cur.x - start.x,
                                       y: origin.y + cur.y - start.y))
                return nil  // consume: button never sees drag events
            }
            return event

        case .leftMouseUp:
            let wasDragging = isDragging
            dragStartLocation = nil
            panelOriginAtDragStart = nil
            isDragging = false
            return wasDragging ? nil : event  // suppress mouseUp after drag

        default:
            return event
        }
    }
}

@main
struct ScreeMyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var dashboardWindow: NSWindow?
    private var licenseWindow: NSWindow?
    private var bubblePanel: BubblePanel?
    private var statusItem: NSStatusItem?
    private var laserManager: LaserPointerManager?
    private var laserOverlayPanel: NSPanel?
    private var clickManager: ClickManager?
    private var clickOverlayPanel: NSPanel?

    let recorder = ScreenRecorder()
    let devices  = DeviceManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSSetUncaughtExceptionHandler { exception in
            let msg = "EXCEPTION: \(exception.name.rawValue)\nReason: \(exception.reason ?? "?")\n\(exception.callStackSymbols.joined(separator: "\n"))"
            try? msg.write(toFile: "/tmp/screemy_crash.txt", atomically: true, encoding: .utf8)
        }

        signal(SIGTERM) { _ in print("[ScreeMy] SIGTERM received"); fflush(stdout) }
        signal(SIGINT)  { _ in print("[ScreeMy] SIGINT received");  fflush(stdout) }
        atexit          {      print("[ScreeMy] atexit");            fflush(stdout) }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { _ in
            print("[ScreeMy] applicationWillTerminate")
        }

        NSApp.setActivationPolicy(.regular)
        recorder.prewarmCompositor()
        Task { await devices.refresh() }
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)

        Task { @MainActor in
            await LicenseManager.shared.checkLicense()
            if LicenseManager.shared.isLicensed {
                showDashboard()
            } else {
                showLicenseWindow()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func appDidBecomeActive() {
        guard !recorder.isRecording else { return }
        Task { await devices.refreshSCContent() }
    }

    // MARK: License window

    func showLicenseWindow() {
        if licenseWindow == nil {
            let view = LicenseView {
                self.licenseWindow?.close()
                self.licenseWindow = nil
                self.showDashboard()
            }
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.center()
            w.title = ""
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = .clear
            w.isOpaque = false
            w.titlebarAppearsTransparent = true
            w.contentView = NSHostingView(rootView: view)
            licenseWindow = w
        }
        licenseWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Dashboard

    func showDashboard() {
        if dashboardWindow == nil {
            let view = DashboardView(recorder: recorder, devices: devices, onStart: startRecording)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 720),
                styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.center()
            w.title = ""
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = .clear
            w.isOpaque = false
            w.titlebarAppearsTransparent = true
            w.minSize = NSSize(width: 450, height: 560)
            w.maxSize = NSSize(width: 450, height: 10000)
            w.contentView = NSHostingView(rootView: view)
            dashboardWindow = w
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Recording flow

    func startRecording(shape: CameraShape, color: Color, bubbleSize: BubbleSize) {
        guard let filter = devices.buildContentFilter() else {
            showError("Please select a recording source (display or window) first.")
            return
        }
        Task { @MainActor in
            do {
                let url = tempURL()
                await devices.stopPreview()
                recorder.selectedShape = shape
                recorder.selectedBorderColor = (NSColor(color).usingColorSpace(.deviceRGB) ?? .white).cgColor
                recorder.selectedBubbleScale = bubbleSize.scale
                let targetScreen = devices.targetNSScreen()
                let recFrame = targetScreen?.frame ?? NSScreen.main?.frame ?? .zero
                recorder.recordedScreenFrame = recFrame
                print("[ScreeMy] screens:")
                for s in NSScreen.screens {
                    let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                    print("  NSScreen id=\(num) frame=\(s.frame) visible=\(s.visibleFrame) main=\(s == NSScreen.main)")
                }
                print("[ScreeMy] selectedSourceTag=\(devices.selectedSourceTag)")
                print("[ScreeMy] targetNSScreen=\(String(describing: targetScreen?.frame))")
                print("[ScreeMy] recordedScreenFrame=\(recFrame)")
                try await recorder.start(filter: filter, outputURL: url)
                dashboardWindow?.orderOut(nil)
                showBubble(shape: shape, color: color, bubbleSize: bubbleSize,
                           captureSession: recorder.recordingCaptureSession)
            } catch {
                print("[ScreeMy] start error: \(error)")
                devices.startPreview()
                showDashboard()
                showError("Recording failed:\n\(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        guard recorder.isRecording else { return }
        Task {
            await recorder.stop()

            guard let tempURL = recorder.tempOutputURL else {
                finishRecording()
                return
            }

            // Show dashboard first so the save panel has a visible parent window
            showDashboard()
            guard let window = dashboardWindow else {
                try? FileManager.default.removeItem(at: tempURL)
                finishRecording()
                return
            }

            let panel = NSSavePanel()
            panel.title = "Save Recording"
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "ScreeMy-\(formattedDate()).mp4"

            let response = await panel.beginSheetModal(for: window)
            if response == .OK, let dest = panel.url {
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                } catch {
                    print("[ScreeMy] save error: \(error)")
                    showError("Failed to save file:\n\(error.localizedDescription)")
                }
            } else {
                try? FileManager.default.removeItem(at: tempURL)
            }
            finishRecording()
        }
    }

    private func finishRecording() {
        stopClickManager()
        stopLaserPointer()
        bubblePanel?.close()
        bubblePanel = nil
        recorder.bubblePanel = nil
        updateStatusItem(recording: false)
        devices.startPreview()
        showDashboard()
    }

    // MARK: Status item (permanent)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle",
                                     accessibilityDescription: "ScreeMy")
        item.button?.image?.isTemplate = true
        statusItem = item
        updateStatusItem(recording: false)
    }

    private func updateStatusItem(recording: Bool) {
        guard let item = statusItem, let button = item.button else { return }

        if recording {
            let img = NSImage(systemSymbolName: "record.circle.fill",
                              accessibilityDescription: "ScreeMy is recording")
            img?.isTemplate = false
            button.image = img
            button.contentTintColor = .red
        } else {
            let img = NSImage(systemSymbolName: "record.circle",
                              accessibilityDescription: "ScreeMy")
            img?.isTemplate = true
            button.image = img
            button.contentTintColor = nil
        }

        let menu = NSMenu()
        if recording {
            let info = NSMenuItem(title: "Recording…", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            menu.addItem(.separator())
            let stop = NSMenuItem(title: "Stop Recording",
                                  action: #selector(stopRecordingFromStatusItem),
                                  keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        } else {
            let open = NSMenuItem(title: "Open ScreeMy",
                                  action: #selector(openDashboardFromStatusItem),
                                  keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ScreeMy",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func stopRecordingFromStatusItem() { stopRecording() }

    @objc private func openDashboardFromStatusItem() {
        showDashboard()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Bubble panel

    private func showBubble(shape: CameraShape, color: Color, bubbleSize: BubbleSize,
                            captureSession: AVCaptureSession?) {
        print("[ScreeMy] bubble: sizing")
        let scale = bubbleSize.scale
        let size: NSSize
        switch shape {
        case .circle:   size = NSSize(width: 220 * scale, height: 220 * scale)
        case .square:   size = NSSize(width: 250 * scale, height: 250 * scale)
        case .portrait: size = NSSize(width: 200 * scale, height: 300 * scale)
        }

        let screen = devices.targetNSScreen() ?? NSScreen.main ?? NSScreen.screens.first!
        let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 40,
                             y: screen.visibleFrame.minY + 100)

        print("[ScreeMy] bubble: creating panel")
        let panel = BubblePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        print("[ScreeMy] bubble: creating view (captureSession=\(captureSession != nil))")
        let view = BubbleView(
            previewSession: captureSession,
            shape: shape,
            borderColor: color
        )
        print("[ScreeMy] bubble: NSHostingView")
        panel.contentView = NSHostingView(rootView: view)
        print("[ScreeMy] bubble: makeKeyAndOrderFront")
        panel.makeKeyAndOrderFront(nil)
        panel.startDragMonitoring()
        updateStatusItem(recording: true)
        startClickManager(screenFrame: recorder.recordedScreenFrame)
        startLaserPointer(screenFrame: recorder.recordedScreenFrame)
        print("[ScreeMy] bubble: done")
        bubblePanel = panel
        recorder.bubblePanel = panel
    }

    // MARK: Click manager

    private func startClickManager(screenFrame: CGRect) {
        guard !screenFrame.isEmpty else { return }
        guard UserDefaults.standard.object(forKey: "showClickEffects") as? Bool ?? true else { return }

        let mgr = ClickManager(screenFrame: screenFrame)
        recorder.clickManager = mgr

        let overlayView = ClickOverlayView(frame: screenFrame)
        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = overlayView
        panel.orderFront(nil)
        clickOverlayPanel = panel

        mgr.onUpdate = { [weak overlayView, weak panel] relPoint, isRight in
            guard let overlayView, let panel else { return }
            let local = CGPoint(x: relPoint.x * panel.frame.width,
                                y: relPoint.y * panel.frame.height)
            overlayView.showPulse(at: local, isRight: isRight)
        }

        mgr.start()
        clickManager = mgr
    }

    private func stopClickManager() {
        clickManager?.stop()
        clickManager = nil
        recorder.clickManager = nil
        clickOverlayPanel?.close()
        clickOverlayPanel = nil
    }

    // MARK: Laser pointer

    private func startLaserPointer(screenFrame: CGRect) {
        guard !screenFrame.isEmpty else { return }

        let mgr = LaserPointerManager(screenFrame: screenFrame)
        recorder.laserManager = mgr

        let overlayView = LaserOverlayView(frame: .zero)
        overlayView.manager = mgr
        mgr.onUpdate = { [weak overlayView] in
            overlayView?.setNeedsDisplay(overlayView?.bounds ?? .zero)
        }
        mgr.start()

        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = overlayView
        panel.orderFront(nil)

        laserManager = mgr
        laserOverlayPanel = panel
        print("[ScreeMy] laser pointer active (⌥ + mouse to draw)")
    }

    private func stopLaserPointer() {
        recorder.laserManager = nil
        laserManager?.stop()
        laserManager = nil
        laserOverlayPanel?.close()
        laserOverlayPanel = nil
    }

    // MARK: Helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("screemy_\(Date().timeIntervalSince1970).mp4")
    }

    private func formattedDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }

    private func showError(_ msg: String) {
        let a = NSAlert()
        a.messageText = "ScreeMy"
        a.informativeText = msg
        a.runModal()
    }
}
