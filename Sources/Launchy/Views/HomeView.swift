import SwiftUI

struct HomeView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(GameLauncher.self) private var launcher

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "cube.transparent.fill")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(.tint)

            Text("Launchy")
                .font(.largeTitle.bold())

            Text("Minecraft 1.21.1 · NeoForge")
                .foregroundStyle(.secondary)

            Button {
                guard let account = accounts.current else { return }
                Task { await launcher.play(as: account) }
            } label: {
                Label(buttonTitle, systemImage: "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 200)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(launcher.isBusy || accounts.current == nil)

            status

            Spacer()
        }
        .padding()
    }

    private var buttonTitle: String {
        switch launcher.phase {
        case .installing: "Installation…"
        case .running: "En jeu"
        case .idle, .failed: "Jouer"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch launcher.phase {
        case .installing(let label, let fraction):
            VStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 320)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        case .idle, .running:
            if accounts.current == nil {
                Text("Connectez-vous dans Compte pour jouer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
