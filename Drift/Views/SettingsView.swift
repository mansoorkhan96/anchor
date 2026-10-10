import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement
import SafariServices

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, speed, browser, cleanup, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .speed: "Speed"
        case .browser: "Browser"
        case .cleanup: "Cleanup"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Where downloads go and how Drift behaves."
        case .speed: "How hard Drift pushes your connection."
        case .browser: "Send downloads from Safari, Chrome, Arc, Brave and Edge to Drift."
        case .cleanup: "Files show up in Cleanup when Drift has seen no use of them for this long. Nothing is removed until you choose to."
        case .about: ""
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .speed: "gauge.with.dots.needle.67percent"
        case .browser: "globe"
        case .cleanup: "sparkles"
        case .about: "info"
        }
    }

    var badge: Color {
        switch self {
        case .general: .adaptive(light: 0x5E5E63, dark: 0x6E6E73)
        case .speed: .driftAccent
        case .browser: .driftAccentInk
        case .cleanup: .adaptive(light: 0x46902E, dark: 0x5BA845)
        case .about: .adaptive(light: 0x737378, dark: 0x7C7C81)
        }
    }
}

struct SettingsView: View {
    @Environment(DownloadStore.self) private var store
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsSection.allCases) { item in
                    SectionButton(section: item, isSelected: item == section) { section = item }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .frame(width: 210)
            .frame(maxHeight: .infinity)
            .background(Color.driftCard)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.driftLine).frame(width: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if section != .about {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color.driftText)
                            Text(section.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.driftMuted)
                        }
                    }
                    switch section {
                    case .general: GeneralPage()
                    case .speed: SpeedPage()
                    case .browser: BrowserPage()
                    case .cleanup: CleanupPage()
                    case .about: AboutPage()
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.driftWindow)
        }
        .frame(width: 760, height: 740)
        .tint(.driftAccent)
        .onAppear(perform: openRequestedPage)
        .onChange(of: store.settings.requestedSettingsPage) { openRequestedPage() }
    }

    /// Another part of the app (e.g. the empty Cleanup list) asked for a specific page.
    private func openRequestedPage() {
        guard let page = store.settings.requestedSettingsPage else { return }
        store.settings.requestedSettingsPage = nil
        if let requested = SettingsSection(rawValue: page) { section = requested }
    }
}

private struct SectionButton: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(section.badge, in: .rect(cornerRadius: 6))
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.driftAccentInk : Color.driftText)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(isSelected ? Color.driftAccentWash : hovering ? Color.driftText.opacity(0.05) : .clear,
                        in: .rect(cornerRadius: 9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Building blocks

/// Borderless soft-gray card holding rows separated by hairlines.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Color.driftCard, in: .rect(cornerRadius: 14))
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var divider = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.driftText)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.driftMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Color.driftLine).frame(height: 1) }
        }
    }
}

// MARK: - Pages

private struct GeneralPage: View {
    @Environment(DownloadStore.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = store.settings
        VStack(spacing: 16) {
            SettingsCard {
                SettingsRow(title: "Save downloads to", detail: displayPath(settings.downloadFolder), divider: true) {
                    Button("Change…", action: chooseFolder).buttonStyle(.driftSecondary)
                }
                SettingsRow(title: "Sort into category folders", detail: "Video, Music, Apps and others get their own subfolder", divider: true) {
                    DriftSwitch(isOn: $settings.categorySubfolders, label: "Sort into category folders")
                }
                SettingsRow(title: "If the file already exists", detail: "Ask each time, or always rename or overwrite") {
                    DriftSegmented(options: ExistingFileAction.allCases, selection: $settings.existingFileAction, title: \.title,
                                   minWidth: 0, symbol: { action in
                                       switch action {
                                       case .ask: "questionmark.bubble"
                                       case .rename: "character.cursor.ibeam"
                                       case .overwrite: "arrow.triangle.2.circlepath"
                                       }
                                   })
                }
            }
            SettingsCard {
                SettingsRow(title: "Open Drift at login", detail: "Stays in the menu bar so browser downloads always work", divider: true) {
                    DriftSwitch(isOn: $launchAtLogin, label: "Open Drift at login")
                }
                SettingsRow(title: "Keep Mac awake while downloading", detail: "Stops idle sleep until downloads finish; the screen can still turn off", divider: true) {
                    DriftSwitch(isOn: $settings.keepAwake, label: "Keep Mac awake while downloading")
                }
                SettingsRow(title: "Notify when downloads finish", detail: "Also tells you when a download fails", divider: true) {
                    DriftSwitch(isOn: $settings.notifications, label: "Notify when downloads finish")
                }
                SettingsRow(title: "Offer to download copied links", detail: "Links to files and magnet links") {
                    DriftSwitch(isOn: $settings.clipboardMonitoring, label: "Offer to download copied links")
                }
            }
            SettingsCard {
                SettingsRow(title: "Show speed bar", detail: "Live speed and time left above the download list") {
                    DriftSwitch(isOn: $settings.showSpeedStrip, label: "Show speed bar")
                }
            }
            SettingsCard {
                SettingsRow(title: "Show Drift in the menu bar", detail: "Live speed and recent downloads, one click away", divider: true) {
                    DriftSwitch(isOn: $settings.showMenuBarIcon, label: "Show Drift in the menu bar")
                }
                SettingsRow(title: "Recent downloads in menu bar", detail: "How many show in the menu bar list") {
                    NumberStepper(value: $settings.menuBarCount, range: 3...15)
                }
            }
        }
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.settings.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { store.settings.downloadFolder = url }
    }
}

private struct SpeedPage: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        VStack(spacing: 16) {
            SpeedLimitCard()
            SettingsCard {
                SettingsRow(title: "Connections per download", detail: "More connections are faster on most servers", divider: true) {
                    DriftSegmented(options: [1, 4, 8, 16, 32], selection: $settings.connections, title: { "\($0)" }, minWidth: 34)
                }
                SettingsRow(title: "Simultaneous downloads", detail: "The rest wait in the queue") {
                    NumberStepper(value: $settings.maxConcurrent, range: 1...10)
                        .onChange(of: settings.maxConcurrent) { store.schedule() }
                }
            }
            TorrentCard()
        }
    }
}

/// Torrent seeding: share back after downloading, until a ratio, with an upload cap.
private struct TorrentCard: View {
    @Environment(DownloadStore.self) private var store
    private static let uploadOptions = [0, 32, 100, 500, 1_000, 5_000]

    var body: some View {
        @Bindable var settings = store.settings
        SettingsCard {
            SettingsRow(title: "Upload limit", detail: uploadDetail(settings.uploadLimitKB), divider: true) {
                Menu {
                    ForEach(Self.uploadOptions, id: \.self) { kb in
                        Button(uploadTitle(kb)) { settings.uploadLimitKB = kb }
                    }
                    Divider()
                    Button(uploadTitle(-1)) { settings.uploadLimitKB = -1 }
                } label: {
                    HStack(spacing: 6) {
                        Text(uploadTitle(settings.uploadLimitKB))
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(settings.uploadLimitKB < 0 ? Color.driftPausedInk : Color.driftText)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.driftWindow, in: .rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.driftLine))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            SettingsRow(title: "Seed torrents after downloading",
                        detail: "Keep sharing finished torrents with other people", divider: settings.seedTorrents) {
                DriftSwitch(isOn: $settings.seedTorrents, label: "Seed torrents after downloading")
            }
            if settings.seedTorrents {
                SettingsRow(title: "Stop seeding at ratio",
                            detail: "Uploaded ÷ size. 1.0 means you've shared back as much as you took") {
                    RatioStepper(value: $settings.seedRatio)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: settings.seedTorrents)
        .onChange(of: settings.seedTorrents) { store.applySeeding() }
        .onChange(of: settings.seedRatio) { store.applySeeding() }
        .onChange(of: settings.uploadLimitKB) { store.applySeeding() }
    }

    private func uploadTitle(_ kb: Int) -> String {
        kb < 0 ? "Stop uploading" : kb == 0 ? "Unlimited" : Format.speed(Double(kb * 1000))
    }

    private func uploadDetail(_ kb: Int) -> String {
        if kb < 0 { return "Downloads may be slower: peers favor people who share back" }
        if kb == 0 { return "Torrents share with other people while downloading and seeding" }
        return "Caps upload while downloading and seeding. A small cap keeps downloads fast"
    }
}

private struct RatioStepper: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 0) {
            step("minus") { value = max(0.5, value - 0.5) }
            Text(String(format: "%.1f", value))
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.driftText)
                .frame(width: 42, height: 30)
                .overlay(alignment: .leading) { Rectangle().fill(Color.driftLine).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(Color.driftLine).frame(width: 1) }
            step("plus") { value = min(10, value + 0.5) }
        }
        .background(Color.driftWindow, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.driftLine))
    }

    private func step(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.driftMuted2)
                .frame(width: 32, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Speed limit: an on/off switch, presets, and a custom value in KB/s or MB/s.
private struct SpeedLimitCard: View {
    @Environment(DownloadStore.self) private var store
    @State private var customSelected = false
    @State private var customText = ""
    @State private var unit: Unit = .mb
    @FocusState private var customFocused: Bool

    enum Unit: String, CaseIterable { case kb = "KB/s", mb = "MB/s" }

    private static let presets: [(label: String, kb: Int)] = [
        ("512 KB/s", 512), ("1 MB/s", 1000), ("2 MB/s", 2000), ("5 MB/s", 5000), ("10 MB/s", 10_000),
    ]

    var body: some View {
        @Bindable var settings = store.settings
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Limit download speed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.driftText)
                    Text("Applies to all downloads, including torrents")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.driftMuted)
                }
                Spacer()
                DriftSwitch(isOn: $settings.speedLimitEnabled, label: "Limit download speed")
            }

            if settings.speedLimitEnabled {
                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.kb) { preset in
                        chip(preset.label, on: !customSelected && settings.speedLimitKB == preset.kb) {
                            customSelected = false
                            settings.speedLimitKB = preset.kb
                        }
                    }
                    chip("Custom…", on: customSelected) {
                        customSelected = true
                        loadCustom()
                        customFocused = true
                    }
                }

                if customSelected {
                    HStack(spacing: 10) {
                        Text("Custom limit")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.driftMuted2)
                            .frame(width: 86, alignment: .leading)
                        TextField("2.5", text: $customText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.driftText)
                            .focused($customFocused)
                            .frame(width: 70)
                            .fieldChrome(focused: customFocused, height: 34)
                            .onChange(of: customText) { applyCustom() }
                        DriftSegmented(options: Unit.allCases, selection: $unit, title: \.rawValue, minWidth: 48)
                            .onChange(of: unit) { applyCustom() }
                    }
                }

                Text("Drift will stay under \(Text(Format.speed(Double(settings.effectiveSpeedLimit))).bold().foregroundStyle(Color.driftText)) across all downloads.")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.driftMuted)
            } else {
                Text("Downloads use your full connection.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.driftMuted)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color.driftCard, in: .rect(cornerRadius: 14))
        .animation(.snappy(duration: 0.2), value: settings.speedLimitEnabled)
        .animation(.snappy(duration: 0.2), value: customSelected)
        .onAppear {
            customSelected = !Self.presets.contains { $0.kb == settings.speedLimitKB }
            loadCustom()
        }
        .onChange(of: settings.speedLimitEnabled) { store.applySpeedLimit() }
        .onChange(of: settings.speedLimitKB) { store.applySpeedLimit() }
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.driftAccentInk : Color.driftText.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(on ? Color.driftAccentWash : Color.driftWindow, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.driftAccentRing : Color.driftLine))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Shows the current limit in the custom field, in MB/s when it divides cleanly enough.
    private func loadCustom() {
        let kb = store.settings.speedLimitKB
        if kb >= 1000 {
            unit = .mb
            customText = String(format: "%g", Double(kb) / 1000)
        } else {
            unit = .kb
            customText = "\(kb)"
        }
    }

    private func applyCustom() {
        let text = customText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(text), value > 0 else { return }
        let kb = Int((unit == .mb ? value * 1000 : value).rounded())
        store.settings.speedLimitKB = max(1, kb)
    }
}

private struct NumberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", label: "Fewer") { value = max(range.lowerBound, value - 1) }
                .disabled(value <= range.lowerBound)
            Text("\(value)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.driftText)
                .frame(width: 36, height: 30)
                .overlay(alignment: .leading) { Rectangle().fill(Color.driftLine).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(Color.driftLine).frame(width: 1) }
            stepButton("plus", label: "More") { value = min(range.upperBound, value + 1) }
                .disabled(value >= range.upperBound)
        }
        .background(Color.driftWindow, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.driftLine))
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.driftMuted2)
                .frame(width: 32, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct CleanupPage: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        let categories = FileCategory.allCases
        VStack(alignment: .leading, spacing: 16) {
            Text("Clean up after")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.driftMuted)
                .padding(.horizontal, 4)
                .padding(.bottom, -8)
            SettingsCard {
                ForEach(categories) { category in
                    SettingsRow(title: category.title, divider: category != categories.last) {
                        DaysMenu(days: Binding(get: { settings.cleanupDays(for: category) },
                                               set: { settings.cleanupDays[category] = $0 > 0 ? $0 : nil }))
                    }
                }
            }
            SettingsCard {
                SettingsRow(title: "Archive installers once installed",
                            detail: "Moves a dmg to Downloads/Drift Archive once the same or a newer version of its app is installed. Restore puts it back.") {
                    DriftSwitch(isOn: $settings.archiveInstallers, label: "Archive installers once installed")
                }
            }
        }
    }
}

/// Never, or a number of days without recorded use.
private struct DaysMenu: View {
    static let options = [0, 7, 14, 30, 60, 90]
    @Binding var days: Int

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.self) { option in
                Button {
                    days = option
                } label: {
                    if option == days { Label(title(option), systemImage: "checkmark") } else { Text(title(option)) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(days))
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(days == 0 ? Color.driftMuted2 : Color.driftText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.driftWindow, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.driftLine))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Clean up after")
    }

    private func title(_ days: Int) -> String { days == 0 ? "Never" : "\(days) days" }
}

private struct BrowserPage: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        VStack(spacing: 16) {
            DefaultAppCard()
            SettingsCard {
                SettingsRow(title: "Take over browser downloads",
                            detail: settings.browserIntegration ? "Listening on 127.0.0.1:47821" : "Off", divider: true) {
                    DriftSwitch(isOn: $settings.browserIntegration, label: "Take over browser downloads")
                }
                SettingsRow(title: "Confirm each download", detail: "Show the New Download window before starting") {
                    DriftSwitch(isOn: $settings.confirmBrowserDownloads, label: "Confirm each download")
                }
                .opacity(settings.browserIntegration ? 1 : 0.45)
                .disabled(!settings.browserIntegration)
            }
            SettingsCard {
                SettingsRow(title: "Safari extension",
                            detail: "Turn on Drift in Safari's Extensions settings. Unsigned builds also need Develop > Allow Unsigned Extensions.",
                            divider: true) {
                    Button("Open Safari…", action: openSafariExtension).buttonStyle(.driftSecondary)
                }
                SettingsRow(title: "Chrome, Arc, Brave and Edge extension",
                            detail: "In chrome://extensions turn on Developer mode, choose Load unpacked, and pick the drift-browser-extension folder.") {}
            }
        }
    }

    private func openSafariExtension() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: "dev.mansoor.Drift.SafariExtension") { _ in }
    }
}

/// Shows which app opens magnet links and .torrent files, and lets Drift take them over.
private struct DefaultAppCard: View {
    @State private var magnetApp: URL?
    @State private var torrentApp: URL?
    @State private var working = false

    private static let torrentType = UTType("org.bittorrent.torrent") ?? UTType(filenameExtension: "torrent")!
    private var drift: URL { Bundle.main.bundleURL.standardizedFileURL }
    private var isDefault: Bool { magnetApp?.standardizedFileURL == drift && torrentApp?.standardizedFileURL == drift }

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Open magnet links and .torrent files",
                        detail: isDefault ? "Drift opens them" : "Currently: \(describe())") {
                if isDefault {
                    Chip(text: "Drift is the default", ink: .driftSuccess, wash: .driftSuccessWash)
                } else {
                    Button(working ? "Waiting…" : "Make Drift the Default", action: makeDefault)
                        .buttonStyle(.driftPrimary)
                        .disabled(working)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func describe() -> String {
        let names = Set([magnetApp, torrentApp].map { $0.map { $0.deletingPathExtension().lastPathComponent } ?? "nothing" })
        return names.sorted().joined(separator: " and ")
    }

    private func refresh() {
        let ws = NSWorkspace.shared
        magnetApp = ws.urlForApplication(toOpen: URL(string: "magnet:?xt=urn:btih:0")!)
        torrentApp = ws.urlForApplication(toOpen: Self.torrentType)
    }

    /// macOS asks the user to confirm each change.
    private func makeDefault() {
        working = true
        let ws = NSWorkspace.shared
        let app = drift
        ws.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet") { _ in
            ws.setDefaultApplication(at: app, toOpen: Self.torrentType) { _ in }
        }
        // The completion handlers can lag behind macOS's confirmation prompts, so re-check until it sticks.
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                refresh()
                if isDefault { break }
            }
            working = false
        }
    }
}

private struct AboutPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Drift")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.driftText)
            Text(version)
                .font(.system(size: 12))
                .foregroundStyle(Color.driftMuted)
            Text("Fast, segmented downloads for macOS. Torrents powered by aria2.")
                .font(.system(size: 12))
                .foregroundStyle(Color.driftMuted)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
