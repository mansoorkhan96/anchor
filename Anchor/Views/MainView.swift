import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(CleanupStore.self) private var cleanup
    @State private var filter: SidebarFilter = .all
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(selection: $filter)
                .frame(minWidth: 210)
                .navigationSplitViewColumnWidth(min: 210, ideal: 228, max: 280)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            DownloadListView(filter: filter, sidebarHidden: columns == .detailOnly) {
                withAnimation { columns = .all }
            }
            .background(Color.anchorWindow)
            // Let the header rise into the title bar row so it lines up with the window buttons, as in the design.
            .ignoresSafeArea(.container, edges: .top)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(.anchorAccent)
        .sheet(item: $store.addRequest) { request in
            AddDownloadSheet(request: request)
        }
        .alert("Anchor", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK") { store.alert = nil }
        } message: {
            Text(store.alert ?? "")
        }
        // Opened from elsewhere (e.g. the menu bar): make sure the focused download is visible in the list.
        .onChange(of: store.focusedID) { _, id in
            if let id, let item = store.item(id), !shows(item) { filter = .all }
        }
        // Asked for from elsewhere (the menu bar line or the cleanup banner).
        .onChange(of: store.pendingFilter, initial: true) { _, pending in
            guard let pending else { return }
            filter = pending
            store.pendingFilter = nil
        }
        .onChange(of: filter) { _, filter in
            if filter == .cleanup { cleanup.rescan() }
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func shows(_ item: DownloadItem) -> Bool {
        switch filter {
        case .cleanup: cleanup.candidates[item.id] != nil
        case .archive: item.archivedAt != nil
        default: filter.matches(item)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
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
        return false
    }
}

struct SidebarView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(CleanupStore.self) private var cleanup
    @Binding var selection: SidebarFilter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Library")
                    row(.all, symbol: "tray.full", color: .anchorMuted)
                    row(.downloading, symbol: "arrow.down.circle", color: .anchorAccent)
                    row(.queued, symbol: "list.bullet.indent", color: .anchorPausedInk)
                    row(.completed, symbol: "checkmark.circle", color: .anchorSuccess)
                    if store.count(.failed) > 0 {
                        row(.failed, symbol: "exclamationmark.triangle", color: .anchorDanger)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Kinds")
                    ForEach(FileCategory.allCases) { category in
                        row(.category(category), dot: category.color)
                    }
                    row(.torrents, dot: .anchorTorrent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Tidy")
                    let bytes = cleanup.attentionBytes
                    row(.cleanup, symbol: "sparkles", color: .anchorSuccess, badge: bytes > 0 ? Format.bytes(bytes) : nil)
                    row(.archive, symbol: "archivebox", color: .anchorMuted, badge: "\(store.archivedItems().count)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom) {
            BrowserStatusCard()
                .padding(10)
        }
    }

    private func row(_ filter: SidebarFilter, symbol: String, color: Color, badge: String? = nil) -> some View {
        SidebarRow(title: filter.title, badge: filter.isTidy ? badge : "\(store.count(filter))", isSelected: selection == filter) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
        } action: {
            selection = filter
        }
    }

    private func row(_ filter: SidebarFilter, dot: Color) -> some View {
        SidebarRow(title: filter.title, badge: "\(store.count(filter))", isSelected: selection == filter) {
            Circle().fill(dot).frame(width: 8, height: 8).frame(width: 18)
        } action: {
            selection = filter
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color.anchorMuted)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
    }
}

private struct SidebarRow<Icon: View>: View {
    let title: String
    /// A count, or a size for Cleanup; nil hides it.
    let badge: String?
    let isSelected: Bool
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.anchorAccentInk : Color.anchorText)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white : Color.anchorMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.anchorAccent : .clear, in: .capsule)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(background, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? Color.anchorAccentTint : .clear))
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return .anchorAccentWash }
        return hovering ? Color.anchorText.opacity(0.05) : .clear
    }
}

private struct BrowserStatusCard: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        let on = store.settings.browserIntegration
        VStack(alignment: .leading, spacing: 4) {
            Text("Browser")
                .font(.system(size: 11))
                .foregroundStyle(Color.anchorMuted)
            HStack(spacing: 6) {
                Circle().fill(on ? Color.anchorTorrent : Color.anchorMuted).frame(width: 7, height: 7)
                Text(on ? "Listening for downloads" : "Off · turn on in Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.anchorText)
            }
            if store.settings.speedLimitEnabled {
                Text("Limited to \(Format.speed(Double(store.settings.effectiveSpeedLimit)))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.anchorPausedInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.anchorWindow, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.anchorLine))
    }
}
