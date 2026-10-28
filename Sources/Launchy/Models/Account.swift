import Foundation

/// Un compte Launchy. Le mot de passe n'est jamais stocké localement.
struct Account: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// Compte Minecraft officiel, pseudo réservé chez Mojang.
        case premium
        /// Compte hors ligne, géré par le backend Launchy.
        case cracked
    }

    var id: String { username.lowercased() }
    let username: String
    let kind: Kind
    /// UUID renvoyé par le backend (ou Mojang pour un compte premium).
    let uuid: String
    /// Jeton de session du backend Launchy, nécessaire pour envoyer un skin.
    var token: String? = nil
}

enum AuthError: LocalizedError {
    case invalidUsername
    case premiumNameTaken
    case wrongCredentials
    case sessionExpired
    case invalidSkin
    case usernameAlreadyRegistered
    case network(String)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidUsername:
            "Pseudo invalide : 3 à 16 caractères, lettres, chiffres et _."
        case .premiumNameTaken:
            "Ce pseudo appartient à un compte Minecraft officiel. Connectez-vous avec le compte premium."
        case .wrongCredentials:
            "Pseudo ou mot de passe incorrect."
        case .sessionExpired:
            "Session expirée. Reconnectez-vous dans Compte."
        case .invalidSkin:
            "Skin invalide : PNG de 64×64 ou 64×32 requis."
        case .usernameAlreadyRegistered:
            "Ce pseudo est déjà enregistré. Connectez-vous avec son mot de passe."
        case .network(let message):
            "Connexion impossible : \(message)"
        case .server(let code):
            "Erreur du serveur d'authentification (\(code))."
        }
    }
}
