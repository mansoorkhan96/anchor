import AppKit
import os

/// Looks inside dmg installers (read-only, never shown in Finder) and checks whether their app is installed.
/// Everything here runs off the main actor.
enum InstallerInspector {
    static let hdiutil = "/usr/bin/hdiutil"
    static let log = Logger(subsystem: "dev.mansoor.Anchor", category: "cleanup")
    /// content-hint of the synthesized container disk macOS adds when attaching an APFS image.
    private static let apfsContainerHint = "EF57347C-0000-11AA-AA11-00306543ECAC"

    struct AttachInfo: Equatable, Sendable {
        /// The image's own whole disk; detaching it detaches everything attached from the image.
        var root: String?
        var mountPoints: [String]
    }

    /// Paths as hdiutil reports them (symlinks such as /var resolved).
    static func normalized(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isWholeDisk(_ device: String) -> Bool {
        device.wholeMatch(of: /\/dev\/disk[0-9]+/) != nil
    }

    /// The image disk among an image's entities: a whole disk that is not an APFS synthesized container,
    /// the lowest numbered if several.
    private static func rootDevice(_ entities: [[String: Any]]) -> String? {
        let whole = entities.compactMap { entity -> (device: String, hint: String?)? in
            guard let device = entity["dev-entry"] as? String, isWholeDisk(device) else { return nil }
            return (device, entity["content-hint"] as? String)
        }
        .sorted { Int($0.device.dropFirst("/dev/disk".count)) ?? 0 < Int($1.device.dropFirst("/dev/disk".count)) ?? 0 }
        return (whole.first { $0.hint != apfsContainerHint } ?? whole.first)?.device
    }

    static func parseAttach(_ data: Data) -> AttachInfo? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return AttachInfo(root: rootDevice(entities), mountPoints: entities.compactMap { $0["mount-point"] as? String })
    }

    /// Normalized image path to its image disk, from `hdiutil info -plist`.
    static func attachedImages(infoPlist data: Data) -> [String: String]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        var images: [String: String] = [:]
        for image in plist["images"] as? [[String: Any]] ?? [] {
            guard let path = image["image-path"] as? String,
                  let root = rootDevice(image["system-entities"] as? [[String: Any]] ?? []) else { continue }
            images[normalized(path)] = root
        }
        return images
    }

    /// nil if hdiutil could not tell (callers then treat the image as possibly mounted).
    static func attachedImages() async -> [String: String]? {
        let info = await ProcessRunner.run(hdiutil, ["info", "-plist"], timeout: 15)
        guard info.status == 0 else { return nil }
        return attachedImages(infoPlist: info.data)
    }

    /// nil when unknown.
    static func isMounted(_ file: URL) async -> Bool? {
        guard let images = await attachedImages() else { return nil }
        return images[normalized(file.path)] != nil
    }

    /// The single `.app` at the top level of the mount points (symlinks ignored). Zero or several: nil bundle ID.
    static func findApp(in mountPoints: [URL]) -> (bundleID: String?, version: String?) {
        let fm = FileManager.default
        var apps: [URL] = []
        for mount in mountPoints {
            let entries = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.pathExtension.lowercased() == "app" {
                // attributesOfItem does not follow symlinks, so an alias into /Applications is skipped.
                guard (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory else { continue }
                apps.append(url)
            }
        }
        guard apps.count == 1,
              let data = try? Data(contentsOf: apps[0].appending(path: "Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { return (nil, nil) }
        let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String
        return (bundleID, version)
    }

    /// Inspects a dmg. Returns nil when it was skipped (file changed, already attached, or hdiutil unavailable),
    /// so nothing is cached; otherwise the result to cache for `expected`.
    static func inspect(_ file: URL, expected: FileStamp) async -> InstallerInfo? {
        guard FileStamp.read(file) == expected else { return nil }
        let path = normalized(file.path)
        // Already attached: the user is probably installing. Leave it alone.
        guard let attached = await attachedImages(), attached[path] == nil else { return nil }

        let failed = InstallerInfo(stamp: expected, bundleID: nil, version: nil, failed: true)
        let encrypted = await ProcessRunner.run(hdiutil, ["isencrypted", file.path], timeout: 15)
        if encrypted.status != 0 || String(decoding: encrypted.data, as: UTF8.self).contains("YES") {
            return FileStamp.read(file) == expected ? failed : nil
        }

        let mountRoot = FileManager.default.temporaryDirectory.appending(path: "Anchor-inspect-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)) != nil else { return nil }
        let attach = await ProcessRunner.run(hdiutil, ["attach", file.path, "-readonly", "-nobrowse", "-noautoopen", "-noverify",
                                                       "-mountrandom", mountRoot.path, "-plist"], timeout: 30)
        let parsed = attach.status == 0 && !attach.timedOut ? parseAttach(attach.data) : nil
        var app: (bundleID: String?, version: String?) = (nil, nil)
        if let parsed, parsed.root != nil {
            app = findApp(in: parsed.mountPoints.map { URL(filePath: $0, directoryHint: .isDirectory) })
        }

        // Always detach what this inspection attached. The check above guarantees nothing from this image was
        // attached before, so anything attached from it now came from this inspection.
        if let root = parsed?.root { await detach(root) }
        if let remaining = await attachedImages()?[path] { await detach(remaining) }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: mountRoot.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: mountRoot)
        }

        guard FileStamp.read(file) == expected else { return nil }
        guard let parsed, parsed.root != nil else { return failed }
        return InstallerInfo(stamp: expected, bundleID: app.bundleID, version: app.version, failed: false)
    }

    /// Detaches without `-force`, retrying once after 2 seconds. A failure is logged and left alone.
    private static func detach(_ device: String) async {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if await ProcessRunner.run(hdiutil, ["detach", device], timeout: 30).status == 0 { return }
        }
        log.error("Couldn't detach \(device, privacy: .public) after inspecting an installer")
    }

    /// Versions of the app installed in /Applications or ~/Applications.
    static func installedVersions(bundleID: String) -> [String] {
        let roots = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path + "/"]
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).compactMap { url in
            let path = url.standardizedFileURL.path
            guard roots.contains(where: { path.hasPrefix($0) }), let info = Bundle(url: url)?.infoDictionary else { return nil }
            return info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String
        }
    }
}
