import Foundation

/// The single owner of writes to the library file. Writes run in order on a private serial queue, and a write
/// with a lower sequence number than one already written is skipped, so an old state can never land last.
/// A class with a queue rather than an actor so termination can drain it synchronously.
final class LibraryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.mansoor.Anchor.library-writer", qos: .utility)
    private let url: URL
    private let write: @Sendable (Data, URL) throws -> Void
    /// Only touched on `queue`.
    private var lastWritten = Int.min

    init(url: URL, write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url
        self.write = write
    }

    /// Writes in the background and reports whether `data` (or something newer) is on disk.
    func enqueue(_ data: Data, seq: Int, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { completion(self.perform(data, seq: seq)) }
    }

    /// Waits for every earlier queued write, then writes. Used on quit.
    func writeNowSync(_ data: Data, seq: Int) -> Bool {
        queue.sync { perform(data, seq: seq) }
    }

    private func perform(_ data: Data, seq: Int) -> Bool {
        // A newer state is already on disk.
        guard seq > lastWritten else { return true }
        do {
            try write(data, url)
            lastWritten = seq
            return true
        } catch {
            return false
        }
    }
}

/// Dirty tracking by generations: every change bumps `changeGeneration`, a save records the generation it encoded,
/// and the store is dirty while a change is newer than the newest successful save. An older save that finishes
/// late can never hide a newer change.
struct SaveTracker: Sendable {
    struct Save: Sendable { var seq: Int; var generation: Int }

    private(set) var changeGeneration = 0
    private(set) var savedGeneration = 0
    private var nextSeq = 0

    var isDirty: Bool { changeGeneration > savedGeneration }

    mutating func changed() { changeGeneration += 1 }

    mutating func beginSave() -> Save {
        nextSeq += 1
        return Save(seq: nextSeq, generation: changeGeneration)
    }

    mutating func finished(_ save: Save, success: Bool) {
        if success { savedGeneration = max(savedGeneration, save.generation) }
    }
}
