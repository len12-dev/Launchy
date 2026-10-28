import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SkinView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var pendingSkin: Data?
    @State private var preview: NSImage?
    @State private var showImporter = false
    @State private var isUploading = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 20) {
            if let preview {
                Image(nsImage: preview)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 192, height: 192 * preview.size.height / preview.size.width)
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            } else {
                ContentUnavailableView(
                    "Aucun skin",
                    systemImage: "person.crop.square",
                    description: Text("Importez un fichier PNG de 64×64 ou 64×32.")
                )
                .frame(height: 240)
            }

            HStack {
                Button("Importer un PNG…") { showImporter = true }
                Button(isUploading ? "Envoi…" : "Envoyer au serveur") { upload() }
                    .buttonStyle(.borderedProminent)
                    .disabled(pendingSkin == nil || accounts.current?.token == nil || isUploading)
            }

            if accounts.current == nil {
                Text("Connectez-vous dans Compte pour envoyer votre skin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .navigationTitle("Skins")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.png]) { result in
            importSkin(result)
        }
    }

    private func importSkin(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            guard let bitmap = NSBitmapImageRep(data: data),
                  bitmap.pixelsWide == 64,
                  bitmap.pixelsHigh == 64 || bitmap.pixelsHigh == 32,
                  let image = NSImage(data: data) else {
                message = AuthError.invalidSkin.localizedDescription
                return
            }
            pendingSkin = data
            preview = image
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func upload() {
        guard let data = pendingSkin, let token = accounts.current?.token else { return }
        isUploading = true
        message = nil
        Task {
            do {
                try await SkinService.upload(data, token: token)
                message = "Skin envoyé. Il sera visible sur le serveur après la prochaine connexion."
            } catch {
                message = error.localizedDescription
            }
            isUploading = false
        }
    }
}
