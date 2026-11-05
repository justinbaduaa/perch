# Perch

iMessage in your menu bar. The people you talked to last sit in the menu bar as avatars. Click one and a glass panel grows out of the menu bar with that thread: read it, type a note, drop files in, drag photos out. The expand button opens the thread in Messages. The UI follows [Hoy](https://gethoy.app), with iMessage as the transport instead of CloudKit.

Requires macOS 26 or later.

## Install

```sh
./build.sh          # writes build/Perch.app and build/Perch.dmg
open build/Perch.dmg
```

Drag Perch to Applications, open it, then grant:

- **Full Disk Access**: System Settings > Privacy & Security > Full Disk Access, add Perch, relaunch. Perch reads `~/Library/Messages/chat.db`.
- **Contacts**: prompted on first launch, for names and photos.
- **Automation > Messages**: prompted on your first send.
- **Notifications**: prompted the first time you use Remind me.
- **Accessibility**: prompted the first time you react.
- **Microphone** and **Screen Recording**: prompted the first time you record. After allowing screen recording, reopen Perch.

`build.sh` signs with your first Apple Development identity, so these grants survive rebuilds. The DMG is not notarized: it opens on your Mac, but another Mac's Gatekeeper will block it.

## Interactions

- The menu bar shows the 5 people you talked to last, whoever sent the last message. A new message, in or out, moves that chat to the front.
- Avatars overlap in the menu bar. The one under the pointer parts from its neighbours; nothing else in the menu bar moves.
- "•••" opens every chat behind a search field. Return opens the top match.
- Clicking an avatar shows its name in a pill, which grows into the panel. Clicking another one slides the panel over; clicking the same one, or anywhere else, closes it.
- With the panel open, hovering another avatar changes the composer to "Switch to …".
- A message you send shows at once, dimmed, and settles when Messages writes it. A failed send puts your text back.
- The waveform button records a voice note: Send stops and sends it, × throws it away.
- The record button records the screen with CleanShot X if it's installed (area, window or display, with pause and restart), picking up the file from CleanShot's media folder when you stop. Without CleanShot it opens macOS's capture toolbar; stop with ⌃⌘⎋, since the menu bar's Stop Sharing cancels without a file. The recording then waits in the composer for Send. QuickTime-format recordings are re-encoded as HEVC to fit iMessage's size limit.
- Click anywhere on a voice note to play or pause it. One plays at a time, and closing the panel stops it.
- Clicking a photo zooms it into Quick Look; the arrow keys step through the chat's media. Drag a photo out to copy the file.
- Right-click a message to react (❤️ 👍 👎 😂 ‼️ ❓; your current one takes it off), or for Copy, Share, Show in Finder, Forward to and Remind me. A reminder shows under its message until it fires.
- Reactions go through [Beeper's platform-imessage](https://github.com/beeper/platform-imessage), which drives a hidden second copy of Messages, so your own Messages window never moves.
- Right-click the menu bar item to quit. Reduce Motion skips the grow and parting animations.

## Not supported

- Threaded replies. platform-imessage can send them; Perch doesn't use it for that yet.
- Native voice-message bubbles. Voice notes arrive as audio files, which play inline in Messages.
- Link preview cards. Links are clickable text.
- Deleting or unsending.

## Develop

```sh
swift test                                              # reads a fixture chat.db
open build/Perch.app --env PERCH_DB=/path/to/chat.db   # another database; sends only pretend
```
