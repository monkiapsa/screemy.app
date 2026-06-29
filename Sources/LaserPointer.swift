import Foundation
import AppKit

final class LaserPointerManager {
    let fadeDuration: TimeInterval = 2.0
    private(set) var screenFrame: CGRect

    private let lock = NSLock()
    private var points: [(CGPoint, Date)] = []

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var cleanupTimer: Timer?

    var onUpdate: (() -> Void)?

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged,
                                           .rightMouseDragged, .otherMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard event.modifierFlags.contains(.option) else { return }
            self?.addPoint(at: NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.modifierFlags.contains(.option) { self?.addPoint(at: NSEvent.mouseLocation) }
            return event
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.prune()
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        cleanupTimer?.invalidate(); cleanupTimer = nil
        lock.withLock { points.removeAll() }
    }

    func snapshotPoints() -> [(CGPoint, Date)] {
        lock.withLock { points }
    }

    private func addPoint(at loc: NSPoint) {
        guard !screenFrame.isEmpty else { return }
        let relX = (loc.x - screenFrame.minX) / screenFrame.width
        let relY = (loc.y - screenFrame.minY) / screenFrame.height
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return }
        lock.withLock { points.append((CGPoint(x: relX, y: relY), Date())) }
        onUpdate?()
    }

    private func prune() {
        let cutoff = Date(timeIntervalSinceNow: -fadeDuration)
        var changed = false
        lock.withLock {
            let before = points.count
            points.removeAll { $0.1 < cutoff }
            changed = points.count != before
        }
        if changed { onUpdate?() }
    }
}

// MARK: - Screen overlay

final class LaserOverlayView: NSView {
    weak var manager: LaserPointerManager?
    private var redrawTimer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            redrawTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.setNeedsDisplay(self.bounds)
            }
        } else {
            redrawTimer?.invalidate()
            redrawTimer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let mgr = manager else { return }
        let pts = mgr.snapshotPoints()
        guard !pts.isEmpty else { return }

        let now = Date()
        let fade = mgr.fadeDuration
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let w = bounds.width
        let h = bounds.height
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for i in 1..<pts.count {
            let (p0, t0) = pts[i - 1]
            let (p1, t1) = pts[i]
            let age = now.timeIntervalSince(t1)
            guard age < fade, t1.timeIntervalSince(t0) < 0.12 else { continue }
            let alpha = CGFloat(1.0 - age / fade)
            let r = 0.95 + 0.55 * alpha
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
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
