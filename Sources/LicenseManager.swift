import Foundation
import Security

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published var isLicensed = false
    @Published var isChecking = false

    private let service = "fi.screemy.app"
    private let kKey = "license_key"
    private let kInstance = "instance_id"
    private let kValidatedAt = "validated_at"
    private let graceDays: Double = 7

    private init() {}

    // MARK: - Public

    func checkLicense() async {
        guard
            let key = keychainLoad(kKey),
            let instanceId = keychainLoad(kInstance)
        else {
            isLicensed = false
            return
        }

        if let ts = validatedAt(), Date().timeIntervalSince(ts) < graceDays * 86400 {
            isLicensed = true
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            let valid = try await validateOnline(key: key, instanceId: instanceId)
            if valid {
                saveValidatedAt()
                isLicensed = true
            } else {
                clearKeychain()
                isLicensed = false
            }
        } catch {
            // Network failure — keep user licensed (don't punish offline users)
            isLicensed = true
        }
    }

    func activate(licenseKey: String) async throws {
        isChecking = true
        defer { isChecking = false }

        let instanceName = Host.current().localizedName ?? "Mac"
        let instanceId = try await activateOnline(key: licenseKey, instanceName: instanceName)

        keychainSave(kKey, value: licenseKey)
        keychainSave(kInstance, value: instanceId)
        saveValidatedAt()
        isLicensed = true
    }

    // MARK: - LS Licensing API

    private struct ActivateResponse: Decodable {
        let activated: Bool
        let instance: Instance?
        let error: String?
        struct Instance: Decodable { let id: String }
    }

    private struct ValidateResponse: Decodable {
        let valid: Bool
    }

    private func activateOnline(key: String, instanceName: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.lemonsqueezy.com/v1/licenses/activate")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "license_key=\(key)&instance_name=\(instanceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Mac")"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw LicenseError.network
        }

        let decoded = try JSONDecoder().decode(ActivateResponse.self, from: data)

        guard http.statusCode == 200, decoded.activated, let id = decoded.instance?.id else {
            throw LicenseError.invalid(decoded.error ?? "Invalid license key.")
        }

        return id
    }

    private func validateOnline(key: String, instanceId: String) async throws -> Bool {
        var req = URLRequest(url: URL(string: "https://api.lemonsqueezy.com/v1/licenses/validate")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "license_key=\(key)&instance_id=\(instanceId)".data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        let decoded = try JSONDecoder().decode(ValidateResponse.self, from: data)
        return decoded.valid
    }

    // MARK: - Keychain

    private func keychainSave(_ account: String, value: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    private func keychainLoad(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: kCFBooleanTrue!,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var ref: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func validatedAt() -> Date? {
        guard let s = keychainLoad(kValidatedAt), let ts = Double(s) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private func saveValidatedAt() {
        keychainSave(kValidatedAt, value: "\(Date().timeIntervalSince1970)")
    }

    private func clearKeychain() {
        for account in [kKey, kInstance, kValidatedAt] {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

enum LicenseError: LocalizedError {
    case network
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .network: return "Network error. Check your internet connection and try again."
        case .invalid(let msg): return msg
        }
    }
}
