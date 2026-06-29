import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var devices: DeviceManager

    var onStart: (CameraShape, Color, BubbleSize) -> Void

    @State private var selectedCameraId: String = ""
    @State private var selectedMicId: String = ""
    @State private var shape: CameraShape = .circle
    @State private var bubbleSize: BubbleSize = .normal
    @State private var borderColor: Color = .white
    @AppStorage("showClickEffects") private var showClickEffects: Bool = true

    private var canStart: Bool { !devices.selectedSourceTag.isEmpty }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.3)
                ScrollView {
                    VStack(spacing: 20) {
                        sourceSection
                        cameraPreviewSection
                        deviceSection
                        appearanceSection
                    }
                    .padding(24)
                }
                Divider().opacity(0.3)
                startButton
            }
        }
        .frame(width: 450)
        .frame(minHeight: 560)
        .onAppear { syncSelections() }
        .onChange(of: devices.cameras)     { _ in syncSelections() }
        .onChange(of: devices.microphones) { _ in syncSelections() }
    }

    // MARK: - Source picker

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Recording Source", icon: "display")

            if devices.availableDisplays.isEmpty && devices.availableWindows.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Allow screen recording in System Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Picker("", selection: $devices.selectedSourceTag) {
                    if !devices.availableDisplays.isEmpty {
                        Section("Displays") {
                            ForEach(devices.availableDisplays) { d in
                                Label(d.name, systemImage: "display").tag("display:\(d.id)")
                            }
                        }
                    }
                    if !devices.availableWindows.isEmpty {
                        Section("Windows") {
                            ForEach(devices.availableWindows) { w in
                                Label(w.label, systemImage: "macwindow").tag("window:\(w.id)")
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Camera preview

    private var cameraPreviewSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.5))

            if selectedCameraId.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "camera.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No camera selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                CameraPreview(session: devices.previewSession)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(height: 150)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("ScreeMy")
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Spacer()
            Button {
                Task { await devices.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh displays, windows, cameras and microphones")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                label("Camera", icon: "camera.fill")
                Picker("", selection: $selectedCameraId) {
                    Text("Disabled").tag("")
                    ForEach(devices.cameras) { cam in
                        Text(cam.name).tag(cam.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: selectedCameraId) { id in
                    recorder.selectedCameraId = id.isEmpty ? nil : id
                    devices.updatePreview(cameraId: id.isEmpty ? nil : id)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                label("Microphone", icon: "mic.fill")
                Picker("", selection: $selectedMicId) {
                    Text("Disabled").tag("")
                    ForEach(devices.microphones) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: selectedMicId) { id in
                    recorder.selectedMicId = id.isEmpty ? nil : id
                }
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            label("Camera Shape", icon: "square.on.circle")
            Picker("", selection: $shape) {
                ForEach(CameraShape.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            label("Camera Size", icon: "arrow.up.left.and.arrow.down.right")
            Picker("", selection: $bubbleSize) {
                ForEach(BubbleSize.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                label("Click Effects", icon: "cursorarrow.click")
                Spacer()
                Toggle("", isOn: $showClickEffects)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack {
                label("Border Color", icon: "paintpalette.fill")
                Spacer()
                ColorPicker("", selection: $borderColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 36, height: 28)
            }
        }
    }

    private var startButton: some View {
        Button {
            onStart(shape, borderColor, bubbleSize)
        } label: {
            Label("Start Recording", systemImage: "record.circle.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(canStart ? Color.red : Color.gray)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .padding(24)
    }

    // MARK: - Helpers

    private func label(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func syncSelections() {
        if selectedCameraId.isEmpty || !devices.cameras.contains(where: { $0.id == selectedCameraId }) {
            let id = devices.cameras.first?.id ?? ""
            selectedCameraId = id
            recorder.selectedCameraId = id.isEmpty ? nil : id
            devices.updatePreview(cameraId: id.isEmpty ? nil : id)
        }
        if selectedMicId.isEmpty || !devices.microphones.contains(where: { $0.id == selectedMicId }) {
            let id = devices.microphones.first?.id ?? ""
            selectedMicId = id
            recorder.selectedMicId = id.isEmpty ? nil : id
        }
    }
}
