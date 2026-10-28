import Foundation

/// Liste des versions publiée par Mojang.
struct VersionList: Decodable {
    struct Entry: Decodable {
        let id: String
        let url: URL
        let sha1: String
    }

    let versions: [Entry]
}

/// Description d'une version de Minecraft (fichier JSON de Mojang).
struct VersionManifest: Decodable {
    let id: String
    let mainClass: String
    let javaVersion: JavaVersion?
    let assetIndex: AssetIndexRef
    let downloads: Downloads
    let libraries: [Library]
    let arguments: Arguments

    struct JavaVersion: Decodable {
        let component: String
        let majorVersion: Int
    }

    struct AssetIndexRef: Decodable {
        let id: String
        let url: URL
        let sha1: String
    }

    struct Downloads: Decodable {
        let client: Artifact
    }

    struct Artifact: Decodable {
        let url: URL
        let sha1: String
        let path: String?
        let size: Int?
    }

    struct Library: Decodable {
        struct LibraryDownloads: Decodable {
            let artifact: Artifact?
        }

        let name: String
        let downloads: LibraryDownloads?
        let rules: [Rule]?
        let natives: [String: String]?
    }

    struct Arguments: Decodable {
        let game: [Argument]
        let jvm: [Argument]
    }
}

/// Règle de Mojang : une bibliothèque ou un argument n'est utilisé que si la règle s'applique.
struct Rule: Decodable {
    struct OS: Decodable {
        let name: String?
        let arch: String?
    }

    let action: String
    let os: OS?
    let features: [String: Bool]?

    /// Vrai si la règle concerne ce Mac (Apple Silicon) sans fonctionnalité optionnelle activée.
    var matchesThisMac: Bool {
        if let name = os?.name, name != "osx" { return false }
        if os?.arch == "x86" { return false }
        if let features, features.values.contains(true) { return false }
        return true
    }
}

/// La dernière règle qui correspond décide ; sans règle, l'élément est utilisé.
func isAllowed(_ rules: [Rule]?) -> Bool {
    guard let rules, !rules.isEmpty else { return true }
    var allowed = false
    for rule in rules where rule.matchesThisMac {
        allowed = rule.action == "allow"
    }
    return allowed
}

/// Argument JVM ou de jeu : texte simple, ou texte conditionné par des règles.
enum Argument: Decodable {
    case plain(String)
    case conditional(rules: [Rule], values: [String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .plain(text)
            return
        }
        let object = try container.decode(Conditional.self)
        self = .conditional(rules: object.rules, values: object.values)
    }

    private struct Conditional: Decodable {
        enum Keys: CodingKey {
            case rules, value
        }

        let rules: [Rule]
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            rules = try container.decode([Rule].self, forKey: .rules)
            if let single = try? container.decode(String.self, forKey: .value) {
                values = [single]
            } else {
                values = try container.decode([String].self, forKey: .value)
            }
        }
    }
}

/// Index des assets : nom logique -> hash SHA-1 (le fichier est servi par hash).
struct AssetIndex: Decodable {
    struct Object: Decodable {
        let hash: String
        let size: Int
    }

    let objects: [String: Object]
}

/// Référence vers le manifeste d'un runtime (plateforme -> composant -> [référence]).
struct RuntimeRef: Decodable {
    let manifest: VersionManifest.Artifact
}

/// Manifeste d'un runtime Java de Mojang (fichiers, dossiers, liens).
struct RuntimeManifest: Decodable {
    struct Entry: Decodable {
        struct Downloads: Decodable {
            let raw: VersionManifest.Artifact
        }

        let type: String
        let executable: Bool?
        let target: String?
        let downloads: Downloads?
    }

    let files: [String: Entry]
}
