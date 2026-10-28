import Foundation

/// Vérifie auprès de Mojang si un pseudo appartient à un compte premium.
/// Un pseudo premium ne peut jamais être enregistré comme compte crack.
enum PremiumNameChecker {
    static func isPremiumName(_ username: String) async throws -> Bool {
        let url = URL(string: "https://api.mojang.com/users/profiles/minecraft/\(username)")!
        let (_, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network("réponse invalide")
        }
        switch http.statusCode {
        case 200: return true
        case 204, 404: return false
        default: throw AuthError.server(http.statusCode)
        }
    }
}
