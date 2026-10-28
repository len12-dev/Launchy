import Foundation

/// Envoi du skin au serveur d'authentification Launchy.
enum SkinService {
    static func upload(_ png: Data, token: String) async throws {
        var request = URLRequest(url: Config.authBaseURL.appendingPathComponent("auth/skin"))
        request.httpMethod = "PUT"
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = png

        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return
        case 401: throw AuthError.sessionExpired
        case 400: throw AuthError.invalidSkin
        case let code?: throw AuthError.server(code)
        case nil: throw AuthError.network("réponse invalide")
        }
    }
}
