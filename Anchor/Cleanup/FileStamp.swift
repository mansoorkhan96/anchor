import Foundation

/// Identity of a file on disk. Two stamps are equal only if every field matches.
/// A same-volume rename keeps every field; rewriting the file changes at least one.
struct FileStamp: Codable, Hashable, Sendable {
    var volume: String
    var fileID: UInt64
    var created: Date
    var modified: Date
    var size: Int64

    /// nil if the path is missing, is a symlink (not followed), is not a regular file, or any field can't be read.
    static func read(_ url: URL) -> FileStamp? {
        let path = url.path
        // attributesOfItem describes a final symlink itself rather than its target (lstat semantics).
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let fileID = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let created = attrs[.creationDate] as? Date,
              let modified = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let volume = volumeUUID(of: url) else { return nil }
        return FileStamp(volume: volume, fileID: fileID, created: created, modified: modified, size: size)
    }

    /// The volume UUID of an existing file or folder, read fresh (a new URL has no cached resource values).
    static func volumeUUID(of url: URL) -> String? {
        try? URL(filePath: url.path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }
}

/// Cached result of looking inside an installer.
struct InstallerInfo: Codable, Hashable, Sendable {
    /// The file that was inspected; it is inspected again if the current stamp differs.
    var stamp: FileStamp
    /// nil when inspection could not find exactly one app.
    var bundleID: String?
    var version: String?
    /// Inspection failed (encrypted, license prompt, timeout, unreadable).
    var failed: Bool
}

/// Recorded and saved before an archive or restore move, cleared after; used for crash recovery.
struct PendingMove: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case archive, restore }
    var kind: Kind
    /// Full source path.
    var from: String
    /// Full target path.
    var to: String
    /// Identity of the file being moved.
    var stamp: FileStamp
}
