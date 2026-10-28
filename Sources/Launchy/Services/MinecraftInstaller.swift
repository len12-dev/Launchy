import Foundation

/// Installe Minecraft vanilla dans le dossier de Launchy, comme le fait le launcher officiel.
enum MinecraftInstaller {
    static let versionID = "1.21.1"

    /// Mojang publie l'index des runtimes Java ; cette URL est celle utilisée par le launcher officiel.
    private static let runtimeIndexURL = URL(string: "https://launchermeta.mojang.com/v1/products/java-runtime/2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json")!
    private static let assetBaseURL = "https://resources.download.minecraft.net"

    static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Launchy/minecraft", isDirectory: true)

    /// Tout ce qu'il faut pour lancer le jeu.
    struct Files {
        let version: VersionManifest
        let java: URL
        let classpath: [String]
        let clientJar: URL
        let gameDir: URL
        let assetsDir: URL
        let nativesDir: URL
    }

    typealias Progress = @MainActor @Sendable (String, Double) -> Void

    static func install(progress: @escaping Progress) async throws -> Files {
        let fm = FileManager.default
        let gameDir = root.appendingPathComponent("game", isDirectory: true)
        let assetsDir = root.appendingPathComponent("assets", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("libraries", isDirectory: true)
        let versionDir = root.appendingPathComponent("versions/\(versionID)", isDirectory: true)
        let nativesDir = versionDir.appendingPathComponent("natives", isDirectory: true)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: nativesDir, withIntermediateDirectories: true)

        await progress("Version \(versionID)", 0)
        let version = try await loadVersion(into: versionDir)

        // Client
        let clientJar = versionDir.appendingPathComponent("\(versionID).jar")
        await progress("Client Minecraft", 0.02)
        try await Downloader.ensureFile(at: version.downloads.client.url, to: clientJar, sha1: version.downloads.client.sha1)

        // Bibliothèques
        let libraries = version.libraries.compactMap { library -> (path: String, artifact: VersionManifest.Artifact)? in
            guard isAllowed(library.rules), library.natives == nil, let artifact = library.downloads?.artifact, let path = artifact.path else {
                return nil
            }
            return (path, artifact)
        }
        try await downloadAll(
            libraries.map { (url: $0.artifact.url, sha1: $0.artifact.sha1, destination: libraryRoot.appendingPathComponent($0.path)) },
            label: "Bibliothèques",
            range: 0.05...0.35,
            progress: progress
        )
        let classpath = libraries.map { libraryRoot.appendingPathComponent($0.path).path }

        // Assets
        let indexFile = assetsDir.appendingPathComponent("indexes/\(version.assetIndex.id).json")
        try await Downloader.ensureFile(at: version.assetIndex.url, to: indexFile, sha1: version.assetIndex.sha1)
        let index = try JSONDecoder().decode(AssetIndex.self, from: Data(contentsOf: indexFile))
        try await downloadAll(
            index.objects.values.map { object in
                let prefix = String(object.hash.prefix(2))
                return (
                    url: URL(string: "\(assetBaseURL)/\(prefix)/\(object.hash)")!,
                    sha1: object.hash,
                    destination: assetsDir.appendingPathComponent("objects/\(prefix)/\(object.hash)")
                )
            },
            label: "Assets",
            range: 0.35...0.7,
            progress: progress
        )

        // Java
        let component = version.javaVersion?.component ?? "jre-legacy"
        let runtimeDir = root.appendingPathComponent("runtime/\(component)", isDirectory: true)
        try await installRuntime(component: component, into: runtimeDir, progress: progress)

        return Files(
            version: version,
            java: runtimeDir.appendingPathComponent("jre.bundle/Contents/Home/bin/java"),
            classpath: classpath,
            clientJar: clientJar,
            gameDir: gameDir,
            assetsDir: assetsDir,
            nativesDir: nativesDir
        )
    }

    private static func loadVersion(into versionDir: URL) async throws -> VersionManifest {
        let list = try await Downloader.getJSON(VersionList.self, from: URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!)
        guard let entry = list.versions.first(where: { $0.id == versionID }) else {
            throw DownloadError.versionNotFound(versionID)
        }
        let file = versionDir.appendingPathComponent("\(versionID).json")
        try await Downloader.ensureFile(at: entry.url, to: file, sha1: entry.sha1)
        return try JSONDecoder().decode(VersionManifest.self, from: Data(contentsOf: file))
    }

    private static func installRuntime(component: String, into dir: URL, progress: @escaping Progress) async throws {
        #if arch(arm64)
        let platform = "mac-os-arm64"
        #else
        let platform = "mac-os"
        #endif

        let index = try await Downloader.getJSON([String: [String: [RuntimeRef]]].self, from: runtimeIndexURL)
        guard let ref = index[platform]?[component]?.first else {
            throw DownloadError.runtimeNotFound(component)
        }
        let manifest = try await Downloader.getJSON(RuntimeManifest.self, from: ref.manifest.url)

        let fm = FileManager.default
        var files: [(url: URL, sha1: String, destination: URL)] = []
        var executables: [URL] = []
        var links: [(link: URL, target: String)] = []

        for (path, entry) in manifest.files {
            let target = dir.appendingPathComponent(path)
            switch entry.type {
            case "directory":
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case "file":
                guard let raw = entry.downloads?.raw else { continue }
                files.append((url: raw.url, sha1: raw.sha1, destination: target))
                if entry.executable == true { executables.append(target) }
            case "link":
                if let destination = entry.target { links.append((link: target, target: destination)) }
            default:
                continue
            }
        }

        try await downloadAll(files, label: "Java \(component)", range: 0.7...0.95, progress: progress)

        for executable in executables {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        for link in links {
            try? fm.removeItem(at: link.link)
            try fm.createDirectory(at: link.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link.link.path, withDestinationPath: link.target)
        }
    }

    private static func downloadAll(
        _ items: [(url: URL, sha1: String, destination: URL)],
        label: String,
        range: ClosedRange<Double>,
        progress: @escaping Progress
    ) async throws {
        let total = items.count
        guard total > 0 else {
            await progress(label, range.upperBound)
            return
        }
        let counter = Counter()
        try await items.concurrentForEach(limit: 16) { item in
            try await Downloader.ensureFile(at: item.url, to: item.destination, sha1: item.sha1)
            let done = await counter.increment()
            let fraction = range.lowerBound + (range.upperBound - range.lowerBound) * Double(done) / Double(total)
            await progress("\(label) \(done)/\(total)", fraction)
        }
    }
}
