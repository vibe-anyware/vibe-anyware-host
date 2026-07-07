# Vibe Anyware — Mac Companion Host

The Mac-side companion for the **Vibe Anyware** iPhone app. Vibe Anyware turns
your iPhone into a wireless trackpad, keyboard, and shortcut pad for your Mac.
This host is the small menu-bar helper that runs on the Mac and applies the
pointer and keyboard commands your iPhone sends.

- **iOS app:** Vibe Anyware, on the App Store.
- **This repo:** the Mac host, source-available so you can build and run it
  yourself. See [LICENSE](LICENSE) — this is **not** open-source software and is
  for personal use with the Vibe Anyware app only.

## How it connects

The iPhone reaches this host in one of two ways:

- **LAN** — direct over the same Wi‑Fi network. Lowest latency, nothing leaves
  your local network. You enter the Mac's LAN IP and port in the app.
- **Relay** — routed through a relay server when the phone and Mac aren't on the
  same network. You can point it at your own self-hosted relay, or use the
  official relay via a setup key the app generates for you.

No account is required for LAN use.

## Requirements

- macOS 14 (Sonoma) or later
- [Xcode](https://developer.apple.com/xcode/) (or the Command Line Tools) — for `xcodebuild`
- [XcodeGen](https://github.com/yonyz/XcodeGen) — `brew install xcodegen`

## Install

```bash
git clone https://github.com/vibe-anyware/vibe-anyware-host.git
cd vibe-anyware-host
xcodegen generate
Scripts/install-macos-host.sh
```

The installer builds the host in Release, packages it as
`~/Applications/VibeAnyware.app`, installs a user LaunchAgent so it starts
automatically, launches it, and prints the LAN IP and port to type into the app.

### Options

```
Scripts/install-macos-host.sh --help
```

| Flag | Purpose |
|------|---------|
| `--port <port>` | LAN listen port (default 45731) |
| `--lan-command-key <key>` | Shared key for encrypted LAN command frames |
| `--relay <endpoint>` | Relay endpoint, e.g. `wss://relay.example.com` |
| `--server-id <id>` | Relay server ID for this Mac |
| `--relay-access-token <token>` | Relay access token |
| `--relay-command-key <key>` | Relay command encryption key |
| `--official-relay-setup-key <key>` | Paste the setup key the app gives you |

For relay setups, the easiest path is to let the iPhone app generate a setup key
and pass it with `--official-relay-setup-key` — the host then configures the
endpoint, server ID, token, and command key for you.

## Grant Accessibility permission

macOS requires Accessibility permission to move the pointer and type on your
behalf. On first run, open **System Settings → Privacy & Security →
Accessibility** and enable `VibeAnyware.app`. The menu-bar icon shows
whether the permission is granted.

> Tip: sign the app with your own Apple Development certificate
> (`--codesign-identity`) so the Accessibility grant survives rebuilds. With
> ad-hoc signing you may need to re-grant it after each reinstall.

## Pair with the app

1. Start the host (the installer does this) and confirm the menu bar shows
   **Accessibility: Granted** and **LAN: listening**.
2. Open Vibe Anyware on your iPhone, choose **LAN**, and enter the Mac's LAN IP
   and port shown by the installer.
3. Move your finger on the phone — the Mac pointer follows.

### Screen mirroring (e.g. UU Remote)

Some screen-mirroring tools don't capture the hardware cursor, so the pointer
looks invisible in the mirrored view. Enable **"Show pointer for screen
mirroring"** from the host's menu bar to draw an on-screen pointer that mirroring
tools can see. It only appears while the phone is actively moving the pointer.

## Build & test from source

```bash
xcodegen generate
xcodebuild -project VibeAnyware.xcodeproj -scheme VibeAnyware -configuration Release build
xcodebuild -project VibeAnyware.xcodeproj -scheme VibeAnyware test
```

## Uninstall

```bash
launchctl bootout gui/$(id -u)/app.vibeanyware.host 2>/dev/null || true
rm -f ~/Library/LaunchAgents/app.vibeanyware.host.plist
rm -rf ~/Applications/VibeAnyware.app
```

## License

Copyright © 2026 Shenzhen Infinite State Technology Co., Ltd. All rights
reserved. Source-available for personal use with the Vibe Anyware app; see
[LICENSE](LICENSE). For commercial use or redistribution, contact
support@infist.cn.
