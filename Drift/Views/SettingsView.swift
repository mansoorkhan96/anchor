import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Speed", systemImage: "gauge.with.dots.needle.67percent") { SpeedSettings() }
            Tab("Integration", systemImage: "puzzlepiece.extension") { IntegrationSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 560)
        .tint(.driftAccent)
    }
}

/// System Settings style row: colored icon badge, title and optional detail, control on the right.
private struct SettingRow<Control: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var detail: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(color.gradient, in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 2)
    }
}

private struct GeneralSettings: View {
    @Environment(DownloadStore.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("Downloads") {
                SettingRow(symbol: "folder.fill", color: .blue, title: "Save downloads to",
                           detail: displayPath(settings.downloadFolder)) {
                    Button("Change…", action: chooseFolder)
                        .buttonStyle(.driftSecondary)
                }
                SettingRow(symbol: "square.grid.2x2.fill", color: .orange, title: "Sort into category folders",
                           detail: "Video, Music, Apps and others get their own subfolder") {
                    Toggle("", isOn: $settings.categorySubfolders).labelsHidden().toggleStyle(.switch)
                }
            }
            Section("App") {
                SettingRow(symbol: "bell.badge.fill", color: .red, title: "Notify when downloads finish") {
                    Toggle("", isOn: $settings.notifications).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(symbol: "power", color: .green, title: "Open Drift at login",
                           detail: "Stays in the menu bar so browser downloads always work") {
                    Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 400)
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

private struct SpeedSettings: View {
    @Environment(DownloadStore.self) private var store

    private static let limits = [0, 256, 512, 1024, 2048, 5120, 10240, 20480, 51200]

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section {
                SettingRow(symbol: "arrow.down.circle.fill", color: .driftAccent, title: "Simultaneous downloads",
                           detail: "Others wait in the queue") {
                    HStack(spacing: 8) {
                        Text("\(settings.maxConcurrent)")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .frame(minWidth: 18, alignment: .trailing)
                        Stepper("Simultaneous downloads", value: $settings.maxConcurrent, in: 1...10)
                            .labelsHidden()
                    }
                }
                SettingRow(symbol: "point.3.connected.trianglepath.dotted", color: .teal, title: "Connections per download",
                           detail: "More connections are faster on most servers") {
                    Picker("", selection: $settings.connections) {
                        ForEach([1, 4, 8, 16, 32], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
            Section {
                SettingRow(symbol: "speedometer", color: .orange, title: "Speed limit",
                           detail: "Applies to all downloads, including torrents") {
                    Picker("", selection: $settings.speedLimitKB) {
                        ForEach(Self.limits, id: \.self) { kb in
                            Text(kb == 0 ? "Unlimited" : Format.speed(Double(kb * 1000))).tag(kb)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: settings.speedLimitKB) { store.applySpeedLimit() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 300)
    }
}

private struct IntegrationSettings: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("Browser") {
                SettingRow(symbol: "globe", color: .blue, title: "Take over browser downloads",
                           detail: settings.browserIntegration ? "Listening on 127.0.0.1:47821" : "Off") {
                    Toggle("", isOn: $settings.browserIntegration).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(symbol: "checkmark.bubble.fill", color: .indigo, title: "Confirm each download",
                           detail: "Show the New Download window before starting") {
                    Toggle("", isOn: $settings.confirmBrowserDownloads).labelsHidden().toggleStyle(.switch)
                }
                .disabled(!settings.browserIntegration)
                SettingRow(symbol: "puzzlepiece.extension.fill", color: .purple, title: "Chrome, Arc, Brave, Edge",
                           detail: "In chrome://extensions turn on Developer mode, choose Load unpacked, and pick the folder Drift shows you") {
                    Button("Install…", action: revealExtension)
                        .buttonStyle(.driftSecondary)
                }
            }
            Section("Clipboard") {
                SettingRow(symbol: "doc.on.clipboard.fill", color: .gray, title: "Offer to download copied links",
                           detail: "Links to files and magnet links") {
                    Toggle("", isOn: $settings.clipboardMonitoring).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 470)
    }

    private func revealExtension() {
        guard let source = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) else { return }
        let target = AppPaths.support.appending(path: "BrowserExtension", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: source, to: target)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

private struct AboutSettings: View {
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
                .font(.system(size: 22, weight: .semibold))
            Text(version)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Fast, segmented downloads for macOS. Torrents powered by aria2.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }
}
