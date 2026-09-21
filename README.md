<p align="center">
  <img src="docs/icon.png" alt="Elgato Capture icon" width="128">
</p>

<h1 align="center">Elgato Mac Tool</h1>

![UI](ui.png)

Hardware-accelerated 1080p60 capture for Elgato (and other UVC) devices on macOS — built on AVFoundation and VideoToolbox. Ships a SwiftUI menu-bar app and a minimal CLI, sharing a single capture engine.

<p align="center">
  <img src="remote.png" alt="Mobile remote (PWA)" width="360">
</p>

Originally lived inside [obs-remote](https://github.com/) as `elgatomactool/`; extracted here as its own repo.

## Features

- **1080p60 capture** with hardware H.264/HEVC encoding via VideoToolbox.
- **Replay buffer** — keep the last N seconds of footage in RAM, save on demand.
- **Recording, screenshots, replay save** — keyboard shortcuts in the CLI, buttons + menu-bar items in the GUI.
- **SwiftUI GUI** with live preview, audio meter, FPS/bitrate/CPU/GPU/RAM/disk telemetry and sparklines.
- **Mobile remote (PWA)** — the GUI ships an embedded web server that hosts a Framework7-based PWA. Scan the QR, control everything from your phone over LAN, PSK-protected.
- **Apple Silicon native** — NV12 throughout, no color conversion, typical CPU < 5% on M2.

## Install

Download `ElgatoCapture-<version>.dmg` from [Releases](https://github.com/sleep/elgato-mac-tool/releases), open it and drag **Elgato Capture** into **Applications**.

The app isn't signed with a developer certificate, so the first launch needs a right-click → **Open** (or `xattr -dr com.apple.quarantine "/Applications/Elgato Capture.app"`). It's a universal binary (Apple Silicon + Intel).

### Updates

The app checks [GitHub Releases](https://github.com/sleep/elgato-mac-tool/releases) once a day on launch (toggle in **Preferences → General**) and on demand via **Check for Updates…** in the app and menu-bar menus. When a newer version exists it offers to install it: the DMG is downloaded, checked against the SHA-256 GitHub publishes for the asset, and the app inside is verified before it replaces the running copy and relaunches. It never installs while a recording is in progress. The only request made is to `api.github.com`.

Self-update needs the packaged app in a folder you can write to (e.g. `/Applications`); `swift run` builds don't update.

The icon is drawn in code (`Sources/ElgatoCaptureGUI/AppIconRenderer.swift`) — the packaging script renders it into the `.icns`, the app uses it for the Dock, and the mobile remote serves a full-bleed variant as its home-screen icon.

To build the installer yourself:

```bash
scripts/package-app.sh 0.1.1   # → dist/Elgato Capture.app, dist/ElgatoCapture-0.1.1.dmg
```

## Requirements

- macOS 13 or later
- Swift 5.9 toolchain (Xcode 15+ or matching command-line tools)
- An Elgato (or other AVFoundation-visible) capture device
- Camera access granted in System Settings → Privacy & Security → Camera

## Build & run

```bash
# GUI (default)
./run.sh
# or explicitly
swift run elgato-capture-gui

# CLI
swift run elgato-capture
swift run elgato-capture --help
swift run elgato-capture --list-devices
```

Output files land in `~/Movies/ElgatoCapture/`.

## Targets

The package (`Package.swift`) defines three targets:

| Target | Kind | Path | Description |
|---|---|---|---|
| `CaptureCore` | library | `Sources/CaptureCore` | Capture engine, encoder, recorder, replay buffer, device discovery |
| `elgato-capture` | executable | `Sources/ElgatoCapture` | AppKit CLI with preview window and keyboard controls |
| `elgato-capture-gui` | executable | `Sources/ElgatoCaptureGUI` | SwiftUI menu-bar app with embedded mobile-remote server |

## CLI controls

In the preview window:

| Key | Action |
|---|---|
| `R` | Toggle recording |
| `S` | Save screenshot (PNG) |
| `Space` | Save replay buffer (MP4) |
| `Q` | Quit |

## Mobile remote

The GUI app embeds a small HTTP server (`Sources/ElgatoCaptureGUI/Remote/`) that serves a PWA from `Sources/ElgatoCaptureGUI/WebRoot/`.

1. Open the **Mobile Remote…** panel (toolbar button or menu bar).
2. Click **Start Remote Server** and scan the QR code on your phone.
3. Optionally enable **Start automatically on launch**.

The PSK is embedded in the URL (`?k=…`) and persists across sessions so the installed PWA keeps working. Rotate it from the panel any time. The macOS local-network permission prompt may appear the first time.

## Project layout

```
Sources/
├── CaptureCore/            shared engine library
│   ├── CaptureEngine.swift
│   ├── HardwareEncoder.swift
│   ├── Recorder.swift
│   ├── ReplayBuffer.swift
│   └── DeviceDiscovery.swift
├── ElgatoCapture/          CLI app
└── ElgatoCaptureGUI/       SwiftUI app
    ├── Remote/             embedded mobile-remote server
    ├── Views/              SwiftUI views
    └── WebRoot/            PWA assets (HTML/CSS/JS/SW)
```
