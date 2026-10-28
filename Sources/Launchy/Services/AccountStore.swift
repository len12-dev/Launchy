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

    func register(username: String, password: String) async {
        await perform { try await self.auth.register(username: username, password: password) }
    }

    func logout() {
        current = nil
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
