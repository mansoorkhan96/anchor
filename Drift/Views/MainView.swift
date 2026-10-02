import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(DownloadStore.self) private var store
    @State private var filter: SidebarFilter = .all

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView(selection: $filter)
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            DownloadListView(filter: filter)
        }
        .tint(.driftAccent)
        .sheet(item: $store.addRequest) { request in
            AddDownloadSheet(request: request)
        }
        .alert("Drift", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK") { store.alert = nil }
        } message: {
            Text(store.alert ?? "")
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if url.isFileURL {
                            AppRouter.shared.handle(url)
                        } else {
                            store.addRequest = AddRequest(url: url.absoluteString)
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}

struct SidebarView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var selection: SidebarFilter

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                row(.all, symbol: "tray.full")
                row(.downloading, symbol: "arrow.down.circle")
                row(.queued, symbol: "list.bullet.indent")
                row(.completed, symbol: "checkmark.circle")
                if store.count(.failed) > 0 {
                    row(.failed, symbol: "exclamationmark.triangle")
                }
            }
            Section("Kinds") {
                ForEach(FileCategory.allCases) { category in
                    kindRow(.category(category), color: category.color)
                }
                kindRow(.torrents, color: .driftTorrent)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarStatus()
                .padding(10)
        }
    }

    private func row(_ filter: SidebarFilter, symbol: String) -> some View {
        Label {
            HStack {
                Text(filter.title)
                Spacer()
                Text("\(store.count(filter))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(filter)
    }

    private func kindRow(_ filter: SidebarFilter, color: Color) -> some View {
        Label {
            HStack {
                Text(filter.title)
                Spacer()
                Text("\(store.count(filter))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } icon: {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .tag(filter)
    }
}

private struct SidebarStatus: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Speed limit")
                Spacer()
                Text(store.settings.speedLimitKB == 0 ? "Unlimited" : Format.speed(Double(store.settings.speedLimitKB * 1000)))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            HStack {
                Text("Browser")
                Spacer()
                Text(store.settings.browserIntegration ? "Listening" : "Off")
                    .foregroundStyle(store.settings.browserIntegration ? Color.driftSuccess : .secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}
