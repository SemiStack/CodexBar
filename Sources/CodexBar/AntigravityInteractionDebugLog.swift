import Foundation

enum AntigravityInteractionDebugLog {
    private static let queue = DispatchQueue(label: "codexbar.antigravity.interaction.debug.log")

    static var logFilePath: String {
        self.logFileURL.path
    }

    static func append(_ event: String, metadata: [String: String] = [:]) {
        let timestamp = self.timestampString(Date())
        let normalizedMetadata = metadata
            .mapValues { value in value.replacingOccurrences(of: "\n", with: "\\n") }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let line = normalizedMetadata.isEmpty
            ? "[\(timestamp)] \(event)\n"
            : "[\(timestamp)] \(event) \(normalizedMetadata)\n"
        self.queue.async {
            self.write(line: line)
        }
    }

    private static func write(line: String) {
        let url = self.logFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: url.path) == false {
                try data.write(to: url, options: [.atomic])
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Best-effort debug log. Swallow file write failures.
        }
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static var logFileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        return directory.appendingPathComponent("antigravity-interaction-debug.log")
    }
}
