# Bambu Bar

![Bambu Bar window: a drawn P2S printing a vase in orange PLA, the job at 67% with time left and finish time, pause, stop and speed controls, and nozzle, bed, chamber and fan readings](.github/assets/showcase.webp)

<p align="center">
  <img src=".github/assets/menubar.webp" width="600" alt="Animated menu bar item showing 62% and an hour left, with its panel open: the printer drawing, progress, temperatures and AMS spools; the chamber light turns on, then the print pauses because the filament ran out">
</p>

**Your Bambu Lab printer, one click away in the menu bar.**

Bambu Bar is a native macOS app that shows your 3D printer's progress, temperatures and filament without opening Bambu Studio or Bambu Handy. Glance at the menu bar for percent and time left, click for everything else, or keep a widget on your desktop.

Built with Swift and SwiftUI. No analytics, and no account needed: status and controls stay on your network. Only the optional live camera goes through Bambu Cloud.

[Getting started](#getting-started) · [Features](#features) · [Camera](#live-camera) · [Widgets](#desktop-widgets) · [Compatibility](#compatibility) · [Building](#building-from-source)

> Independent, community-developed software. Not affiliated with or endorsed by Bambu Lab. A P2S is the development printer; other Bambu Lab printers that speak the same LAN protocol (X1, P1, A1, H2) should work.

## Why this app?

The printer is in another room, and the slicer is a big app to keep open just to see how long is left. Bambu Bar keeps the answer in the menu bar: **64% · 1h 02m**. Click it and a panel shows the job, the stage, temperatures, the spool in use and how much filament is left, with pause, stop, light and speed controls right there.

It talks to the printer directly over your network, the same way Bambu Studio does in LAN mode, so it works with the printer still bound to your Bambu account and status never goes through a cloud. The live camera is the one exception: it streams through Bambu Cloud, like in Bambu Studio and Bambu Handy, once you sign in.

## Features

| | What you get |
| --- | --- |
| **Menu bar** | A printer glyph that fills as the print grows, with progress and time left beside it (or just one, or only the icon), and a pause or alert mark when the printer needs you. |
| **Panel** | The job, its stage ("Heating hotend", "Paused: filament ran out"), percentage, layers, time left and finish time; nozzle, bed and chamber temperatures; AMS spools with what's left and the humidity; printer errors in plain English. |
| **Live camera** | The printer's camera on the printer page, streamed through Bambu Cloud the way Bambu Studio shows it. Needs Bambu Studio installed and a sign-in with the Bambu account the printer is bound to; once enabled, it stays connected until turned off or the app quits. |
| **Controls** | Pause, resume, stop (with a confirmation), print speed (Silent, Standard, Sport, Ludicrous) and a chamber light switch. |
| **Drawn to match** | Each printer is drawn as its model, with the part growing in the colour of the filament in use: the P2S/P1S/X1 enclosure, the wider dual-nozzle H2, the open P1P frame, the A1's arch with its AMS Lite, the A1 mini. |
| **Window** | A larger view plus fans, nozzle, door, network, storage and firmware; a Filament page with every spool; a Widgets page that tours every widget size and state. |
| **Several printers** | Bambu Bar watches all of them at once. Switch from the printer name at the top of the panel or the window's sidebar, and choose which one the menu bar shows (or let it pick whichever is busy). |
| **Desktop widgets** | Small, medium and large, one per printer if you like, counting down between updates. |
| **Notifications** | Print finished, failed or canceled, paused (filament runout and the like), new printer errors, and optionally when a print starts. |
| **Easy setup** | Finds printers on your network and reads the access code from Bambu Studio or OrcaSlicer, on this Mac or from a settings file copied from another one. |
| **Mac integration** | Open at Login, no Dock icon while it lives in the menu bar (the icon and menus appear while its window is open), keyboard shortcuts, and it follows the printer when DHCP gives it a new address. |

## Getting started

### Requirements

- **macOS 26 Tahoe or later**, Apple silicon or Intel.
- A Bambu Lab printer on the same local network as the Mac.

### Install and connect

1. Download the latest `Bambu-Bar-<version>-macos.zip` from [Releases](https://github.com/rolottr/bambu-bar/releases), unzip it and move **Bambu Bar.app** to your Applications folder. Or [build it yourself](#building-from-source).
2. Open it. The window lists the printers it finds on your network; pick yours.
3. The **access code** usually fills itself in: if Bambu Studio or OrcaSlicer on this Mac has used the printer, Bambu Bar reads the code from its settings. Slicer on another Mac? Drop that Mac's `~/Library/Application Support/BambuStudio/BambuStudio.conf` onto the setup page. Otherwise read it off the printer: **Settings → Network** on its screen shows the 8-character **Access Code**.
4. Click **Connect**. The menu bar starts showing progress as soon as the printer reports in.

The access code is stored in your keychain and only ever sent to the printer. If it changes later (after a factory reset, say) and the slicer has the new one, Bambu Bar offers to use it.

Closing the window keeps Bambu Bar running in the menu bar without a Dock icon. Opened at login, it starts quietly in the menu bar; open it from Spotlight or the menu bar to see the window. **Add Printer…** in the printer picker or in Settings adds another printer.

### About downloaded builds

Builds on the [Releases](https://github.com/rolottr/bambu-bar/releases) page are **universal, Developer ID signed and notarized by Apple**, so they open normally after you download them. Builds you make yourself without a Developer ID certificate, and the artifacts of the [Actions](https://github.com/rolottr/bambu-bar/actions/workflows/build.yml) workflow, are ad-hoc signed: they run on the Mac that built them, but the desktop widget only loads in a Developer ID signed copy.

### Controlling prints

Reading status and the chamber light work in any mode, over the local network (on H2 printers both chamber lights switch together). Since Bambu Lab's 2025 firmware, printers outside Developer Mode accept pause, resume, stop and speed changes only when they're signed the way Bambu's own apps sign them. For those printers Bambu Bar sends these commands through Bambu Cloud using the same helper and requirements as the [live camera](#live-camera): **Bambu Studio** installed and opened once, and your **Bambu account** signed in under Settings. Bambu Studio's network plugin does the signing. The session runs while a print is active (or the camera is on). If something is missing, the buttons show a lock and say what to do. Printers in LAN Only mode with Developer Mode on still take the commands directly over the local network.

## Live camera

The printer page has a camera card. Press play once; the stream stays connected when you switch tabs or close the window, until you turn it off or quit Bambu Bar. Reopening the printer page reuses the live stream. If left enabled, it reconnects on the next app launch.

- **Sign in** under Settings → Bambu account, with the account the printer is bound to (email with a password or an emailed code, plus a 2FA code if your account has one).
- **Bambu Studio** must be installed and opened once, so it has downloaded its network plugin. Bambu Bar's `bambu-camera` helper loads that plugin (`~/Library/Application Support/BambuStudio/plugins`) to ask Bambu for the camera link and play the stream; the same session carries signed print commands. It runs as its own process, so the plugin can't take the app down, and it's the only part of the app that loads code not signed by Bambu Bar.
- The stream is the printer's own H.264 video, decoded by macOS. It stops when you leave the page, close the window or the Mac sleeps.
- Most printers serve one remote viewer at a time: with the camera open in Bambu Studio or Bambu Handy, Bambu Bar says it's in use.

The camera runs inside the app bundle without Docker or a separate relay. Its helper uses the installed networking plugin's native signing metadata for cloud camera requests. This was verified on an H2C with macOS networking plugin `02.08.02.60`; plugin updates may require compatibility changes.
- No LAN Only mode or LAN Only Liveview is needed.

## Desktop widgets

<p align="center">
  <img src=".github/assets/widgets.webp" width="480" alt="The Bambu Bar widget morphing from small to medium to large while a print plays through printing, paused and finished">
</p>

- **Small:** a progress ring with the percentage, time left, the filament going in, and the finish time and layers. Paused, it says why; finished, how long ago and how long it took; idle, the temperatures and loaded spools.
- **Medium:** the drawn printer with the part growing, the job and its progress, finish time, layers and temperatures.
- **Large:** everything: temperature tiles, every AMS spool with what's left, the newest error in plain words and how the last print went.

To add one, right-click the desktop and choose **Edit Widgets…**, search for **Bambu Bar** and drag the size you want onto the desktop or into Notification Center. With more than one printer, right-click a widget and choose **Edit "Printer"** to pick which printer it shows; a widget left empty follows the menu bar printer.

The widget shows what the app last saw, so keep Bambu Bar running (Open at Login does that). While a print runs, the widget projects progress and time left forward on its own between updates.

## Compatibility

| Printer | Status |
| --- | --- |
| **P2S** | Development printer; verified with firmware **01.03.00.00** and an AMS 2 Pro. |
| **X1, P1, A1, H2 families** | Same LAN protocol and certificate authorities; implemented, not verified on hardware. |

The printer can be in cloud mode or LAN Only mode; in cloud mode, controls go through Bambu Cloud (see [Controlling prints](#controlling-prints)). The live camera works in cloud mode (see [Live camera](#live-camera)).

If you try another model, [open an issue](https://github.com/rolottr/bambu-bar/issues) with the model, firmware, macOS version and what worked. Run `--probe` (below) for a report; remove the serial number and access code before posting it.

## How it works

Bambu printers run an MQTT broker on port 8883. Bambu Bar connects to it over TLS 1.2 (the P2S doesn't answer TLS 1.3), signs in as `bblp` with the access code, and accepts the printer only if its certificate chains to Bambu Lab's own certificate authorities, which ship with the app, *and* is issued to the printer's serial number, so no other device on the network can collect the code. It asks once for a full report and then merges the changes the printer sends about once a second.

Printers announce themselves on UDP port 2021; that's how Bambu Bar lists them during setup and notices when one moves to a new address. The widgets read a snapshot the app writes to an app group container on this Mac.

## Privacy and local storage

No analytics. Status and controls go only to your printers on your local network. The live camera is opt-in: it needs a Bambu account sign-in and streams through Bambu's cloud.

- **Bambu account session (camera only):** your login keychain. It's sent only to Bambu (`api.bambulab.com`) and to Bambu Studio's network plugin, which opens the camera.
- **Camera log:** `~/Library/Logs/Bambu Bar/camera.log`, the last camera session's steps (no tokens or camera links).

- **Printers (address, serial, name) and preferences:** local macOS user defaults.
- **Access codes:** your login keychain.
- **Last prints** (for "Last: …" and finish times, only what the app saw while running): `~/Library/Application Support/Bambu Bar/history.json`.
- **Widget snapshot:** `~/Library/Group Containers/<team>.dev.rolottr.BambuBar/printers.json`.

## Building from source

Requirements: Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). No third-party Swift packages.

```sh
git clone https://github.com/rolottr/bambu-bar.git
cd bambu-bar
./scripts/build.sh               # build/App.noindex/Bambu Bar.app (universal, release)
./scripts/install.sh             # copy to /Applications and open it
./scripts/install.sh --build     # rebuild first
```

To sign with your own team, put `DEVELOPMENT_TEAM = <your team id>` in `Config/Local.xcconfig` (gitignored). Xcode then runs Debug builds with your Apple Development identity (run `xcodegen generate` once, open `BambuBar.xcodeproj`, press Run), and `build.sh` signs with that team's Developer ID.

To run from Xcode, put your team in `Config/Local.xcconfig` (not checked in), e.g. `DEVELOPMENT_TEAM = ABCDE12345`, run `xcodegen generate` and open `BambuBar.xcodeproj`. Debug builds sign automatically with your Apple Development certificate; Release builds use Developer ID.

`build.sh` generates the Xcode project from `project.yml`, builds the app and its widget extension, and signs both with the **Developer ID Application** identity of your team (from `Config/Local.xcconfig`, else the first one in your keychain) (override with `SIGN_IDENTITY=…`; set `TEAM_ID` to match its team, which names the app group the widget shares). Without one the app is signed ad hoc and works without the widget. `CONFIG=Debug` and `ARCHS=arm64` are available. Builds go into a `.noindex` folder so Spotlight and Launchpad only ever find the installed copy.

### Package and notarize a release

```sh
NOTARY_PROFILE=<profile> ./scripts/package.sh
```

This makes a universal release build signed with Developer ID, the Hardened Runtime and a secure timestamp, submits it to Apple's notary service, staples the ticket and checks it with Gatekeeper, then writes `build/Bambu-Bar-<version>-macos.zip` and its SHA-256 checksum. The profile is a [notarytool keychain profile](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) (`xcrun notarytool store-credentials`). Without `NOTARY_PROFILE` it packages the signed build without notarizing.

To verify a download, run this next to both files:

```sh
shasum -a 256 -c Bambu-Bar-1.0.0-macos.zip.sha256
```

The [GitHub Actions workflow](.github/workflows/build.yml) builds and uploads an ad-hoc signed ZIP on pushes and pull requests. It does not sign, notarize or publish a release.

### Developing without a printer

- `--demo [printing|preparing|paused|finished|failed|idle|offline|unconfigured]` runs a simulated P2S; add `--fleet` for three printers. Nothing is saved and no network is used.
- `scripts/emulator/printer.py` runs a pretend P2S on `127.0.0.1:8883` (needs `brew install mosquitto`): a TLS MQTT broker that replays a real P2S report, then prints, heats and obeys pause, resume, stop, speed and light. Connect with
  `"build/App.noindex/Bambu Bar.app/Contents/MacOS/Bambu Bar" --connect 127.0.0.1 22E00EMULATOR0 12345678 --insecure-tls`
- `--probe <ip> <serial> <access-code>` connects to a real printer from Terminal and prints what it reports.
- `scripts/showcase.sh <dir>` screenshots the panel, window and widgets in each demo state; `scripts/make-readme-animations.sh` renders the animations above, offscreen, from the demo printer.
- `scripts/make-hms.py` regenerates the bundled error texts.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘1` – `⌘5` | Printer, Filament, Widgets, Settings, About. |
| `⌘R` | Ask the printer for a full report. |
| `⌘L` | Turn the chamber light on or off. |
| `⌘,` | Settings. |

The **Printer** menu also switches printers, adds one, and pauses, resumes or stops the print.

## Credits and license

Created by [rolottr](https://github.com/rolottr). Released under the [MIT License](LICENSE).

Protocol details, a real P2S report and the English HMS error texts come from [ha-bambulab](https://github.com/greghesp/ha-bambulab) (MIT), which also provided Bambu Lab's certificate authorities that ship with the app. [Bambuddy](https://github.com/maziggy/bambuddy) and [bambu-cli](https://github.com/tobiasbischoff/bambu-cli) helped map the newer printers, and the access-code import follows [Bambu Studio](https://github.com/bambulab/BambuStudio)'s settings format.

Bambu Lab, Bambu Studio, Bambu Handy, AMS and P2S are trademarks of Bambu Lab. This project is not affiliated with Bambu Lab.
