<p align="center">
  <img src="Anchor/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" height="128" alt="Anchor icon">
</p>

<h1 align="center">Anchor</h1>

<p align="center">A native download manager for macOS, built with SwiftUI.</p>

## Features

- **Fast HTTP downloads**: splits each file across several connections, resumes after interruptions, and queues the rest.
- **Torrents and magnet links**: powered by a bundled aria2, with per-file selection and priority, seeding ratio and upload limits.
- **Browser integration**: a Safari extension ships inside the app. Chrome, Arc, Brave and Edge use the separate [anchor-browser-extension](https://github.com/mansoorkhan96/anchor-browser-extension).
- **Clipboard pickup**: offers to download links and magnets you copy.
- **Speed control**: global speed limits and quick speed modes.
- **When done**: sleep, shut down or quit once every download has finished.
- **Cleanup**: finds downloads you haven't used in a while so you can archive them (and restore them later) or move them to the Trash. Installers can be archived once their app is installed. Nothing is removed until you choose to.
- **Menu bar**: live speed and recent downloads, one click away.

## Requirements

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

## Browser extensions

Turn on **Take over browser downloads** in Settings > Browser. The extensions talk to Anchor over a local server on `127.0.0.1:47821`.

- **Safari**: open Settings > Browser > Open Safari… and enable Anchor. Unsigned builds also need Develop > Allow Unsigned Extensions.
- **Chrome, Arc, Brave, Edge**: in `chrome://extensions` turn on Developer mode, choose Load unpacked, and pick your `anchor-browser-extension` folder.

## Data

Anchor keeps its library and torrent state in `~/Library/Application Support/Anchor`.

## License

[MIT](LICENSE)
