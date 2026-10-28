import Foundation

/// Installe Minecraft vanilla et NeoForge dans le dossier de Launchy, comme le fait le launcher officiel.
enum MinecraftInstaller {
    static let minecraftVersion = "1.21.1"
    static let neoForgeVersion = "21.1.265"
    static let loaderID = "neoforge-\(neoForgeVersion)"

    /// Index des runtimes Java de Mojang, utilisé par le launcher officiel.
    private static let runtimeIndexURL = URL(string: "https://launchermeta.mojang.com/v1/products/java-runtime/2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json")!
    private static let assetBaseURL = "https://resources.download.minecraft.net"
    private static let defaultLibraryBase = "https://libraries.minecraft.net/"
    private static let neoForgeInstallerURL = URL(string: "https://maven.neoforged.net/releases/net/neoforged/neoforge/\(neoForgeVersion)/neoforge-\(neoForgeVersion)-installer.jar")!

    static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Launchy/minecraft", isDirectory: true)

    /// Tout ce qu'il faut pour lancer le jeu.
    struct Files {
        let java: URL
        let mainClass: String
        let jvmArguments: [Argument]
        let gameArguments: [Argument]
        let assetIndexID: String
        let classpath: [String]
        let clientJar: URL
        let libraryRoot: URL
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
        let versionDir = root.appendingPathComponent("versions/\(minecraftVersion)", isDirectory: true)
        let nativesDir = versionDir.appendingPathComponent("natives", isDirectory: true)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: nativesDir, withIntermediateDirectories: true)

        // Vanilla : manifeste, client, Java
        await progress("Version \(minecraftVersion)", 0)
        let version = try await loadVersion(into: versionDir)

        let clientJar = versionDir.appendingPathComponent("\(minecraftVersion).jar")
        await progress("Client Minecraft", 0.03)
        try await Downloader.ensureFile(at: version.downloads.client.url, to: clientJar, sha1: version.downloads.client.sha1)

        let component = version.javaVersion?.component ?? "jre-legacy"
        let runtimeDir = root.appendingPathComponent("runtime/\(component)", isDirectory: true)
        try await installRuntime(component: component, into: runtimeDir, progress: progress, range: 0.05...0.2)
        let java = runtimeDir.appendingPathComponent("jre.bundle/Contents/Home/bin/java")

        // NeoForge : installeur officiel en mode headless
        try await installNeoForge(java: java, progress: progress)
        let loader = try JSONDecoder().decode(
            LoaderVersion.self,
            from: Data(contentsOf: root.appendingPathComponent("versions/\(loaderID)/\(loaderID).json"))
        )

        // Bibliothèques : vanilla puis NeoForge (la version NeoForge l'emporte en cas de doublon)
        let libraries = libraryFiles(vanilla: version.libraries, loader: loader.libraries)
        try await downloadAll(
            libraries.map { (url: $0.url, sha1: $0.sha1, destination: libraryRoot.appendingPathComponent($0.path)) },
            label: "Bibliothèques",
            range: 0.4...0.6,
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
            range: 0.6...0.95,
            progress: progress
        )

        await progress("Prêt", 1)
        return Files(
            java: java,
            mainClass: loader.mainClass,
            jvmArguments: version.arguments.jvm + (loader.arguments?.jvm ?? []),
            gameArguments: version.arguments.game + (loader.arguments?.game ?? []),
            assetIndexID: version.assetIndex.id,
            classpath: classpath,
            clientJar: clientJar,
            libraryRoot: libraryRoot,
            gameDir: gameDir,
            assetsDir: assetsDir,
            nativesDir: nativesDir
        )
    }

    private static func loadVersion(into versionDir: URL) async throws -> VersionManifest {
        let list = try await Downloader.getJSON(VersionList.self, from: URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!)
        guard let entry = list.versions.first(where: { $0.id == minecraftVersion }) else {
            throw DownloadError.versionNotFound(minecraftVersion)
        }
        let file = versionDir.appendingPathComponent("\(minecraftVersion).json")
        try await Downloader.ensureFile(at: entry.url, to: file, sha1: entry.sha1)
        return try JSONDecoder().decode(VersionManifest.self, from: Data(contentsOf: file))
    }

    /// Lance l'installeur NeoForge une seule fois : il écrit le profil et les bibliothèques dans `root`.
    private static func installNeoForge(java: URL, progress: @escaping Progress) async throws {
        let fm = FileManager.default
        let profile = root.appendingPathComponent("versions/\(loaderID)/\(loaderID).json")
        guard !fm.fileExists(atPath: profile.path) else { return }

        await progress("Installation de NeoForge \(neoForgeVersion)", 0.2)
        let installer = root.appendingPathComponent("installers/\(loaderID)-installer.jar")
        try await Downloader.ensureFile(at: neoForgeInstallerURL, to: installer, sha1: nil)

        // L'installeur exige un launcher_profiles.json, même vide.
        let launcherProfiles = root.appendingPathComponent("launcher_profiles.json")
        if !fm.fileExists(atPath: launcherProfiles.path) {
            try Data("{\"profiles\":{}}".utf8).write(to: launcherProfiles)
        }

        let log = root.appendingPathComponent("neoforge-installer.log")
        let status = try await ProcessRunner.run(
            executable: java,
            arguments: ["-jar", installer.path, "--installClient", root.path],
            currentDirectory: root,
            log: log
        )
        guard status == 0, fm.fileExists(atPath: profile.path) else {
            throw DownloadError.neoForgeInstallFailed(log.path)
        }
    }

    /// Fusionne les bibliothèques (la dernière version d'un même artefact gagne) et garde celles de ce Mac.
    private static func libraryFiles(vanilla: [VersionManifest.Library], loader: [VersionManifest.Library]) -> [LibraryFile] {
        var byKey: [String: VersionManifest.Library] = [:]
        var order: [String] = []
        for library in vanilla + loader {
            guard let key = mavenKey(library.name) else { continue }
            if byKey[key] == nil { order.append(key) }
            byKey[key] = library
        }

        return order.compactMap { key -> LibraryFile? in
            guard let library = byKey[key], isAllowed(library.rules), library.natives == nil else { return nil }
            let artifact = library.downloads?.artifact
            guard let path = artifact?.path ?? mavenPath(library.name) else { return nil }
            let url = artifact?.url ?? URL(string: (library.url ?? defaultLibraryBase) + path)
            guard let url else { return nil }
            return LibraryFile(path: path, url: url, sha1: artifact?.sha1)
        }
    }

    /// `groupe:artefact[:classifieur]` : identifie un artefact indépendamment de sa version.
    private static func mavenKey(_ name: String) -> String? {
        let parts = name.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return nil }
        return parts.count > 3 ? "\(parts[0]):\(parts[1]):\(parts[3])" : "\(parts[0]):\(parts[1])"
    }

    /// Chemin Maven d'un artefact : `net.neoforged:neoforge:1.0` -> `net/neoforged/neoforge/1.0/neoforge-1.0.jar`.
    private static func mavenPath(_ name: String) -> String? {
        let parts = name.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return nil }
        let (group, artifact, version) = (parts[0], parts[1], parts[2])
        let classifier = parts.count > 3 ? "-\(parts[3])" : ""
        return "\(group.replacingOccurrences(of: ".", with: "/"))/\(artifact)/\(version)/\(artifact)-\(version)\(classifier).jar"
    }

    private static func installRuntime(component: String, into dir: URL, progress: @escaping Progress, range: ClosedRange<Double>) async throws {
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

        try await downloadAll(files, label: "Java \(component)", range: range, progress: progress)

        for executable in executables {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        for link in links {
            try? fm.removeItem(at: link.link)
            try fm.createDirectory(at: link.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link.link.path, withDestinationPath: link.target)
        }
    }

    /// Télécharge en parallèle ; le SHA-1 est vérifié quand il est connu.
    static func downloadAll(
        _ items: [(url: URL, sha1: String?, destination: URL)],
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

/// Une bibliothèque à télécharger : chemin relatif dans `libraries/`, URL, SHA-1 optionnel.
struct LibraryFile {
    let path: String
    let url: URL
    let sha1: String?
}
