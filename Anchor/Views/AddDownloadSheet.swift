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
    @State private var prepareTask: Task<PreparedTorrent, Error>?
    @State private var prepareError: String?
    @State private var localTorrent: URL?
    @State private var torrentPriority: Priority = .normal
    @State private var added = false
    // Video links: a known host or a page yt-dlp recognizes.
    @State private var mediaCandidate = false
    @State private var media: MediaProbeResult?
    @State private var mediaProbing = false
    /// yt-dlp's answer when a video site refused (bot check, private, removed…); shown instead of falling back to
    /// downloading the page.
    @State private var mediaError: String?
    @State private var quality: MediaQuality = .best
    @State private var subtitleChoice: MediaSubtitle?
    // Playlists and channels: the videos to download (indexes into `playlist.videos`).
    @State private var playlist: MediaProbeResult?
    @State private var playlistSelection: Set<Int> = []
    @State private var numberFiles = true
    @FocusState private var addressFocused: Bool

    private var tools: ToolManager { .shared }
    private var isMedia: Bool { mediaCandidate || media != nil || playlist != nil }
    /// Re-checks the link when the tools become ready, so a waiting video link gets probed.
    private struct ProbeKey: Hashable { var address: String; var toolsReady: Bool }

    private var url: URL? {
        URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.scheme == nil ? nil : $0 }
    }
    private var isMagnet: Bool { url?.scheme?.lowercased() == "magnet" }
    private var isTorrent: Bool {
        isMagnet || url?.pathExtension.lowercased() == "torrent" || probe?.mimeType == "application/x-bittorrent"
    }
    /// "1080p · about 444 MB" when yt-dlp gave sizes, otherwise just the quality; "(Convert to MP4)" when the
    /// quality only exists as VP9 or AV1 and Anchor re-encodes it so QuickTime can play it.
    private func qualityLabel(_ option: MediaQuality) -> String {
        var label = option.title
        if playlist != nil { return label }
        if option == .playable, let height = media?.chosenVideo(.playable)?.height { label = "\(height)p, no conversion" }
        if let size = media?.estimatedSize(option) { label += " · about \(Format.bytes(size))" }
        if media?.conversionHeight(option) != nil { label += " (Convert to MP4)" }
        return label
    }

    private var targetFolder: URL { folder ?? store.settings.folder(for: isMedia ? quality.category : category) }
    private var canAdd: Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        // Video links wait for the tools and for yt-dlp's answer; a playlist needs at least one video.
        if isMedia, !tools.isReady || (media == nil && (playlist == nil || playlistSelection.isEmpty)) { return false }
        return ["http", "https", "magnet", "file"].contains(scheme)
    }

    private var qualityOptions: [MediaQuality] {
        playlist != nil ? MediaQuality.playlistOptions : media?.availableQualities ?? [.best, .audio]
    }

    /// "Download", "Download 12 Videos", or with a schedule waiting, "Download at 1:00 AM".
    private var downloadTitle: String {
        if let startsAt = store.queueStartsAt { return "Download at \(startsAt.formatted(date: .omitted, time: .shortened))" }
        if playlist != nil { return playlistSelection.count == 1 ? "Download 1 Video" : "Download \(playlistSelection.count) Videos" }
        return "Download"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.anchorAccent)
                    .frame(width: 38, height: 38)
                    .background(Color.anchorAccentWash, in: .rect(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.anchorAccentTint))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Download")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.anchorText)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.anchorMuted)
                }
            }

            field("Link") {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.anchorMuted)
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
                        .foregroundStyle(Color.anchorAccentInk)
                    } else {
                        Button {
                            address = ""
                            addressFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.anchorMuted.opacity(0.7))
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
                    .foregroundStyle(Color.anchorMuted)
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.anchorLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    )
            } else if let playlist {
                PlaylistCard(folderName: $fileName, result: playlist)
                PlaylistVideoList(videos: playlist.videos, selection: $playlistSelection)
            } else if isMedia {
                MediaCard(fileName: $fileName, result: media, probing: mediaProbing, quality: quality)
                if let mediaError, media == nil, !mediaProbing {
                    MediaErrorNote(raw: mediaError)
                }
            } else {
                fileCard
            }

            if isMedia {
                HStack(alignment: .top, spacing: 12) {
                    field("Quality") {
                        Menu {
                            ForEach(qualityOptions) { option in
                                Button {
                                    quality = option
                                } label: {
                                    if option == quality { Label(qualityLabel(option), systemImage: "checkmark") } else { Text(qualityLabel(option)) }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: quality.isAudio ? "music.note" : "film")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.anchorAccent)
                                    .accessibilityHidden(true)
                                Text(qualityLabel(quality)).font(.system(size: 13)).foregroundStyle(Color.anchorText)
                                Spacer(minLength: 4)
                                MenuChevron()
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.anchorMuted)
                            }
                            .fieldChrome()
                            .contentShape(.rect)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Quality")
                        .onChange(of: media?.availableQualities ?? []) { _, options in
                            if !options.isEmpty, !options.contains(quality) { quality = .best }
                        }
                    }
                    if let options = media?.subtitleOptions, !options.isEmpty, !quality.isAudio {
                        field("Subtitles") {
                            SubtitleMenu(options: options, selection: $subtitleChoice)
                        }
                        .frame(width: 210)
                    }
                }
            }

            if let files = prepared?.files {
                TorrentFileList(files: files, maxHeight: 220, rootFolder: prepared?.name,
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
                                .foregroundStyle(Color.anchorAccent)
                            Text(folderLabel)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.anchorText)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                            Text("Change")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.anchorMuted)
                        }
                        .fieldChrome()
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

                if isMedia {
                    EmptyView()
                } else if isTorrent {
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
                                Text(category.title).font(.system(size: 13)).foregroundStyle(Color.anchorText)
                                Spacer(minLength: 4)
                                MenuChevron()
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.anchorMuted)
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
                if playlist != nil {
                    HStack(spacing: 8) {
                        AnchorSwitch(isOn: $numberFiles, label: "Number the files")
                        Text("Number the files")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.anchorMuted2)
                            .lineLimit(1)
                            .fixedSize()
                            .onTapGesture { numberFiles.toggle() }
                            .help("Puts each video's place in the playlist in front of its name, like \"03 Title\"")
                            .accessibilityHidden(true)
                    }
                } else if !isTorrent {
                    HStack(spacing: 8) {
                        AnchorSwitch(isOn: $openWhenDone, label: "Open when finished")
                        Text("Open when finished")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.anchorMuted2)
                            .onTapGesture { openWhenDone.toggle() }
                            .accessibilityHidden(true)
                    }
                }
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(.anchorPlain)
                    .keyboardShortcut(.cancelAction)
                Button("Add to Queue") { add(startNow: false) }
                    .buttonStyle(.anchorSecondary)
                    .disabled(!canAdd)
                Button(downloadTitle) { add(startNow: true) }
                    .buttonStyle(.anchorPrimary)
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(Color.anchorWindow)
        .fixedSize(horizontal: false, vertical: true)
        .tint(.anchorAccent)
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
        .task(id: ProbeKey(address: address, toolsReady: tools.isReady)) { await runProbe() }
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
                .foregroundStyle(Color.anchorMuted2)
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
        var path = targetFolder.path
        // A playlist's videos go into a folder named after it.
        let sub = FileNaming.sanitize(fileName.trimmingCharacters(in: .whitespaces))
        if playlist != nil, !sub.isEmpty { path = targetFolder.appending(path: sub).path }
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
                    .foregroundStyle(Color.anchorText)
                    .onChange(of: fileName) { _, new in
                        if new != autoName { nameEdited = true }
                        category = FileCategory.detect(fileName: new)
                    }
                    .disabled(isTorrent)
                HStack(spacing: 6) {
                    if let url, store.items.contains(where: { $0.url == url }) {
                        Chip(text: "Already in your list", ink: .anchorPausedInk, wash: Color.anchorPaused.opacity(0.18))
                    }
                    if probing {
                        ProgressView().controlSize(.mini)
                        Text("Checking link…").font(.system(size: 11)).foregroundStyle(Color.anchorMuted)
                    } else if let probeError {
                        Chip(text: probeError, ink: .anchorDanger, wash: .anchorDangerWash)
                    } else if preparing {
                        ProgressView().controlSize(.mini)
                        Text("Fetching file list…").font(.system(size: 11)).foregroundStyle(Color.anchorMuted)
                    } else if let prepareError {
                        Chip(text: prepareError, ink: .anchorDanger, wash: .anchorDangerWash)
                    } else if let prepared {
                        Chip(text: "Torrent", ink: .anchorSuccess, wash: .anchorSuccessWash)
                        Chip(text: "\(prepared.files.count) file\(prepared.files.count == 1 ? "" : "s")", ink: .anchorText.opacity(0.8))
                        Chip(text: Format.bytes(prepared.files.filter(\.included).reduce(0) { $0 + $1.length }), ink: .anchorText.opacity(0.8))
                    } else if isMagnet {
                        Chip(text: "Magnet link", ink: .anchorSuccess, wash: .anchorSuccessWash)
                    } else if isTorrent {
                        Chip(text: "Torrent", ink: .anchorSuccess, wash: .anchorSuccessWash)
                    } else if let probe {
                        Chip(text: probe.totalBytes.map(Format.bytes) ?? "Unknown size", ink: .anchorText.opacity(0.8))
                        Chip(text: probe.supportsRanges ? "Resumable" : "Not resumable",
                             ink: probe.supportsRanges ? .anchorSuccess : .anchorPausedInk,
                             wash: probe.supportsRanges ? .anchorSuccessWash : Color.anchorPaused.opacity(0.18))
                        if probe.supportsRanges {
                            Chip(text: "\(store.settings.connections) connections", ink: .anchorAccentInk, wash: .anchorAccentWash)
                        }
                    }
                }
                .frame(height: 20)
            }
        }
        .padding(14)
        .background(Color.anchorCard, in: .rect(cornerRadius: 14))
    }

    private func runProbe() async {
        probe = nil
        probeError = nil
        media = nil
        playlist = nil
        playlistSelection = []
        subtitleChoice = nil
        mediaError = nil
        mediaCandidate = false
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

        // A known video site: without the tools, show what's needed and let the user start the install; then yt-dlp decides.
        if MediaLinkDetector.isLikelyMedia(url) {
            mediaCandidate = true
            guard tools.isReady else {
                tools.requestForVideo()
                return
            }
            if await probeMedia(url) { return }
            guard !Task.isCancelled else { return }
            mediaCandidate = false
        }

        setName(FileNaming.fileName(from: url))
        probing = true
        defer { probing = false }
        do {
            let result = try await Probe.run(url, headers: request.headers)
            guard !Task.isCancelled else { return }
            probe = result
            setName(result.fileName)
            // A web page on another site: yt-dlp may still know it.
            if result.mimeType == "text/html", tools.isReady, !MediaLinkDetector.isLikelyMedia(url) {
                probing = false
                if await probeMedia(url) { probe = nil }
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { probeError = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach server" }
        }
    }

    /// Asks yt-dlp about the link; true (and the card filled in) when it is a video.
    private func probeMedia(_ url: URL) async -> Bool {
        guard let paths = tools.paths else { return false }
        mediaProbing = true
        defer { mediaProbing = false }
        let outcome = await MediaProber.shared.probe(url, tools: paths, cookies: cookies(for: url))
        guard !Task.isCancelled else { return false }
        if case .playlist(let result) = outcome {
            playlist = result
            playlistSelection = Set(result.videos.indices)
            quality = .best
            nameEdited = false
            setName(FileNaming.sanitize(result.title ?? "Playlist"))
            return true
        }
        if case .notMedia(let message?) = outcome, MediaLinkDetector.isLikelyMedia(url), MediaErrors.kind(of: message) != .other {
            // The site refused; saying why beats offering its web page as a download.
            mediaError = message
            return true
        }
        guard case .media(let result) = outcome else { return false }
        media = result
        quality = result.defaultQuality
        nameEdited = false
        setName(FileNaming.sanitize(result.title ?? "Video"))
        return true
    }

    /// The cookies yt-dlp should use: the chosen browser's, else the ones the extension sent with the link
    /// (structured, or rebuilt from its Cookie header).
    private func cookies(for url: URL) -> MediaCookies {
        var jar = request.cookieJar
        if jar.isEmpty, let header = request.headers["Cookie"] { jar = MediaCookies.jar(fromHeader: header, url: url) }
        return MediaCookies.choose(jar: jar)
    }

    /// The extension's cookies for this link, kept with the download.
    private func linkCookies(for url: URL) -> [BrowserCookie] {
        if !request.cookieJar.isEmpty { return request.cookieJar }
        return request.headers["Cookie"].map { MediaCookies.jar(fromHeader: $0, url: url) } ?? []
    }

    /// Adds the torrent to aria2 paused and loads its file list for review.
    private func prepareTorrent(_ url: URL, scheme: String) async {
        setName(scheme == "magnet" ? (FileNaming.magnetName(url) ?? "Magnet link")
                                   : (url.lastPathComponent as NSString).deletingPathExtension)
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let directory = targetFolder
        let headers = request.headers
        // Its own task, so pressing Download before it finishes can hand it to the list to finish there.
        let task = Task { () async throws -> PreparedTorrent in
            if scheme == "magnet" {
                return try await Aria2.shared.prepareMagnet(url.absoluteString, directory: directory)
            }
            let local = AppPaths.torrents.appending(path: "\(UUID().uuidString).torrent")
            do {
                if url.isFileURL {
                    try FileManager.default.copyItem(at: url, to: local)
                } else {
                    var request = URLRequest(url: url)
                    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    try await URLSession.shared.data(for: request).0.write(to: local)
                }
                var result = try await Aria2.shared.prepareTorrent(local, directory: directory)
                result.torrentFile = local
                return result
            } catch {
                try? FileManager.default.removeItem(at: local)
                throw error
            }
        }
        prepareTask = task
        preparing = true
        defer { preparing = false }
        let outcome = await task.result
        if added { return } // handed to the list
        guard !Task.isCancelled else {
            if case .success(let result) = outcome {
                await Aria2.shared.remove(result.gid)
                if let file = result.torrentFile { try? FileManager.default.removeItem(at: file) }
            }
            return
        }
        switch outcome {
        case .success(let result):
            prepared = result
            localTorrent = result.torrentFile
            nameEdited = false
            setName(result.name)
        case .failure(let error):
            if !(error is CancellationError) {
                prepareError = (error as? LocalizedError)?.errorDescription ?? "Couldn't read the torrent"
            }
        }
    }

    /// Drops a prepared torrent the user didn't add, plus the files fetched for it.
    private func releasePrepared() {
        prepareError = nil
        prepareTask?.cancel()
        prepareTask = nil
        if let gid = prepared?.gid {
            Task { await Aria2.shared.remove(gid) }
            if isMagnet, let url, let hash = FileNaming.magnetHash(url) {
                try? FileManager.default.removeItem(at: (prepared?.directory ?? targetFolder).appending(path: "\(hash).torrent"))
            }
        }
        if let localTorrent { try? FileManager.default.removeItem(at: localTorrent) }
        prepared = nil
        localTorrent = nil
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
        if preparing, let prepareTask, let url {
            added = true
            store.addPreparingTorrent(prepareTask, source: url, name: fileName, directory: targetFolder,
                                      priority: torrentPriority, startNow: startNow)
            close()
            return
        }
        if let playlist, let url {
            added = true
            let videos = playlist.videos
            let chosen = playlistSelection.sorted().filter { videos.indices.contains($0) }.map { (index: $0 + 1, video: videos[$0]) }
            store.addPlaylist(chosen, folderName: fileName, extractor: playlist.extractor, quality: quality,
                              directory: targetFolder, numbered: numberFiles, cookieJar: linkCookies(for: url), startNow: startNow)
            close()
            return
        }
        if let media, let url {
            added = true
            store.addMedia(url, name: fileName.trimmingCharacters(in: .whitespaces), directory: targetFolder, quality: quality,
                           info: media.info, convertHeight: media.conversionHeight(quality), subtitle: subtitleChoice,
                           cookieJar: linkCookies(for: url), startNow: startNow, openWhenDone: openWhenDone)
            close()
            return
        }
        // Adding doesn't wait for the link check: without a server answer yet (and no name typed),
        // the download takes the name the server sends.
        let name = fileName.trimmingCharacters(in: .whitespaces)
        let useName = !name.isEmpty && (nameEdited || probe != nil || !probing)
        let ok = store.add(address, fileName: useName ? name : nil, directory: targetFolder,
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
                    .foregroundStyle(on ? ink(option) : Color.anchorMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.anchorWindow)
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
        .background(Color.anchorField, in: .rect(cornerRadius: 10))
    }

    private func ink(_ option: Priority) -> Color {
        switch option {
        case .high: .anchorAccentInk
        case .normal: .anchorText
        case .low: .anchorMuted2
        }
    }
}

/// None, or one of the languages the site has subtitles in.
private struct SubtitleMenu: View {
    let options: [MediaSubtitle]
    @Binding var selection: MediaSubtitle?

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                if selection == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            Divider()
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.anchorAccent)
                    .accessibilityHidden(true)
                Text(selection?.title ?? "None")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.anchorText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                MenuChevron()
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.anchorMuted)
            }
            .fieldChrome()
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Subtitles")
    }
}
