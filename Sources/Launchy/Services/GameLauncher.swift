import Foundation
import Observation

/// Installe Minecraft si besoin, puis lance le jeu avec le compte connecté.
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
        phase = .installing("Préparation", 0)
        do {
            let files = try await MinecraftInstaller.install { label, fraction in
                self.phase = .installing(label, fraction)
            }
            try start(files, as: account)
            phase = .running
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func start(_ files: MinecraftInstaller.Files, as account: Account) throws {
        let values = [
            "auth_player_name": account.username,
            "version_name": files.version.id,
            "game_directory": files.gameDir.path,
            "assets_root": files.assetsDir.path,
            "assets_index_name": files.version.assetIndex.id,
            "auth_uuid": account.uuid.replacingOccurrences(of: "-", with: ""),
            "auth_access_token": "0",
            "auth_session": "0",
            "clientid": "",
            "auth_xuid": "",
            "user_type": "legacy",
            "user_properties": "{}",
            "version_type": "release",
            "natives_directory": files.nativesDir.path,
            "launcher_name": "Launchy",
            "launcher_version": "1.0",
            "classpath": (files.classpath + [files.clientJar.path]).joined(separator: ":"),
        ]

        let jvmArguments = ["-Xms512M", "-Xmx2G"] + resolve(files.version.arguments.jvm, values)
        let gameArguments = resolve(files.version.arguments.game, values)

        let process = Process()
        process.executableURL = files.java
        process.arguments = jvmArguments + [files.version.mainClass] + gameArguments
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
