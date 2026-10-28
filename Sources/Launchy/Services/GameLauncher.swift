import Foundation
import Observation

/// Installe Minecraft et NeoForge, synchronise les mods, puis lance le jeu sur le serveur Ultra.
@MainActor
@Observable
final class GameLauncher {
    enum Phase: Equatable {
        case idle
        case installing(String, Double)
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var process: Process?

    var isBusy: Bool {
        switch phase {
        case .installing, .running: true
        case .idle, .failed: false
        }
    }

    func play(as account: Account) async {
        guard !isBusy else { return }
        let report: MinecraftInstaller.Progress = { label, fraction in
            self.phase = .installing(label, fraction)
        }
        phase = .installing("Préparation", 0)
        do {
            let files = try await MinecraftInstaller.install(progress: report)
            try await ModSync.sync(into: files.gameDir.appendingPathComponent("mods", isDirectory: true), progress: report)
            try start(files, as: account)
            phase = .running
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func start(_ files: MinecraftInstaller.Files, as account: Account) throws {
        let values = [
            "auth_player_name": account.username,
            "version_name": MinecraftInstaller.loaderID,
            "game_directory": files.gameDir.path,
            "assets_root": files.assetsDir.path,
            "assets_index_name": files.assetIndexID,
            "auth_uuid": account.uuid.replacingOccurrences(of: "-", with: ""),
            "auth_access_token": "0",
            "auth_session": "0",
            "clientid": "",
            "auth_xuid": "",
            "user_type": "legacy",
            "user_properties": "{}",
            "version_type": "release",
            "natives_directory": files.nativesDir.path,
            "library_directory": files.libraryRoot.path,
            "classpath_separator": ":",
            "launcher_name": "Launchy",
            "launcher_version": "1.0",
            "classpath": (files.classpath + [files.clientJar.path]).joined(separator: ":"),
        ]

        let jvmArguments = ["-Xms1G", "-Xmx4G"] + resolve(files.jvmArguments, values)
        // Connexion directe au serveur Ultra : pas de menu titre.
        let gameArguments = resolve(files.gameArguments, values) + ["--quickPlayMultiplayer", Config.gameServer]

        let process = Process()
        process.executableURL = files.java
        process.arguments = jvmArguments + [files.mainClass] + gameArguments
        process.currentDirectoryURL = files.gameDir

        let log = files.gameDir.appendingPathComponent("launchy-latest.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output
        process.standardError = output

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.phase = .idle
            }
        }

        try process.run()
        self.process = process
    }

    private func resolve(_ arguments: [Argument], _ values: [String: String]) -> [String] {
        arguments
            .flatMap { argument -> [String] in
                switch argument {
                case .plain(let text): [text]
                case .conditional(let rules, let texts): isAllowed(rules) ? texts : []
                }
            }
            .map { text in
                values.reduce(text) { result, pair in
                    result.replacingOccurrences(of: "${" + pair.key + "}", with: pair.value)
                }
            }
    }
}
