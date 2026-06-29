import SwiftUI

struct LicenseView: View {
    var onActivated: () -> Void

    @State private var keyInput = ""
    @State private var errorMessage: String?
    @State private var isActivating = false

    private var trimmedKey: String { keyInput.trimmingCharacters(in: .whitespaces) }
    private var canActivate: Bool { !trimmedKey.isEmpty && !isActivating }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)

                VStack(spacing: 8) {
                    Text("Activate ScreeMy")
                        .font(.title2.bold())
                    Text("Enter your license key to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    TextField("XXXX-XXXX-XXXX-XXXX", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .onSubmit { activateKey() }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: activateKey) {
                        Group {
                            if isActivating {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Activate License")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(canActivate ? Color.accentColor : Color.gray.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canActivate)
                }

                Button("Buy a license →") {
                    if let url = URL(string: "https://screemy.lemonsqueezy.com/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
            .padding(40)
            .frame(width: 380)
        }
    }

    private func activateKey() {
        guard canActivate else { return }
        isActivating = true
        errorMessage = nil
        Task { @MainActor in
            defer { isActivating = false }
            do {
                try await LicenseManager.shared.activate(licenseKey: trimmedKey)
                onActivated()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
