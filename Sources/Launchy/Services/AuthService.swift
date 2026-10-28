import Foundation

/// Authentification des comptes cracks via le backend Launchy.
/// Le backend doit aussi refuser l'enregistrement d'un pseudo premium (double vérification).
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

    func register(username: String, password: String) async throws -> Account {
        guard Self.isValidUsername(username) else { throw AuthError.invalidUsername }
        if try await PremiumNameChecker.isPremiumName(username) {
            throw AuthError.premiumNameTaken
        }
        return try await post(path: "register", username: username, password: password, status409: .usernameAlreadyRegistered)
    }

    func login(username: String, password: String) async throws -> Account {
        guard Self.isValidUsername(username) else { throw AuthError.invalidUsername }
        return try await post(path: "login", username: username, password: password, status409: .wrongCredentials)
    }

    private struct Credentials: Encodable {
        let username: String
        let password: String
    }

    private struct Response: Decodable {
        let username: String
        let uuid: String
        let token: String
    }

    private func post(path: String, username: String, password: String, status409: AuthError) async throws -> Account {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Credentials(username: username, password: password))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.network("réponse invalide") }

        switch http.statusCode {
        case 200:
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return Account(username: decoded.username, kind: .cracked, uuid: decoded.uuid, token: decoded.token)
        case 401, 403:
            throw AuthError.wrongCredentials
        case 409:
            throw status409
        default:
            throw AuthError.server(http.statusCode)
        }
    }
}
