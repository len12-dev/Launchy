import SwiftUI

struct AccountView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var username = ""
    @State private var password = ""
    @State private var email = ""
    @State private var isRegistering = false
    @State private var isResetting = false
    @State private var resetCode = ""
    @State private var resetSent = false
    @State private var newPassword = ""
    @State private var notice: String?

    var body: some View {
        if let account = accounts.current {
            connected(account)
        } else if isResetting {
            resetForm
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
                if isRegistering {
                    TextField("Adresse email", text: $email)
                        .textContentType(.emailAddress)
                }
            } footer: {
                Text(isRegistering
                     ? "L'email est obligatoire : il sert à récupérer votre compte si vous oubliez votre mot de passe."
                     : "Connectez-vous avec le pseudo et le mot de passe de votre compte Launchy.")
            }

            Section {
                Button(isRegistering ? "Créer le compte" : "Se connecter") {
                    Task {
                        if isRegistering {
                            await accounts.register(username: username, password: password, email: email)
                        } else {
                            await accounts.login(username: username, password: password)
                        }
                        password = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || password.isEmpty || (isRegistering && email.isEmpty) || accounts.isBusy)

                Button(isRegistering ? "J'ai déjà un compte" : "Créer un compte") {
                    isRegistering.toggle()
                    accounts.errorMessage = nil
                }
                .buttonStyle(.link)

                if !isRegistering {
                    Button("Mot de passe oublié ?") {
                        isResetting = true
                        accounts.errorMessage = nil
                    }
                    .buttonStyle(.link)
                }
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

    private var resetForm: some View {
        Form {
            Section {
                TextField("Adresse email du compte", text: $email)
                    .textContentType(.emailAddress)
                Button(resetSent ? "Renvoyer le code" : "Envoyer le code") {
                    Task {
                        notice = nil
                        if await accounts.requestPasswordReset(email: email) {
                            resetSent = true
                            notice = "Si un compte existe avec cette adresse, un code vient d'être envoyé."
                        }
                    }
                }
                .disabled(email.isEmpty || accounts.isBusy)
            }

            if resetSent {
                Section {
                    TextField("Code reçu par email (6 chiffres)", text: $resetCode)
                    SecureField("Nouveau mot de passe", text: $newPassword)
                        .textContentType(.newPassword)
                    Button("Changer le mot de passe") {
                        Task {
                            if await accounts.resetPassword(email: email, code: resetCode, newPassword: newPassword) {
                                notice = "Mot de passe changé. Vous pouvez vous connecter."
                                resetSent = false
                                resetCode = ""
                                newPassword = ""
                                isResetting = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(resetCode.count != 6 || newPassword.count < 8 || accounts.isBusy)
                }
            }

            if let message = accounts.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            if let notice {
                Section {
                    Text(notice).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Retour à la connexion") {
                    isResetting = false
                    resetSent = false
                    accounts.errorMessage = nil
                    notice = nil
                }
                .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Mot de passe oublié")
        .frame(maxWidth: 480)
        .padding()
    }

    private func connected(_ account: Account) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(account.username).font(.title2.bold())
            Text("Compte Launchy")
                .foregroundStyle(.secondary)
            Button("Se déconnecter") { accounts.logout() }
        }
        .padding()
    }
}
