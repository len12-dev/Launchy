import Foundation

enum Config {
    /// Serveur d'authentification Launchy (tunnel Cloudflare).
    static let authBaseURL = URL(string: "https://auth-launchy.neo-verse.net")!

    /// Serveur de jeu auquel Launchy se connecte directement au lancement.
    static let gameServer = "ultra.neo-verse.net"
}
