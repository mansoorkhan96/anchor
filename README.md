<p align="center">
  <img src="Anchor/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" height="128" alt="Anchor icon">
</p>

<h1 align="center">Anchor</h1>

<p align="center">A native download manager for macOS, built with SwiftUI.</p>

<p align="center">
  <img src="https://mansoor.dev/images/anchor/main.png" width="800" alt="Anchor's main window with downloads in progress">
  <br>
  <a href="https://mansoor.dev/images/anchor/anchor-launch.mp4">▶ Watch the video</a> · <a href="https://mansoor.dev/projects/anchor">mansoor.dev/projects/anchor</a>
</p>

## Features

- **Fast HTTP downloads**: splits each file across several connections, resumes after interruptions, and queues the rest.
- **Torrents and magnet links**: powered by a bundled aria2, with per-file selection and priority, seeding ratio and upload limits.
- **Browser integration**: Chrome, Arc, Brave and Edge use the [anchor-browser-extension](https://github.com/mansoorkhan96/anchor-browser-extension). Safari support is coming soon.
- **Clipboard pickup**: offers to download links and magnets you copy.
- **Speed control**: global speed limits and quick speed modes.
- **When done**: sleep, shut down or quit once every download has finished.
- **Cleanup**: finds downloads you haven't used in a while so you can archive them (and restore them later) or move them to the Trash. Installers can be archived once their app is installed. Nothing is removed until you choose to.
- **Menu bar**: live speed and recent downloads, one click away.

## Install

Download `Anchor.dmg` from the [latest release](https://github.com/mansoorkhan96/anchor/releases/latest), open it and drag Anchor to Applications. Anchor needs macOS 26 on Apple silicon.

Anchor isn't notarized by Apple, so macOS blocks the first launch. Open Anchor once, then go to **System Settings > Privacy & Security** and click **Open Anyway**. Or run:

```sh
xattr -dr com.apple.quarantine /Applications/Anchor.app
```

## Requirements for building

- macOS 26 on Apple silicon
- Xcode 26
- [Homebrew](https://brew.sh) with `xcodegen`, `aria2` and `dylibbundler`

```sh
brew install xcodegen aria2 dylibbundler
```

## Building

The Xcode project is generated from `project.yml`:

```sh
xcodegen generate
open Anchor.xcodeproj
```

The first build copies Homebrew's `aria2c` and its libraries into `Vendor/aria2` (`scripts/vendor-aria2.sh`) and embeds them in the app.

To build a Release copy and install it to `/Applications`:

```sh
scripts/install.sh
```

### Tests

```sh
xcodebuild test -project Anchor.xcodeproj -scheme Anchor
```

### Releasing

```sh
scripts/release.sh 1.1.0
```

This sets the version in `project.yml` (and bumps the build number), builds a Release copy and writes `build/dist/Anchor-1.1.0.dmg`, a copy named `Anchor.dmg` and a SHA-256 checksum. Builds are ad-hoc signed, not notarized.

To publish, commit and push the version bump, then run:

```sh
scripts/release.sh 1.1.0 --publish
```

That builds again and creates a draft GitHub release `v1.1.0` with the DMGs, install notes and generated release notes. Review the draft on GitHub and publish it. Add `--beta` to mark it as a pre-release titled "Anchor 1.1.0 Beta".

## Browser extensions

**Take over browser downloads** is on by default (Settings > Browser), along with **Confirm each download**, which shows the New Download window before each browser download starts. The extensions talk to Anchor over a local server on `127.0.0.1:47821`.

### Chrome, Arc, Brave, Edge

The extension lives in its own repo: [anchor-browser-extension](https://github.com/mansoorkhan96/anchor-browser-extension).

1. [Download the extension](https://github.com/mansoorkhan96/anchor-browser-extension/archive/refs/heads/main.zip) and unzip it to a folder you'll keep (it unzips as `anchor-browser-extension-main`).
2. Open `chrome://extensions` (or your browser's extensions page) and turn on **Developer mode**.
3. Click **Load unpacked** and pick that folder.

The browser loads the extension from that folder, so don't delete or move it.

### Safari (coming soon)

Safari support is on the way.

## Data

Anchor keeps its library and torrent state in `~/Library/Application Support/Anchor`.

## License

[MIT](LICENSE)
