import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Integration", systemImage: "puzzlepiece.extension") { IntegrationSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(DownloadStore.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section {
                LabeledContent("Download folder") {
                    HStack {
                        Text(settings.downloadFolder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            panel.directoryURL = settings.downloadFolder
                            if panel.runModal() == .OK, let url = panel.url { settings.downloadFolder = url }
                        }
                    }
                }
                Toggle("Sort into category folders (Video, Music, Apps…)", isOn: $settings.categorySubfolders)
            }
            Section {
                Stepper("Simultaneous downloads: \(settings.maxConcurrent)", value: $settings.maxConcurrent, in: 1...10)
                Picker("Connections per download", selection: $settings.connections) {
                    ForEach([1, 2, 4, 8, 12, 16, 24, 32], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Speed limit", selection: $settings.speedLimitKB) {
                    Text("Unlimited").tag(0)
                    ForEach([256, 512, 1024, 2048, 5120, 10240, 20480, 51200], id: \.self) { kb in
                        Text(Format.speed(Double(kb * 1000))).tag(kb)
                    }
                }
                .onChange(of: settings.speedLimitKB) { store.applySpeedLimit() }
            }
            Section {
                Toggle("Notify when downloads finish", isOn: $settings.notifications)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

private struct IntegrationSettings: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("Clipboard") {
                Toggle("Offer to download links I copy", isOn: $settings.clipboardMonitoring)
            }
            Section("Browser") {
                Toggle("Take over browser downloads", isOn: $settings.browserIntegration)
                Toggle("Confirm each browser download", isOn: $settings.confirmBrowserDownloads)
                    .disabled(!settings.browserIntegration)
                LabeledContent("Chrome, Arc, Brave, Edge") {
                    Button("Install Extension…", action: revealExtension)
                }
                Text("Open chrome://extensions, turn on Developer mode, click \"Load unpacked\" and pick the folder Drift shows you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func revealExtension() {
        guard let source = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) else { return }
        let target = AppPaths.support.appending(path: "BrowserExtension", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: source, to: target)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}
