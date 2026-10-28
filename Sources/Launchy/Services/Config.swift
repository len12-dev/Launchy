import Foundation

enum Config {
    /// Backend d'authentification des comptes cracks. Serveur d'authentification Launchy (tunnel Cloudflare).
    static let authBaseURL = URL(string: "https://auth-launchy.neo-verse.net")!
}
