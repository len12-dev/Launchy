import CryptoKit
import Foundation

enum DownloadError: LocalizedError {
    case badStatus(Int, URL)
    case checksumMismatch(URL)
    case versionNotFound(String)
    case runtimeNotFound(String)
    case neoForgeInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let url):
            "Téléchargement échoué (\(code)) : \(url.lastPathComponent)"
        case .checksumMismatch(let url):
            "Fichier corrompu : \(url.lastPathComponent)"
        case .versionNotFound(let id):
            "Version \(id) introuvable chez Mojang"
        case .runtimeNotFound(let component):
            "Runtime Java « \(component) » introuvable pour ce Mac"
        case .neoForgeInstallFailed(let log):
            "Installation de NeoForge échouée, voir le journal : \(log)"
        }
    }
}

enum Downloader {
    /// Télécharge `url` dans `destination` si le fichier est absent ou si son SHA-1 ne correspond pas.
    static func ensureFile(at url: URL, to destination: URL, sha1: String?) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            guard let sha1 else { return }
            if try sha1Hex(of: destination) == sha1 { return }
        }

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0, url)
        }
        if let sha1 {
            guard try sha1Hex(of: tmp) == sha1 else { throw DownloadError.checksumMismatch(url) }
        }

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tmp, to: destination)
    }

    static func getJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0, url)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func sha1Hex(of file: URL) throws -> String {
        let digest = Insecure.SHA1.hash(data: try Data(contentsOf: file))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Compteur partagé entre les téléchargements parallèles.
actor Counter {
    private var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

extension Sequence where Element: Sendable {
    /// Exécute `operation` sur chaque élément, avec au plus `limit` tâches en parallèle.
    func concurrentForEach(limit: Int, _ operation: @escaping @Sendable (Element) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = makeIterator()
            for _ in 0..<limit {
                guard let element = iterator.next() else { break }
                group.addTask { try await operation(element) }
            }
            while try await group.next() != nil {
                if let element = iterator.next() {
                    group.addTask { try await operation(element) }
                }
            }
        }
    }
}
