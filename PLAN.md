# Pasa: Offline File Transfer, Phone <-> Laptop
(Pasa = "pass / hand over")

Status: In progress — v0.1.0 built 2026-11-11, needs real-phone test. Implementation plan: `docs/superpowers/plans/2026-11-11-pasa.md`

## What it is
A phone app (Android) + laptop app (Windows) for moving files between them. No internet needed. Goal: fast, easy, light.

## Locked decisions
| Topic | Decision |
|---|---|
| Phone side | Flutter app, installed as APK. Android 11+ only (minSdk 30). |
| Laptop side | Tauri 2 (Rust backend, plain HTML/CSS/JS UI, no framework, no bundler). Windows only. |
| Flow | One screen, both ways. Laptop app opens straight to its QR. Phone scans it. After that both sides show "Send files" + a transfer list. No Send/Receive choice. |
| Laptop -> phone | Phone downloads automatically (no Accept/Decline). |
| Reconnect | Laptop keeps a saved pairing key. Phone remembers the last laptop and shows "Reconnect to <name>". Falls back to scanning if the laptop's address changed. Laptop has "Forget phones" (new key, old phones must rescan). |
| v1 scope | Progress bar + speed, many files at once, drag-and-drop on laptop, cancel a transfer. |
| Theme | Follow system light/dark on both apps. One accent color: `#1A5FD6 (dark: #5C9CFF)`. |

## How it works
1. Laptop app starts an HTTP server on port 47800 (falls back to a random free port if busy) and shows a QR.
2. QR = `pasa://connect?v=1&h=<ip1>,<ip2>&p=<port>&k=<key>&n=<laptop name>`. All the laptop's LAN IPv4 addresses are listed; the phone tries them all and uses the first that answers.
3. Every request carries `Authorization: Bearer <key>`. Wrong/missing key = 401.
4. Phone -> laptop: phone uploads one file at a time, streamed. Laptop saves to `Downloads\Pasa`.
5. Laptop -> phone: laptop puts files in an outbox. Phone checks the outbox every second and downloads each file, streamed, to `Download/Pasa`.
6. Same-name files get ` (1)`, ` (2)` ... added. Half-finished files are always deleted, never left in Downloads.

## Network (no internet needed)
- Same network: shared Wi-Fi or a phone hotspot (recommended).
- Wi-Fi Direct and Bluetooth skipped (hard to build / slow / patchy desktop support).
- Windows Firewall: the installer adds an inbound allow rule for Pasa on all network profiles (hotspots often count as "Public").

## Stack (all free, P0)
- Mobile: Flutter (`mobile_scanner`, `http`, `file_picker`, `shared_preferences`, `wakelock_plus`)
- Desktop: Tauri 2 + axum (HTTP server) + `qrcode`
- No backend, no database, no hosting
- Distribution: APK + Windows installer (NSIS) via GitHub Releases
- Skip iOS, Play Store and Windows code signing.

## Later (not v1)
- Received-files history across restarts
- Open received file from the phone app
- Resume a broken transfer

## Done checklist
- [ ] Installable builds (APK + Windows installer)
- [ ] README with screenshots
- [ ] 30-second demo video
- [ ] "Problem I solved" note for the portfolio
- [ ] Pushed to GitHub
