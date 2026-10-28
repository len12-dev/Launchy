import Foundation

/// Synchronise le dossier `mods` avec le manifeste publié sur mods.neo-verse.net.
enum ModSync {
    static let manifestURL = URL(string: "https://mods.neo-verse.net/ultra/lastest")!

    static func sync(into modsDir: URL, progress: @escaping MinecraftInstaller.Progress) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: modsDir, withIntermediateDirectories: true)
        await progress("Mods", 0)

        let manifest = try await Downloader.getJSON(ModManifest.self, from: manifestURL)
        let wanted = Set(manifest.mods.map(\.name))

        // Supprime les jars qui ne sont plus publiés sur le serveur.
        for file in try fm.contentsOfDirectory(atPath: modsDir.path) where file.hasSuffix(".jar") && !wanted.contains(file) {
            try fm.removeItem(at: modsDir.appendingPathComponent(file))
        }

        try await MinecraftInstaller.downloadAll(
            manifest.mods.map { (url: $0.url, sha1: $0.sha1, destination: modsDir.appendingPathComponent($0.name)) },
            label: "Mods",
            range: 0...1,
            progress: progress
        )
        await progress("Mods à jour (\(manifest.mods.count))", 1)
    }
}
