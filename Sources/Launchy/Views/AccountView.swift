import SwiftUI

struct AccountView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var username = ""
    @State private var password = ""
    @State private var isRegistering = false

    var body: some View {
        if let account = accounts.current {
            connected(account)
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Pseudo", text: $username)
                    .textContentType(.username)
                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
            } footer: {
                Text(isRegistering
                     ? "Le pseudo sera réservé à ce compte. Un pseudo premium Minecraft ne peut pas être utilisé."
                     : "Connectez-vous avec le pseudo et le mot de passe de votre compte Launchy.")
            }

            Section {
                Button(isRegistering ? "Créer le compte" : "Se connecter") {
                    Task {
                        if isRegistering {
                            await accounts.register(username: username, password: password)
                        } else {
                            await accounts.login(username: username, password: password)
                        }
                        password = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || password.isEmpty || accounts.isBusy)

                Button(isRegistering ? "J'ai déjà un compte" : "Créer un compte") {
                    isRegistering.toggle()
                    accounts.errorMessage = nil
                }
                .buttonStyle(.link)
            }

            if let message = accounts.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Compte")
        .frame(maxWidth: 480)
        .padding()
    }

    private func connected(_ account: Account) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(account.username).font(.title2.bold())
            Text(account.kind == .premium ? "Compte premium" : "Compte Launchy")
                .foregroundStyle(.secondary)
            Button("Se déconnecter") { accounts.logout() }
        }
        .padding()
    }
}
