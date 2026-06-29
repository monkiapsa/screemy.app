import Foundation
import AVFoundation
import ScreenCaptureKit

enum CameraShape: String, CaseIterable, Identifiable {
    case circle   = "Circle"
    case square   = "Square"
    case portrait = "Portrait"
    var id: String { rawValue }
}

enum BubbleSize: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case small  = "Small"
    var id: String { rawValue }
    var scale: CGFloat { self == .small ? 0.7 : 1.0 }
}

struct AudioDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct VideoDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct RecordingDisplay: Identifiable, Hashable {
    let display: SCDisplay
    var id: CGDirectDisplayID { display.displayID }
    var name: String {
        display.displayID == CGMainDisplayID() ? "Main Display" : "Display \(display.displayID)"
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RecordingWindow: Identifiable, Hashable {
    let window: SCWindow
    var id: CGWindowID { window.windowID }
    var label: String {
        let app   = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        if title.isEmpty { return app }
        if app.isEmpty  { return title }
        return "\(app) — \(title)"
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
