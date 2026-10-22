import Foundation

// MARK: - Ring API Client

public actor RingClient {
    public static let shared = RingClient()

    // MARK: - API URLs

    private enum API {
        static let oauthToken = URL(string: "https://oauth.ring.com/oauth/token")!
        static let clientsAPI = "https://api.ring.com/clients_api/"
    }

    private static let userAgent = "android:com.ringapp"

    // MARK: - State

    private var credentials: StoredSession?
    private var refreshTask: Task<String, Error>?
    private var pendingEmail: String?
    private var pendingPassword: String?  // Kept only between login and 2FA submission
    private let keychain = KeychainManager.shared
    private let session: URLSession

    // MARK: - Init

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Authentication

    /// Attempt to restore session from the stored refresh token
    public func restoreSession() async throws -> Bool {
        guard try await loadCredentials().refreshToken != nil else { return false }
        do {
            _ = try await refreshAccessToken()
            return true
        } catch {
            ringLog.notice("🔑 Session restore failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Login with email and password. Throws `RingAuthError.requiresTwoFactor`
    /// when Ring sends a verification code; finish with `submitTwoFactorCode`.
    public func login(email: String, password: String) async throws {
        pendingEmail = email
        pendingPassword = password
        do {
            let response = try await authenticate(grant: .password(email: email, password: password))
            try await storeTokens(response)
            clearPendingLogin()
        } catch RingAuthError.requiresTwoFactor(let prompt) {
            throw RingAuthError.requiresTwoFactor(prompt: prompt)
        } catch {
            clearPendingLogin()
            throw error
        }
    }

    /// Submit 2FA code (Ring requires the password again alongside the code)
    public func submitTwoFactorCode(_ code: String) async throws {
        guard let email = pendingEmail, let password = pendingPassword else {
            throw RingAuthError.notLoggedIn
        }
        let response = try await authenticate(
            grant: .password(email: email, password: password),
            twoFactorCode: code
        )
        try await storeTokens(response)
        clearPendingLogin()
    }

    /// Logout and clear tokens (the hardware ID is kept)
    public func logout() async throws {
        var stored = try await loadCredentials()
        stored.refreshToken = nil
        stored.accessToken = nil
        stored.accessTokenExpiry = nil
        try await saveCredentials(stored)
        clearPendingLogin()
    }

    private func clearPendingLogin() {
        pendingEmail = nil
        pendingPassword = nil
    }

    // MARK: - Credentials

    private func loadCredentials() async throws -> StoredSession {
        if let credentials { return credentials }
        let loaded = try await keychain.load()
        credentials = loaded
        return loaded
    }

    private func saveCredentials(_ stored: StoredSession) async throws {
        credentials = stored
        try await keychain.save(stored)
    }

    private func hardwareId() async throws -> String {
        try await loadCredentials().hardwareId
    }

    private func storeTokens(_ response: AuthTokenResponse) async throws {
        var stored = try await loadCredentials()
        stored.refreshToken = response.refreshToken
        stored.accessToken = response.accessToken
        stored.accessTokenExpiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        try await saveCredentials(stored)
    }

    private func validAccessToken() async throws -> String {
        let stored = try await loadCredentials()
        if let token = stored.accessToken,
           let expiry = stored.accessTokenExpiry,
           expiry > Date().addingTimeInterval(60) {
            return token
        }
        return try await refreshAccessToken()
    }

    /// Refreshes the access token. Concurrent callers share a single request,
    /// so an expired token doesn't trigger several refreshes at once.
    private func refreshAccessToken() async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task<String, Error> {
            guard let refreshToken = try await loadCredentials().refreshToken else {
                throw RingAPIError.unauthorized
            }
            do {
                let response = try await authenticate(grant: .refreshToken(refreshToken))
                try await storeTokens(response)
                return response.accessToken
            } catch RingAuthError.invalidCredentials {
                throw RingAPIError.unauthorized
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    // MARK: - Auth Request

    private enum Grant {
        case password(email: String, password: String)
        case refreshToken(String)
    }

    private func authenticate(grant: Grant, twoFactorCode: String? = nil) async throws -> AuthTokenResponse {
        var body = [
            "client_id": "ring_official_android",
            "scope": "client"
        ]
        switch grant {
        case .password(let email, let password):
            body["grant_type"] = "password"
            body["username"] = email
            body["password"] = password
        case .refreshToken(let token):
            body["grant_type"] = "refresh_token"
            body["refresh_token"] = token
        }

        var request = URLRequest(url: API.oauthToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "2fa-support")
        request.setValue(twoFactorCode ?? "", forHTTPHeaderField: "2fa-code")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(try await hardwareId(), forHTTPHeaderField: "hardware_id")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RingAuthError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(AuthTokenResponse.self, from: data)
        case 400:
            if let errorResponse = try? JSONDecoder().decode(Auth2FAResponse.self, from: data),
               errorResponse.error?.contains("Verification Code") == true {
                throw RingAuthError.invalidTwoFactorCode
            }
            throw RingAuthError.invalidCredentials
        case 412:
            let info = try? JSONDecoder().decode(Auth2FAResponse.self, from: data)
            if let state = info?.tsvState, let phone = info?.phone {
                throw RingAuthError.requiresTwoFactor(prompt: "Enter the code sent to \(phone) via \(state)")
            }
            throw RingAuthError.requiresTwoFactor(prompt: "Enter the verification code sent to your phone or email")
        case 401:
            throw RingAuthError.invalidCredentials
        case 429:
            throw RingAuthError.rateLimited
        default:
            throw RingAuthError.networkError
        }
    }

    // MARK: - API Requests

    private func authorizedRequest(url: URL, method: String = "GET", accept: String = "application/json") async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(try await hardwareId(), forHTTPHeaderField: "hardware_id")
        return request
    }

    /// Performs an authorized request. On a 401 it refreshes the token once and
    /// retries, so an access token revoked early doesn't force a re-login.
    private func send(_ path: String, method: String = "GET") async throws -> Data {
        let url = URL(string: API.clientsAPI + path)!
        var retried = false
        while true {
            let request = try await authorizedRequest(url: url, method: method)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw RingAPIError.networkError
            }
            switch httpResponse.statusCode {
            case 200...299:
                return data
            case 401 where !retried:
                retried = true
                var stored = try await loadCredentials()
                stored.accessToken = nil
                credentials = stored
                _ = try await refreshAccessToken()
            case 401:
                throw RingAPIError.unauthorized
            case 404:
                throw RingAPIError.notFound
            case 429:
                throw RingAPIError.rateLimited
            default:
                throw RingAPIError.serverError(httpResponse.statusCode)
            }
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(path))
    }

    // MARK: - Devices

    public func fetchDevices() async throws -> [RingDevice] {
        let response: DevicesResponse = try await get("ring_devices")
        return response.allDevices
    }

    // MARK: - Device Controls

    /// Toggle the floodlight on a device (for devices with floodlights)
    public func setFloodlight(deviceId: Int, enabled: Bool) async throws {
        let endpoint = enabled ? "floodlight_light_on" : "floodlight_light_off"
        _ = try await send("doorbots/\(deviceId)/\(endpoint)", method: "PUT")
    }

    /// Activate or deactivate the siren on a device
    public func setSiren(deviceId: Int, enabled: Bool) async throws {
        let endpoint = enabled ? "siren_on" : "siren_off"
        _ = try await send("doorbots/\(deviceId)/\(endpoint)", method: "PUT")
    }

    // MARK: - Events

    /// Recent events across the given devices, newest first. Chimes are skipped
    /// (they have no history) and devices are fetched concurrently.
    public func fetchRecentEvents(for devices: [RingDevice], limit: Int = 20) async -> [RingEvent] {
        let cameraIds = devices.filter { $0.deviceType != .chime }.map(\.id)
        let events = await withTaskGroup(of: [RingEvent].self) { group in
            for id in cameraIds {
                group.addTask {
                    do {
                        return try await self.get("doorbots/\(id)/history?limit=\(limit)")
                    } catch {
                        ringLog.error("⚠️ Failed to fetch events for device \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return []
                    }
                }
            }
            var all: [RingEvent] = []
            for await batch in group {
                all += batch
            }
            return all
        }
        return events.sorted { $0.createdAt > $1.createdAt }
    }

    /// Downloads an event's recording to a temporary file and returns its URL.
    public func getEventVideoURL(eventId: String) async throws -> URL {
        let url = URL(string: API.clientsAPI + "dings/\(eventId)/recording")!
        let request = try await authorizedRequest(url: url, accept: "video/mp4")
        let (downloaded, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RingAPIError.networkError
        }
        switch httpResponse.statusCode {
        case 200: break
        case 401: throw RingAPIError.unauthorized
        case 404: throw RingAPIError.recordingNotFound
        default: throw RingAPIError.serverError(httpResponse.statusCode)
        }

        // Ring returns a tiny placeholder body while a recording is still processing
        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? Int) ?? 0
        guard size > 10_000 else {
            try? FileManager.default.removeItem(at: downloaded)
            throw RingAPIError.recordingNotFound
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ring_event_\(eventId).mp4")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    // MARK: - Live View

    public func startLiveView(deviceId: Int, audioMode: LiveViewSession.AudioMode) async throws -> LiveViewSession {
        LiveViewSession(
            deviceId: deviceId,
            accessToken: try await validAccessToken(),
            hardwareId: try await hardwareId(),
            audioMode: audioMode
        )
    }
}

// MARK: - Errors

public enum RingAuthError: Error, LocalizedError, Sendable {
    case invalidCredentials
    case requiresTwoFactor(prompt: String)
    case invalidTwoFactorCode
    case notLoggedIn
    case rateLimited
    case networkError

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password"
        case .requiresTwoFactor(let prompt):
            return prompt
        case .invalidTwoFactorCode:
            return "Invalid verification code"
        case .notLoggedIn:
            return "Not logged in"
        case .rateLimited:
            return "Too many requests. Please wait and try again."
        case .networkError:
            return "Network error. Check your connection."
        }
    }
}

public enum RingAPIError: Error, LocalizedError, Sendable {
    case unauthorized
    case notFound
    case rateLimited
    case serverError(Int)
    case networkError
    case recordingNotFound

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Session expired. Please log in again."
        case .notFound:
            return "Resource not found"
        case .rateLimited:
            return "Too many requests. Please wait."
        case .recordingNotFound:
            return "Recording not available yet"
        case .serverError(let code):
            return "Server error (\(code))"
        case .networkError:
            return "Network error"
        }
    }
}
