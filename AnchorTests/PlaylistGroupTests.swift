import Foundation
import Testing
@testable import Anchor

@Suite struct PlaylistGroupTests {
    static func video(_ name: String, group: UUID? = nil, state: DownloadState = .queued, received: Int64 = 0,
                      total: Int64? = 100, speed: Double = 0, age: Double = 0) -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://youtu.be/\(name)")!, fileName: "\(name).mp4",
                                directory: URL(filePath: "/D/List"), category: .video, kind: .media)
        item.groupID = group
        item.groupTitle = group == nil ? nil : "List"
        item.state = state
        item.receivedBytes = received
        item.totalBytes = total
        item.speed = speed
        item.createdAt = Date(timeIntervalSince1970: 1_000_000 - age)
        return item
    }

    @Test func foldsAPlaylistAtItsFirstVideo() {
        let list = UUID(), single = UUID()
        let entries = ListEntry.build([Self.video("a", group: list, age: 0), Self.video("b"), Self.video("c", group: list, age: 1),
                                       Self.video("d", group: single)])
        #expect(entries.count == 3)
        guard case .group(let group) = entries[0] else { Issue.record("expected the playlist first"); return }
        #expect(group.items.map(\.fileName) == ["a.mp4", "c.mp4"])
        guard case .item(let b) = entries[1], case .item(let d) = entries[2] else { Issue.record("expected plain rows"); return }
        #expect(b.fileName == "b.mp4")
        #expect(d.fileName == "d.mp4", "a playlist with one video showing stays a plain row")
    }

    @Test func videosKeepPlaylistOrder() {
        let list = UUID()
        // The first video of a playlist is added with the latest time.
        let entries = ListEntry.build([Self.video("third", group: list, age: 2), Self.video("first", group: list, age: 0),
                                       Self.video("second", group: list, age: 1)])
        guard case .group(let group) = entries.first else { Issue.record("expected a group"); return }
        #expect(group.items.map(\.fileName) == ["first.mp4", "second.mp4", "third.mp4"])
    }

    @Test func summarizesProgress() {
        let list = UUID()
        let group = PlaylistGroup(id: list, title: "List", items: [
            Self.video("a", group: list, state: .completed, received: 100, total: 100),
            Self.video("b", group: list, state: .downloading, received: 50, total: 100, speed: 2_000_000),
            Self.video("c", group: list, state: .queued, received: 0, total: 100),
        ])
        #expect(group.done == 1)
        #expect(group.stage == "Downloading")
        #expect(group.anyRunning)
        #expect(abs(group.fraction - 0.5) < 0.001, "one done, one halfway, one not started")
        #expect(group.detail.hasPrefix("1 of 3 done · "))
        #expect(group.sizeText == Format.progress(150, of: 300))
    }

    @Test func finishedAndFailedStages() {
        let list = UUID()
        let done = PlaylistGroup(id: list, title: "List", items: [Self.video("a", group: list, state: .completed),
                                                                   Self.video("b", group: list, state: .completed)])
        #expect(done.stage == nil)
        #expect(done.detail == "2 videos")
        let failed = PlaylistGroup(id: list, title: "List", items: [Self.video("a", group: list, state: .completed),
                                                                     Self.video("b", group: list, state: .failed("Bot check"))])
        #expect(failed.stage == "Failed")
        #expect(failed.detail == "1 of 2 done · 1 failed")
        let paused = PlaylistGroup(id: list, title: "List", items: [Self.video("a", group: list, state: .paused),
                                                                     Self.video("b", group: list, state: .completed)])
        #expect(paused.stage == "Paused")
    }

    @Test func groupFieldsRoundTrip() throws {
        let item = Self.video("a", group: UUID())
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.groupID == item.groupID)
        #expect(decoded.groupTitle == "List")
    }
}
