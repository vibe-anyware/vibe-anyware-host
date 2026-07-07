---
name: install-vibe-anyware-host
description: |
  Install the Vibe Anyware Mac companion host from source. Clones the source-available
  repo, builds the menu-bar host app, installs it plus a LaunchAgent so it starts
  automatically, then guides Accessibility permission and pairing with the Vibe Anyware
  iPhone app. Use whenever the user wants to set up, install, build, or update the Mac
  side of Vibe Anyware, or says things like "install the Vibe Anyware Mac host",
  "set up my Mac for Vibe Anyware", or "pair my iPhone trackpad with this Mac".
metadata:
  version: "1.0.0"
---

# Install Vibe Anyware Mac Host

The Mac-side companion for the **Vibe Anyware** iPhone app (a wireless trackpad /
keyboard / shortcut pad for your Mac). This skill clones the source-available host
repo, builds it, installs it as a menu-bar app with a LaunchAgent, and walks the user
through granting Accessibility permission and pairing with their iPhone.

> The source is provided under the **Vibe Anyware Source-Available License** — personal
> use with the Vibe Anyware app only, not open source. See the repo's `LICENSE`.

## Overview of what you will do

1. Check prerequisites (macOS 14+, Xcode/Command Line Tools, XcodeGen).
2. Clone (or update) the repo into `~/Developer/vibe-anyware-host`.
3. Generate the Xcode project and run the installer script.
4. Guide the user to grant Accessibility permission.
5. Help them pair: **LAN** (same Wi-Fi) or **Relay** (setup key from the app).

Run the steps in order. Show the user each command's outcome; stop and ask if a step
fails rather than guessing.

## Step 1 — Prerequisites

Check each; install what's missing.

```bash
sw_vers -productVersion            # must be 14.x (Sonoma) or newer
xcode-select -p                    # must print a developer dir; if not: xcode-select --install
command -v xcodegen                # if missing: brew install xcodegen
command -v git
```

- If macOS is older than 14, stop and tell the user the host requires macOS 14+.
- If `xcode-select -p` fails, run `xcode-select --install` and wait for the user to
  finish the GUI install before continuing.
- If `xcodegen` is missing and Homebrew is present, run `brew install xcodegen`. If
  Homebrew is absent, point the user to https://github.com/yonyz/XcodeGen releases.

## Step 2 — Clone or update the repo

```bash
DIR="$HOME/Developer/vibe-anyware-host"
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only
else
  mkdir -p "$HOME/Developer"
  git clone https://github.com/vibe-anyware/vibe-anyware-host.git "$DIR"
fi
cd "$DIR"
```

## Step 3 — Generate project and install

The installer builds in Release, packages `~/Applications/VibeAnyware.app`, installs a
per-user LaunchAgent (`app.vibeanyware.host`), launches it, and prints the LAN IP + port.

```bash
cd "$HOME/Developer/vibe-anyware-host"
xcodegen generate
Scripts/install-macos-host.sh
```

Optional flags (pass through if the user needs them):

| Flag | Purpose |
|------|---------|
| `--port <port>` | LAN listen port (default 45731) |
| `--codesign-identity <id>` | Sign with the user's own Apple Development cert so the Accessibility grant survives rebuilds (recommended for repeat installs) |
| `--official-relay-setup-key <key>` | Configure relay mode from a key the app generates (see Step 5) |
| `--relay <wss://…>` `--server-id` `--relay-access-token` `--relay-command-key` | Manual relay configuration |

> **Tip on the Accessibility grant:** with ad-hoc signing the grant may need re-approving
> after each reinstall. If the user has an Apple Development certificate, running the
> installer with `--codesign-identity "Apple Development: <name> (<TEAMID>)"` gives the
> app a stable identity so the grant persists across rebuilds. Do NOT invent an identity —
> only use one the user provides or one found via `security find-identity -p codesigning -v`.

Note the LAN IP and port the installer prints — the user types them into the app.

## Step 4 — Grant Accessibility permission

macOS needs Accessibility permission for the host to move the pointer and type.

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Enable **VibeAnyware.app** (toggle it on; add it with `+` if not listed).
3. The menu-bar icon shows **Accessibility: Granted** once it's on.

You can open the pane for the user:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

Do not attempt to toggle the permission programmatically — macOS requires the user to
do it themselves.

## Step 5 — Pair with the iPhone app

Confirm the menu bar shows **Accessibility: Granted** and **LAN: listening**, then:

**LAN (same Wi-Fi — simplest):**
1. Open Vibe Anyware on the iPhone → choose **LAN**.
2. Enter the Mac's LAN IP and port shown by the installer.
3. Move a finger on the phone; the Mac pointer should follow.

**Relay (phone and Mac on different networks):**
1. In the app, generate an **official relay setup key**.
2. Re-run the installer with it (reconfigures the running host):
   ```bash
   cd "$HOME/Developer/vibe-anyware-host"
   Scripts/install-macos-host.sh --official-relay-setup-key "<PASTE_KEY>"
   ```
   The key carries the endpoint, server ID, token, and command key — never print it
   back to the user or store it anywhere.

### Screen mirroring (e.g. UU Remote)

If the user mirrors the Mac screen and the pointer looks invisible, tell them to enable
**"Show pointer for screen mirroring"** from the host's menu bar — it draws an on-screen
pointer that mirroring tools can capture. It only shows while the phone is moving the
pointer.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/app.vibeanyware.host 2>/dev/null || true
rm -f ~/Library/LaunchAgents/app.vibeanyware.host.plist
rm -rf ~/Applications/VibeAnyware.app
```

## Safety notes

- Setup keys, relay tokens, and LAN command keys are secrets. Pass them to the installer
  but never echo them back, log them, or write them to files you create.
- Only sign with a code-signing identity the user actually owns.
- If any build or install step fails, show the real error and ask the user how to
  proceed — don't retry blindly or fabricate success.
