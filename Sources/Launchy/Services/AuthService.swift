import Foundation

/// Authentification des comptes Launchy via le serveur d'authentification.
struct AuthService {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = Config.authBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    static func isValidUsername(_ username: String) -> Bool {
        username.range(of: #"^[A-Za-z0-9_]{3,16}$"#, options: .regularExpression) != nil
    }

    static func isValidEmail(_ email: String) -> Bool {
        email.range(of: #"^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }

    func register(username: String, password: String, email: String) async throws -> Account {
        guard Self.isValidUsername(username) else { throw AuthError.invalidUsername }
        guard Self.isValidEmail(email) else { throw AuthError.invalidEmail }
        let response: AccountResponse = try await post(
            "auth/register",
            body: ["username": username, "password": password, "email": email]
        )
        return Account(username: response.username, kind: .cracked, uuid: response.uuid, token: response.token)
    }

    func login(username: String, password: String) async throws -> Account {
        guard Self.isValidUsername(username) else { throw AuthError.invalidUsername }
        let response: AccountResponse = try await post(
            "auth/login",
            body: ["username": username, "password": password]
        )
        return Account(username: response.username, kind: .cracked, uuid: response.uuid, token: response.token)
    }

    /// Demande un code de réinitialisation. Le serveur répond pareil que le compte existe ou non.
    func requestPasswordReset(email: String) async throws {
        guard Self.isValidEmail(email) else { throw AuthError.invalidEmail }
        let _: EmptyResponse = try await post("auth/forgot", body: ["email": email])
    }

    func resetPassword(email: String, code: String, newPassword: String) async throws {
        let _: EmptyResponse = try await post(
            "auth/reset",
            body: ["email": email, "code": code, "password": newPassword]
        )
    }

    private struct AccountResponse: Decodable {
        let username: String
        let uuid: String
        let token: String
    }

    private struct EmptyResponse: Decodable {}

    private struct ErrorResponse: Decodable {
        let error: String
    }

    private func post<Response: Decodable>(_ path: String, body: [String: String]) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.network("réponse invalide") }

        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error ?? ""
            throw AuthError(serverCode: code, status: http.statusCode)
        }
        if Response.self == EmptyResponse.self {
            return EmptyResponse() as! Response
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
