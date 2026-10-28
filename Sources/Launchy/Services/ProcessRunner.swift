import Foundation

/// Lance un processus jusqu'à la fin et renvoie son code de sortie. La sortie va dans `log`.
enum ProcessRunner {
    static func run(executable: URL, arguments: [String], currentDirectory: URL, log: URL) async throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { finished in
                try? output.close()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                try? output.close()
                continuation.resume(throwing: error)
            }
        }
    }
}
