import SwiftUI

struct AddDownloadSheet: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: AddRequest
    /// Set when shown in the floating panel instead of as a sheet.
    var onClose: (() -> Void)?

    @State private var address = ""
    @State private var fileName = ""
    @State private var nameEdited = false
    @State private var autoName = ""
    @State private var probe: ProbeResult?
    @State private var probing = false
    @State private var probeError: String?
    @State private var category: FileCategory = .other
    @State private var folder: URL?
    @State private var openWhenDone = false
    @State private var fromClipboard = false
    // Torrents: added to aria2 paused so the file list can be reviewed first.
    @State private var prepared: PreparedTorrent?
    @State private var preparing = false
    @State private var prepareError: String?
    @State private var localTorrent: URL?
    @State private var torrentPriority: Priority = .normal
    @State private var added = false
    @FocusState private var addressFocused: Bool

    private var url: URL? {
        URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.scheme == nil ? nil : $0 }
    }
    private var isMagnet: Bool { url?.scheme?.lowercased() == "magnet" }
    private var isTorrent: Bool {
        isMagnet || url?.pathExtension.lowercased() == "torrent" || probe?.mimeType == "application/x-bittorrent"
    }
    private var targetFolder: URL { folder ?? store.settings.folder(for: category) }
    private var canAdd: Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return ["http", "https", "magnet", "file"].contains(scheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.driftAccent)
                    .frame(width: 38, height: 38)
                    .background(Color.driftAccentWash, in: .rect(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.driftAccentTint))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Download")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.driftText)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.driftMuted)
                }
            }

            field("Link") {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.driftMuted)
                    TextField("https://… or magnet:?…", text: $address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($addressFocused)
                        .onSubmit { if canAdd { add(startNow: true) } }
                    if address.isEmpty {
                        Button("Paste") {
                            address = NSPasteboard.general.string(forType: .string)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.driftAccentInk)
                    } else {
                        Button {
                            address = ""
                            addressFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.driftMuted.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear link")
                    }
                }
                .fieldChrome(focused: addressFocused)
            }

            if url == nil {
                Text("File details appear here once you paste a link.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.driftMuted)
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.driftLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    )
            } else {
                fileCard
            }

            if let files = prepared?.files {
                TorrentFileList(files: files, maxHeight: 220,
                                onInclude: { index, included in
                                    guard var p = prepared, let i = p.files.firstIndex(where: { $0.index == index }) else { return }
                                    if !included, p.files.filter(\.included).count <= 1 { return }
                                    p.files[i].included = included
                                    prepared = p
                                },
                                onPriority: { index, priority in
                                    guard var p = prepared, let i = p.files.firstIndex(where: { $0.index == index }) else { return }
                                    p.files[i].priority = priority
                                    prepared = p
                                },
                                onAll: { included in
                                    guard var p = prepared else { return }
                                    for i in p.files.indices { p.files[i].included = included || i == 0 }
                                    prepared = p
                                })
            }

            HStack(alignment: .top, spacing: 12) {
                field("Save to") {
                    Button(action: chooseFolder) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.driftAccent)
                            Text(folderLabel)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.driftText)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                            Text("Change")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.driftMuted)
                        }
                        .fieldChrome()
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

                if isTorrent {
                    field("Priority") {
                        PriorityField(selection: $torrentPriority)
                    }
                    .frame(width: 210)
                } else {
                    field("Category") {
                        Menu {
                            ForEach(FileCategory.allCases) { option in
                                Button(option.title) { category = option }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(category.color).frame(width: 8, height: 8)
                                Text(category.title).font(.system(size: 13)).foregroundStyle(Color.driftText)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.driftMuted)
                            }
                            .fieldChrome()
                            .contentShape(.rect)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                    }
                    .frame(width: 170)
                }
            }

            HStack(spacing: 10) {
                if !isTorrent {
                    HStack(spacing: 8) {
                        DriftSwitch(isOn: $openWhenDone, label: "Open when finished")
                        Text("Open when finished")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.driftMuted2)
                            .onTapGesture { openWhenDone.toggle() }
                    }
                }
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(.driftPlain)
                    .keyboardShortcut(.cancelAction)
                Button("Add to Queue") { add(startNow: false) }
                    .buttonStyle(.driftSecondary)
                    .disabled(!canAdd || preparing)
                Button("Download") { add(startNow: true) }
                    .buttonStyle(.driftPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd || preparing)
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(Color.driftWindow)
        .fixedSize(horizontal: false, vertical: true)
        .tint(.driftAccent)
        .task {
            address = request.url
            if let name = request.suggestedName, !name.isEmpty {
                fileName = name
                nameEdited = true
            }
            if address.isEmpty, let text = NSPasteboard.general.string(forType: .string),
               ClipboardWatcher.downloadLink(in: text) != nil {
                address = text.trimmingCharacters(in: .whitespacesAndNewlines)
                fromClipboard = true
            }
            addressFocused = address.isEmpty
        }
        .task(id: address) { await runProbe() }
        .onChange(of: folder) {
            guard let gid = prepared?.gid else { return }
            let target = targetFolder
            prepared?.directory = target
            Task { await Aria2.shared.setDirectory(gid, to: target) }
        }
        .onDisappear { if !added { releasePrepared() } }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.driftMuted2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        if request.fromBrowser { return "From your browser" }
        if fromClipboard { return "Link found on your clipboard" }
        if !request.url.isEmpty { return "Link detected" }
        return "Paste a link, magnet, or drop a .torrent file"
    }

    private var folderLabel: String {
        let path = targetFolder.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    @ViewBuilder private var fileCard: some View {
        HStack(spacing: 14) {
            FileTile(fileName: fileName, category: category, isTorrent: isTorrent, size: 46)
            VStack(alignment: .leading, spacing: 8) {
                TextField("File name", text: $fileName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.driftText)
                    .onChange(of: fileName) { _, new in
                        if new != autoName { nameEdited = true }
                        category = FileCategory.detect(fileName: new)
                    }
                    .disabled(isTorrent)
                HStack(spacing: 6) {
                    if let url, store.items.contains(where: { $0.url == url }) {
                        Chip(text: "Already in your list", ink: .driftPausedInk, wash: Color.driftPaused.opacity(0.18))
                    }
                    if probing {
                        ProgressView().controlSize(.mini)
                        Text("Checking link…").font(.system(size: 11)).foregroundStyle(Color.driftMuted)
                    } else if let probeError {
                        Chip(text: probeError, ink: .driftDanger, wash: .driftDangerWash)
                    } else if preparing {
                        ProgressView().controlSize(.mini)
                        Text("Fetching file list…").font(.system(size: 11)).foregroundStyle(Color.driftMuted)
                    } else if let prepareError {
                        Chip(text: prepareError, ink: .driftDanger, wash: .driftDangerWash)
                    } else if let prepared {
                        Chip(text: "Torrent", ink: .driftSuccess, wash: .driftSuccessWash)
                        Chip(text: "\(prepared.files.count) file\(prepared.files.count == 1 ? "" : "s")", ink: .driftText.opacity(0.8))
                        Chip(text: Format.bytes(prepared.files.filter(\.included).reduce(0) { $0 + $1.length }), ink: .driftText.opacity(0.8))
                    } else if isMagnet {
                        Chip(text: "Magnet link", ink: .driftSuccess, wash: .driftSuccessWash)
                    } else if isTorrent {
                        Chip(text: "Torrent", ink: .driftSuccess, wash: .driftSuccessWash)
                    } else if let probe {
                        Chip(text: probe.totalBytes.map(Format.bytes) ?? "Unknown size", ink: .driftText.opacity(0.8))
                        Chip(text: probe.supportsRanges ? "Resumable" : "Not resumable",
                             ink: probe.supportsRanges ? .driftSuccess : .driftPausedInk,
                             wash: probe.supportsRanges ? .driftSuccessWash : Color.driftPaused.opacity(0.18))
                        if probe.supportsRanges {
                            Chip(text: "\(store.settings.connections) connections", ink: .driftAccentInk, wash: .driftAccentWash)
                        }
                    }
                }
                .frame(height: 20)
            }
        }
        .padding(14)
        .background(Color.driftCard, in: .rect(cornerRadius: 14))
    }

    private func runProbe() async {
        probe = nil
        probeError = nil
        releasePrepared()
        guard let url, let scheme = url.scheme?.lowercased() else { return }

        if isTorrent {
            await prepareTorrent(url, scheme: scheme)
            return
        }
        guard scheme == "http" || scheme == "https" else {
            if scheme == "file" { setName(url.lastPathComponent) }
            return
        }

        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        setName(FileNaming.fileName(from: url))
        probing = true
        defer { probing = false }
        do {
            let result = try await Probe.run(url, headers: request.headers)
            guard !Task.isCancelled else { return }
            probe = result
            setName(result.fileName)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { probeError = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach server" }
        }
    }

    /// Adds the torrent to aria2 paused and loads its file list for review.
    private func prepareTorrent(_ url: URL, scheme: String) async {
        setName(scheme == "magnet" ? (FileNaming.magnetName(url) ?? "Magnet link")
                                   : (url.lastPathComponent as NSString).deletingPathExtension)
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        preparing = true
        defer { preparing = false }
        do {
            let result: PreparedTorrent
            if scheme == "magnet" {
                result = try await Aria2.shared.prepareMagnet(url.absoluteString, directory: targetFolder)
            } else {
                let local = AppPaths.torrents.appending(path: "\(UUID().uuidString).torrent")
                if url.isFileURL {
                    try FileManager.default.copyItem(at: url, to: local)
                } else {
                    var request = URLRequest(url: url)
                    self.request.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    try await URLSession.shared.data(for: request).0.write(to: local)
                }
                localTorrent = local
                result = try await Aria2.shared.prepareTorrent(local, directory: targetFolder)
            }
            guard !Task.isCancelled else {
                await Aria2.shared.remove(result.gid)
                return
            }
            prepared = result
            nameEdited = false
            setName(result.name)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { prepareError = (error as? LocalizedError)?.errorDescription ?? "Couldn't read the torrent" }
        }
    }

    /// Drops a prepared torrent the user didn't add, plus the files fetched for it.
    private func releasePrepared() {
        prepareError = nil
        if let gid = prepared?.gid {
            Task { await Aria2.shared.remove(gid) }
            if isMagnet, let hash = magnetHash {
                try? FileManager.default.removeItem(at: (prepared?.directory ?? targetFolder).appending(path: "\(hash).torrent"))
            }
        }
        if let localTorrent { try? FileManager.default.removeItem(at: localTorrent) }
        prepared = nil
        localTorrent = nil
    }

    private var magnetHash: String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "xt" }?.value?.split(separator: ":").last?.lowercased()
    }

    private func setName(_ name: String) {
        guard !nameEdited else { return }
        autoName = name
        fileName = name
        category = FileCategory.detect(fileName: name)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = targetFolder
        if panel.runModal() == .OK { folder = panel.url }
    }

    private func add(startNow: Bool) {
        if let prepared, let url {
            added = true
            store.addPreparedTorrent(prepared, source: url, torrentFile: localTorrent, priority: torrentPriority, startNow: startNow)
            close()
            return
        }
        let name = fileName.trimmingCharacters(in: .whitespaces)
        let ok = store.add(address, fileName: name.isEmpty ? nil : name, directory: targetFolder,
                           headers: request.headers, probe: probe, startNow: startNow, openWhenDone: openWhenDone)
        if ok { close() }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

/// Priority picker sized like the other fields: three equal segments with icons in a 40pt rounded track.
private struct PriorityField: View {
    @Binding var selection: Priority
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Priority.allCases.reversed()) { option in
                let on = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 10, weight: .bold))
                        Text(option.title)
                            .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? ink(option) : Color.driftMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.driftWindow)
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(option.title) priority")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: 40)
        .background(Color.driftField, in: .rect(cornerRadius: 10))
    }

    private func ink(_ option: Priority) -> Color {
        switch option {
        case .high: .driftAccentInk
        case .normal: .driftText
        case .low: .driftMuted2
        }
    }
}
