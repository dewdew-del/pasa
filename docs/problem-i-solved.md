# The problem I solved (draft, edit in your own words)

**The problem.** Moving a file from an Android phone to a Windows laptop is still annoying. A cable needs the right cord and driver prompts. Messenger or Google Drive needs internet, eats mobile data and shrinks photos and videos. Bluetooth is slow and pairing often fails. I wanted to send a 2 GB video across the table in seconds, with no internet and no account.

**Who it is for.** Students and anyone with an Android phone and a Windows laptop, especially on campus or at home where the Wi-Fi is slow, shared or missing.

**What made it hard.**
- **Finding each other with no internet.** The laptop shows a QR with all its local addresses and a pairing key; the phone tries each one. If they are not on the same Wi-Fi, the laptop starts its own Wi-Fi network and the phone joins it with one tap, so no hotspot and no mobile data are needed.
- **Big files.** Files are streamed in chunks, so a large video never loads fully into memory on either side, and a half-received file is always deleted instead of left broken in Downloads.
- **Security on a shared network.** Every request must carry a random 256-bit key from the QR. "Forget phones" makes a new key so old phones must scan again.
- **Windows Firewall.** Hotspot networks often count as "Public", so the installer adds the firewall rule for all profiles.

**Decisions I am proud of.**
- No Send/Receive choice: one screen, both ways. Files from the laptop download on the phone automatically.
- Remembering the last laptop, so next time it is one tap: **Reconnect**.
- Tauri instead of Electron for the laptop app, so the installer stays small. The APK is split per phone type for a smaller download.
- Simplified the screens after the first version: the logo replaces the app name and there are fewer words.

**What I would do next.** iPhone and Mac support, sending whole folders, and resuming a transfer that was cut off.
