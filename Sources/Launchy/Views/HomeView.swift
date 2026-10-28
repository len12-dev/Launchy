import SwiftUI

struct HomeView: View {
    @State private var isLaunching = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "cube.transparent.fill")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(.tint)

            Text("Launchy")
                .font(.largeTitle.bold())

            Text("Serveur moddé · version à jour")
                .foregroundStyle(.secondary)

            Button {
                isLaunching = true
            } label: {
                Label(isLaunching ? "Lancement…" : "Jouer", systemImage: "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 200)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLaunching)

            Spacer()
        }
        .padding()
    }
}
