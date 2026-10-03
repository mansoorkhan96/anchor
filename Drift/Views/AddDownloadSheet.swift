import SwiftUI

struct AddDownloadSheet: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: AddRequest

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
                    .frame(width: 36, height: 36)
                    .background(Color.driftAccent.opacity(0.12), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Download")
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            field("Link") {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(Color.driftAccent)
                    } else {
                        Button {
                            address = ""
                            addressFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
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
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.driftStroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    )
            } else {
                fileCard
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
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                            Text("Change")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .fieldChrome()
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

                if !isTorrent {
                    field("Category") {
                        Menu {
                            ForEach(FileCategory.allCases) { option in
                                Button(option.title) { category = option }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(category.color).frame(width: 8, height: 8)
                                Text(category.title).font(.system(size: 13))
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
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
                    Toggle("Open when finished", isOn: $openWhenDone)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 12))
                        .tint(.driftAccent)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.driftPlain)
                    .keyboardShortcut(.cancelAction)
                Button("Add to Queue") { add(startNow: false) }
                    .buttonStyle(.driftSecondary)
                    .disabled(!canAdd)
                Button("Download") { add(startNow: true) }
                    .buttonStyle(.driftPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(width: 580)
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
            }
            addressFocused = address.isEmpty
        }
        .task(id: address) { await runProbe() }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        if request.headers["Cookie"] != nil || request.headers["Referer"] != nil { return "From your browser" }
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
            FileTile(fileName: fileName, tint: isTorrent ? .driftTorrent : category.color, isTorrent: isTorrent, size: 44)
            VStack(alignment: .leading, spacing: 8) {
                TextField("File name", text: $fileName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .onChange(of: fileName) { _, new in
                        if new != autoName { nameEdited = true }
                        category = FileCategory.detect(fileName: new)
                    }
                    .disabled(isTorrent)
                HStack(spacing: 6) {
                    if let url, store.items.contains(where: { $0.url == url }) {
                        Chip(text: "Already in your list", color: .driftPaused)
                    }
                    if probing {
                        ProgressView().controlSize(.mini)
                        Text("Checking link…").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if let probeError {
                        Chip(text: probeError, color: .driftDanger)
                    } else if isMagnet {
                        Chip(text: "Magnet link", color: .driftTorrent)
                    } else if isTorrent {
                        Chip(text: "Torrent", color: .driftTorrent)
                    } else if let probe {
                        Chip(text: probe.totalBytes.map(Format.bytes) ?? "Unknown size")
                        Chip(text: probe.supportsRanges ? "Resumable" : "Not resumable",
                             color: probe.supportsRanges ? .driftSuccess : .driftPaused)
                        if probe.supportsRanges {
                            Chip(text: "\(store.settings.connections) connections")
                        }
                    }
                }
                .frame(height: 20)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.driftStroke))
    }

    private func runProbe() async {
        probe = nil
        probeError = nil
        guard let url, let scheme = url.scheme?.lowercased() else { return }

        if scheme == "magnet" {
            setName(FileNaming.magnetName(url) ?? "Magnet link")
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
        let name = fileName.trimmingCharacters(in: .whitespaces)
        let ok = store.add(address, fileName: name.isEmpty ? nil : name, directory: targetFolder,
                           headers: request.headers, probe: probe, startNow: startNow, openWhenDone: openWhenDone)
        if ok { dismiss() }
    }
}

private struct Chip: View {
    let text: String
    var color: Color?

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(color ?? .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.map { $0.opacity(0.13) } ?? Color.driftFill, in: .rect(cornerRadius: 6))
    }
}
