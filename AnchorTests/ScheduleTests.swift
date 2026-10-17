import Foundation
import Carbon.HIToolbox
import Testing
@testable import Anchor

@Suite struct DownloadWindowTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 15 Oct 2026 at hh:mm UTC.
    static func at(_ hour: Int, _ minute: Int = 0, day: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func sameDayWindow() {
        let window = DownloadWindow(start: 9 * 60, end: 17 * 60)
        #expect(!window.contains(Self.at(8, 59), calendar: Self.calendar))
        #expect(window.contains(Self.at(9), calendar: Self.calendar), "opens on the minute")
        #expect(window.contains(Self.at(16, 59), calendar: Self.calendar))
        #expect(!window.contains(Self.at(17), calendar: Self.calendar), "closes on the minute")
    }

    @Test func overnightWindow() {
        let window = DownloadWindow(start: 23 * 60, end: 7 * 60)
        #expect(window.contains(Self.at(23, 30), calendar: Self.calendar))
        #expect(window.contains(Self.at(0), calendar: Self.calendar))
        #expect(window.contains(Self.at(6, 59), calendar: Self.calendar))
        #expect(!window.contains(Self.at(7), calendar: Self.calendar))
        #expect(!window.contains(Self.at(12), calendar: Self.calendar))
    }

    @Test func sameStartAndEndIsAllDay() {
        let window = DownloadWindow(start: 60, end: 60)
        for hour in [0, 1, 12, 23] {
            #expect(window.contains(Self.at(hour), calendar: Self.calendar))
        }
    }

    @Test func nextStartIsLaterTodayOrTomorrow() {
        let window = DownloadWindow(start: 60, end: 7 * 60)
        #expect(window.nextStart(after: Self.at(0, 30), calendar: Self.calendar) == Self.at(1))
        #expect(window.nextStart(after: Self.at(1), calendar: Self.calendar) == Self.at(1, day: 16), "not the minute it opens")
        #expect(window.nextStart(after: Self.at(22), calendar: Self.calendar) == Self.at(1, day: 16))
    }

    @Test func minutesWrapIntoOneDay() {
        #expect(DownloadWindow(start: -30, end: 24 * 60 + 15) == DownloadWindow(start: 23 * 60 + 30, end: 15))
    }

    @Test func queueRunsInsideTheWindowOrWhenStartedByHand() {
        let window = DownloadWindow(start: 60, end: 7 * 60)
        let night = Self.at(2)
        let day = Self.at(14)
        func runs(_ date: Date, enabled: Bool = true, bypass: Date? = nil) -> Bool {
            DownloadStore.queueRuns(at: date, enabled: enabled, window: window, bypassUntil: bypass, calendar: Self.calendar)
        }
        #expect(runs(day, enabled: false), "no schedule: always")
        #expect(runs(night))
        #expect(!runs(day))
        #expect(runs(day, bypass: Self.at(1, day: 16)), "Start Now runs it until the window opens")
        #expect(!runs(day, bypass: Self.at(13)), "an old Start Now has run out")
    }
}

@Suite struct ShortcutsTests {
    @Test func statusSummary() {
        #expect(DownloadStatusIntent.summary(active: 0, queued: 0, speed: 0) == "Nothing is downloading")
        #expect(DownloadStatusIntent.summary(active: 0, queued: 3, speed: 0) == "3 waiting")
        let busy = DownloadStatusIntent.summary(active: 2, queued: 1, speed: 5_200_000)
        #expect(busy.hasPrefix("2 downloading at "))
        #expect(busy.hasSuffix(", 1 waiting"))
    }
}

@Suite struct GlobalShortcutTests {
    @Test func displaysInMenuOrder() {
        let combo = KeyCombo(keyCode: 9, modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), key: "V")
        #expect(combo.display == "⌃⌥⇧⌘V")
    }

    @Test func needsAStrongModifierUnlessFunctionKey() {
        #expect(!KeyCombo(keyCode: 9, modifiers: 0, key: "V").isUsable, "a plain letter would fire while typing")
        #expect(!KeyCombo(keyCode: 9, modifiers: UInt32(shiftKey), key: "V").isUsable)
        #expect(KeyCombo(keyCode: 9, modifiers: UInt32(controlKey), key: "V").isUsable)
        #expect(KeyCombo(keyCode: UInt32(kVK_F5), modifiers: 0, key: "F5").isUsable)
    }

    @Test func namesSpecialKeys() {
        #expect(KeyCombo.name(keyCode: UInt32(kVK_Space), characters: " ") == "Space")
        #expect(KeyCombo.name(keyCode: UInt32(kVK_F12), characters: nil) == "F12")
        #expect(KeyCombo.name(keyCode: 9, characters: "v") == "V")
        #expect(KeyCombo.name(keyCode: 999, characters: "\u{1}") == nil)
    }

    @Test func savesAndLoads() throws {
        let defaults = try #require(UserDefaults(suiteName: "anchor-shortcut-tests-\(UUID().uuidString)"))
        let combo = KeyCombo(keyCode: 9, modifiers: UInt32(controlKey | optionKey), key: "V")
        GlobalShortcuts.save([.addFromClipboard: combo], to: defaults)
        #expect(GlobalShortcuts.load(from: defaults) == [.addFromClipboard: combo])
        // A combination that could fire while typing (from an older or edited file) isn't loaded.
        GlobalShortcuts.save([.pauseAll: KeyCombo(keyCode: 9, modifiers: 0, key: "V")], to: defaults)
        #expect(GlobalShortcuts.load(from: defaults).isEmpty)
    }

    @Test func everyActionHasATitle() {
        for action in GlobalShortcutAction.allCases {
            #expect(!action.title.isEmpty)
        }
    }
}
