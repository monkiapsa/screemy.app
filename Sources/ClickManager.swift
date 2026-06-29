import AppKit
import QuartzCore

struct ClickEvent {
    let point: CGPoint  // relative coords (0..1, 0..1) within screenFrame
    let timestamp: Date
    let isRight: Bool
}

final class ClickManager {
    let animDuration: TimeInterval = 0.85
    private(set) var screenFrame: CGRect

    // Called on main thread when a click is recorded; receives relative coords (0..1)
    var onUpdate: ((CGPoint, Bool) -> Void)?

    private let lock = NSLock()
    private var events: [ClickEvent] = []
    private var globalMonitor: Any?

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.addClick(at: NSEvent.mouseLocation, isRight: event.type == .rightMouseDown)
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        lock.withLock { events.removeAll() }
    }

    func snapshotEvents() -> [ClickEvent] {
        lock.withLock {
            let cutoff = Date(timeIntervalSinceNow: -animDuration)
            events.removeAll { $0.timestamp < cutoff }
            return events
        }
    }

    private func addClick(at loc: NSPoint, isRight: Bool) {
        guard !screenFrame.isEmpty else { return }
        let relX = (loc.x - screenFrame.minX) / screenFrame.width
        let relY = (loc.y - screenFrame.minY) / screenFrame.height
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return }
        lock.withLock {
            events.append(ClickEvent(
                point: CGPoint(x: relX, y: relY),
                timestamp: Date(),
                isRight: isRight))
        }
        onUpdate?(CGPoint(x: relX, y: relY), isRight)
    }
}

// MARK: - Live overlay view

final class ClickOverlayView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { nil }

    func showPulse(at point: CGPoint, isRight: Bool) {
        let ring = CAShapeLayer()
        let radius: CGFloat = 26
        ring.path = CGPath(ellipseIn: CGRect(
            x: point.x - radius, y: point.y - radius,
            width: radius * 2, height: radius * 2
        ), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = isRight
            ? NSColor.systemBlue.cgColor
            : NSColor.systemYellow.cgColor
        ring.lineWidth = 4
        ring.opacity = 0.9
        layer?.addSublayer(ring)

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values    = [0.9, 0.9, 0.0]
        anim.keyTimes  = [0, 0.55, 1.0]
        anim.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeIn)
        ]
        anim.duration             = 0.85
        anim.fillMode             = .forwards
        anim.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(anim, forKey: "pulse")
        CATransaction.commit()
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
