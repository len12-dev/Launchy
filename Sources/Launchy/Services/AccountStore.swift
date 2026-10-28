import Foundation
import Observation

/// État du compte connecté, partagé dans toute l'app.
@Observable
final class AccountStore {
    private(set) var current: Account?
    var isBusy = false
    var errorMessage: String?

    private let auth: AuthService

    init(auth: AuthService = AuthService()) {
        self.auth = auth
    }

    func login(username: String, password: String) async {
        await perform { try await self.auth.login(username: username, password: password) }
    }

    func register(username: String, password: String, email: String) async {
        await perform { try await self.auth.register(username: username, password: password, email: email) }
    }

    func requestPasswordReset(email: String) async -> Bool {
        await performSimple { try await self.auth.requestPasswordReset(email: email) }
    }

    func resetPassword(email: String, code: String, newPassword: String) async -> Bool {
        await performSimple { try await self.auth.resetPassword(email: email, code: code, newPassword: newPassword) }
    }

    func logout() {
        current = nil
    }

    /// Pour les actions sans nouveau compte : renvoie true si l'action a réussi.
    private func performSimple(_ action: @escaping () async throws -> Void) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await action()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func perform(_ action: @escaping () async throws -> Account) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            current = try await action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
