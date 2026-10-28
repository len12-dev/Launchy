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
    case invalidEmail
    case premiumNameTaken
    case reservedName
    case wrongCredentials
    case usernameAlreadyRegistered
    case emailAlreadyUsed
    case invalidOrExpiredCode
    case sessionExpired
    case invalidSkin
    case emailUnavailable
    case network(String)
    case server(Int)
    case unknown(String)

    /// Traduit le code d'erreur renvoyé par le serveur d'authentification.
    init(serverCode: String, status: Int) {
        switch serverCode {
        case "invalid_username": self = .invalidUsername
        case "invalid_email": self = .invalidEmail
        case "premium_name": self = .premiumNameTaken
        case "reserved_name": self = .reservedName
        case "invalid_credentials": self = .wrongCredentials
        case "username_taken": self = .usernameAlreadyRegistered
        case "email_taken": self = .emailAlreadyUsed
        case "invalid_or_expired_code": self = .invalidOrExpiredCode
        case "email_unavailable": self = .emailUnavailable
        case "unauthorized": self = .sessionExpired
        case "invalid_skin": self = .invalidSkin
        case "too_many_requests": self = .unknown("Trop de tentatives. Réessayez dans une minute.")
        default: self = status >= 500 ? .server(status) : .unknown(serverCode)
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidUsername:
            "Pseudo invalide : 3 à 16 caractères, lettres, chiffres et _."
        case .invalidEmail:
            "Adresse email invalide."
        case .premiumNameTaken:
            "Ce pseudo appartient à un compte Minecraft officiel. Il ne peut pas être utilisé ici."
        case .reservedName:
            "Ce pseudo est réservé. Contactez l'administrateur pour l'obtenir."
        case .wrongCredentials:
            "Pseudo ou mot de passe incorrect."
        case .usernameAlreadyRegistered:
            "Ce pseudo est déjà enregistré. Connectez-vous avec son mot de passe."
        case .emailAlreadyUsed:
            "Cette adresse email est déjà utilisée par un autre compte."
        case .invalidOrExpiredCode:
            "Code invalide ou expiré. Demandez un nouveau code."
        case .sessionExpired:
            "Session expirée. Reconnectez-vous dans Compte."
        case .invalidSkin:
            "Skin invalide : PNG de 64×64 ou 64×32 requis."
        case .emailUnavailable:
            "L'envoi d'email est indisponible pour le moment. Réessayez plus tard."
        case .network(let message):
            "Connexion impossible : \(message)"
        case .server(let code):
            "Erreur du serveur d'authentification (\(code))."
        case .unknown(let message):
            message
        }
    }
}
