import SwiftUI

/// Header button next to Settings: toggles the Video Tools slide-over, with a dot when a tool has an update.
struct VideoToolsButton: View {
    private var tools: ToolManager { .shared }
    @State private var hovering = false

    var body: some View {
        let open = tools.panelOpen
        Button {
            withAnimation(.snappy(duration: 0.25)) { tools.togglePanel() }
        } label: {
            Image(systemName: "film.stack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(open ? Color.anchorAccentInk : Color.anchorText)
                .frame(width: 32, height: 32)
                .background(open ? Color.anchorAccentWash : Color.anchorField, in: .circle)
                .overlay(Circle().strokeBorder(open ? Color.anchorAccentTint : Color.anchorLine))
                .overlay(Circle().fill(Color.anchorText.opacity(hovering ? 0.05 : 0)))
                .overlay(alignment: .topTrailing) {
                    if tools.hasUpdates {
                        Circle()
                            .fill(Color.anchorAccent)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Color.anchorWindow, lineWidth: 1.5))
                            .offset(x: 1, y: -1)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tools.hasUpdates ? "Video Tools: updates available" : "Video Tools")
        .accessibilityLabel(tools.hasUpdates ? "Video Tools, updates available" : "Video Tools")
    }
}

/// Slide-over from the right listing yt-dlp, FFmpeg and the JavaScript runtime, with install and update controls.
/// Same width, look and dismissal as the Details panel.
struct VideoToolsPanel: View {
    @Environment(DownloadStore.self) private var store
    @Binding var width: CGFloat
    let close: () -> Void
    private var tools: ToolManager { .shared }
    @State private var dragStart: CGFloat?
    @State private var escapeMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "film.stack")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.anchorAccent)
                    .frame(width: 38, height: 38)
                    .background(Color.anchorAccentWash, in: .rect(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.anchorAccentTint))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Video Tools")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.anchorText)
                    Text("Video downloads need these free tools. Anchor downloads them from their publishers (ffmpeg build by Martin Riedl).")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.anchorMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                IconButton(symbol: "xmark", label: "Close Video Tools", tint: .anchorMuted2, fill: .anchorField, size: 28,
                           outlined: true, action: close)
            }

            if tools.waitingForVideo, !tools.isReady {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.anchorAccent)
                    Text("Anchor needs these tools to download this video. Click Install all to get them; the video can be downloaded once they're ready.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.anchorAccentInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.anchorAccentWash, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.anchorAccentTint))
            }

            if tools.refreshed, !tools.missing.isEmpty {
                Button(tools.isInstalling ? "Installing…" : "Install all") { tools.installAll() }
                    .buttonStyle(.anchorPrimary)
                    .disabled(tools.isInstalling)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(ToolID.allCases.enumerated()), id: \.element) { index, tool in
                        ToolRow(tool: tool, mediaRunning: mediaRunning)
                            .overlay(alignment: .bottom) {
                                if index < ToolID.allCases.count - 1 { Rectangle().fill(Color.anchorLine).frame(height: 1) }
                            }
                    }
                }
                .background(Color.anchorCard, in: .rect(cornerRadius: 14))
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity, alignment: .top)

            footer
        }
        .padding(18)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.anchorWindow)
        .overlay(alignment: .leading) { resizeHandle }
        .shadow(color: .black.opacity(0.08), radius: 16, x: -6)
        .onAppear {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Escape in the main window (not a sheet or the floating New Download panel) closes the slide-over.
                guard event.keyCode == 53, let window = event.window, window.title == "Anchor",
                      window.attachedSheet == nil else { return event }
                close()
                return nil
            }
        }
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
        }
    }

    /// Updating yt-dlp replaces files a running download is using, so updates wait until media downloads stop.
    private var mediaRunning: Bool { store.items.contains { $0.kind == .media && $0.state.isActive } }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tools folder")
                .font(.system(size: 11))
                .foregroundStyle(Color.anchorMuted)
            HStack(spacing: 8) {
                Text(displayPath(ToolManager.folder))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.anchorText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button("Show in Finder") { tools.revealFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.anchorAccentInk)
            }
            Text(tools.diskUsage > 0 ? "Anchor's copies use \(Format.bytes(tools.diskUsage))" : "Nothing downloaded yet")
                .font(.system(size: 11))
                .foregroundStyle(Color.anchorMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.anchorWindow, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.anchorLine))
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.anchorLine)
            .frame(width: 1)
            .frame(width: 8)
            .contentShape(.rect)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? width
                        dragStart = start
                        width = min(640, max(360, start - value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .offset(x: -4)
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// One tool: icon, name, purpose and its current state with the matching action.
private struct ToolRow: View {
    let tool: ToolID
    let mediaRunning: Bool
    private var tools: ToolManager { .shared }

    var body: some View {
        let record = tools.records[tool]
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(record == nil ? Color.anchorMuted2 : Color.anchorAccent)
                .frame(width: 32, height: 32)
                .background(record == nil ? Color.anchorField : Color.anchorAccentWash, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name(record))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.anchorText)
                    if record?.source == .system {
                        Chip(text: "Found on your Mac", ink: .anchorSuccess, wash: .anchorSuccessWash)
                    }
                }
                Text(tool.purpose)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.anchorMuted)
                    .fixedSize(horizontal: false, vertical: true)
                status(record)
            }
            Spacer(minLength: 8)
            action(record)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func name(_ record: ToolRecord?) -> String {
        if tool == .deno, let runtime = record?.runtime { return JSRuntime.title(runtime) }
        return tool.title
    }

    @ViewBuilder private func status(_ record: ToolRecord?) -> some View {
        switch tools.activity[tool] {
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(received), total: Double(max(total ?? tool.approximateBytes, received, 1)))
                    .progressViewStyle(.linear)
                    .tint(.anchorAccent)
                Text(total == nil && received == 0 ? "Starting download…" : Format.progress(received, of: total))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Color.anchorMuted2)
            }
            .padding(.top, 2)
        case .verifying:
            busy("Verifying…")
        case .installing:
            busy("Installing…")
        case .failed(let reason):
            Text(reason)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.anchorDanger)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case nil:
            if let record {
                if tools.hasUpdate(tool), let newest = tools.latest[tool] {
                    Text("Update available: \(record.version) → \(newest)")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.anchorAccentInk)
                } else {
                    Text(record.source == .system ? "Version \(record.version) · Found on your Mac" : "Installed · version \(record.version)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Color.anchorSuccess)
                }
            } else if !tools.refreshed {
                busy("Checking…")
            } else {
                Text("Not installed · about \(Format.bytes(tool.approximateBytes))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.anchorMuted2)
            }
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.anchorMuted2)
        }
    }

    @ViewBuilder private func action(_ record: ToolRecord?) -> some View {
        switch tools.activity[tool] {
        case .failed:
            Button("Retry") { tools.install(tool) }
                .buttonStyle(.anchorSecondary)
        case nil where record != nil && tools.hasUpdate(tool):
            Button("Update") { tools.install(tool) }
                .buttonStyle(.anchorPrimary)
                .disabled(mediaRunning)
                .help(mediaRunning ? "Available once video downloads finish or are paused" : "Download and install the new version")
        case nil where record == nil && tools.refreshed:
            Button("Install") { tools.install(tool) }
                .buttonStyle(.anchorSecondary)
        default:
            EmptyView()
        }
    }
}
