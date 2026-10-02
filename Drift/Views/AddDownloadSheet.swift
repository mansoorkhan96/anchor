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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New download")
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Address").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("https://… or magnet:?…", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(addressFocused ? Color.driftAccent : .primary.opacity(0.1)))
                    .focused($addressFocused)
                    .onSubmit { if canAdd { add(startNow: true) } }
            }

            fileCard

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Save to").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Button(action: chooseFolder) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(Color.driftAccent)
                            Text(folderLabel).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)

                if !isTorrent {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Category").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker("Category", selection: $category) {
                            ForEach(FileCategory.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(height: 36)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            if !isTorrent {
                Toggle("Open when finished", isOn: $openWhenDone)
                    .toggleStyle(.checkbox)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Queue") { add(startNow: false) }
                    .disabled(!canAdd)
                Button("Download") { add(startNow: true) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560, height: 470)
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
            VStack(alignment: .leading, spacing: 6) {
                TextField("File name", text: $fileName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .onChange(of: fileName) { _, new in
                        if new != autoName { nameEdited = true }
                        category = FileCategory.detect(fileName: new)
                    }
                    .disabled(isTorrent)
                HStack(spacing: 8) {
                    if probing {
                        ProgressView().controlSize(.small)
                        Text("Checking link…").font(.caption).foregroundStyle(.secondary)
                    } else if let probeError {
                        Chip(text: probeError, color: .red)
                    } else if isMagnet {
                        Chip(text: "Magnet link", color: .driftTorrent)
                    } else if isTorrent {
                        Chip(text: "Torrent", color: .driftTorrent)
                    } else if let probe {
                        Chip(text: probe.totalBytes.map(Format.bytes) ?? "Unknown size", color: .primary)
                        Chip(text: probe.supportsRanges ? "Resumable" : "Not resumable",
                             color: probe.supportsRanges ? .driftSuccess : .driftPaused)
                        if probe.supportsRanges {
                            Chip(text: "\(store.settings.connections) connections", color: .primary)
                        }
                    }
                }
                .frame(height: 20)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
    }

    private func runProbe() async {
        probe = nil
        probeError = nil
        guard let url, let scheme = url.scheme?.lowercased() else { return }

        if scheme == "magnet" {
            let dn = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dn" }?.value
            setName(dn ?? "Magnet link")
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
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(color == .primary ? Color.primary : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((color == .primary ? Color.primary.opacity(0.08) : color.opacity(0.14)), in: .rect(cornerRadius: 6))
    }
}
