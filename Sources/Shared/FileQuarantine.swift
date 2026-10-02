import Foundation

enum FileQuarantine {
    /// Moves an unreadable file aside (`name.corrupt-<timestamp>.ext`) so the next save cannot
    /// destroy it. Returns the new location, or nil if the file could not be moved.
    @discardableResult
    static func moveAside(_ url: URL, now: Date = Date()) -> URL? {
        let stamp = Int(now.timeIntervalSince1970)
        let base = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(base).corrupt-\(stamp)")
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }
}
