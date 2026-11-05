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
- **Accessibility**: prompted the first time you react, reply or change a chat from its menu.
- **Microphone** and **Screen Recording**: prompted the first time you record. After allowing screen recording, reopen Perch.

`build.sh` signs with your first Apple Development identity, so these grants survive rebuilds. The DMG is not notarized: it opens on your Mac, but another Mac's Gatekeeper will block it.

## Interactions

- The menu bar shows your pinned chats, then the people you talked to last, 5 in all. A new message, in or out, moves that chat forward. Right-click an avatar, or a chat in the list behind "•••", for Messages' conversation menu: Pin, Mark as Read or Unread, Hide Alerts, Open in Messages and Delete… (which asks first).
- Avatars overlap in the menu bar and spread out side by side when the pointer is over them or the panel is open; the item keeps one width, so nothing else in the menu bar moves. The hovered avatar's name and last activity show in a pill under it.
- A blue ring marks a chat with something new from them that you haven't opened in Perch or answered.
- "•••" opens every chat behind a search field. Return opens the top match.
- Clicking an avatar shows its name in a pill, which grows into the panel. Clicking another one slides the panel over; clicking the same one, or anywhere else, closes it.
- With the panel open, hovering another avatar changes the composer to "Switch to …".
- A message you send shows at once, dimmed, and settles when Messages writes it. A failed send puts your text back.
- Dropped files, pasted files and pictures (⌘V), the paperclip and finished screen recordings wait in the message box with an × each; Send sends them, then your text.
- The waveform button records a voice note, with a live waveform: Send stops and sends it, × throws it away.
- The record button records the screen with CleanShot X if it's installed (area, window or display, with pause and restart), picking up the file from CleanShot's media folder when you stop. Without CleanShot it opens macOS's capture toolbar; stop with ⌃⌘⎋, since the menu bar's Stop Sharing cancels without a file. The recording then waits in the composer for Send. QuickTime-format recordings are re-encoded as HEVC to fit iMessage's size limit.
- Click anywhere on a voice note to play or pause it. One plays at a time, and closing the panel stops it.
- Clicking a photo zooms it into Quick Look; the arrow keys step through the chat's media. Drag a photo out to copy the file.
- Double-click a message to react (❤️ 👍 👎 😂 ‼️ ❓; your current one takes it off). Right-click for the same reactions, Reply, Copy, Share, Show in Finder, Forward to and Remind me. A reminder shows under its message until it fires.
- Swipe sideways on a message with two fingers, past the arrow, to reply in its thread. The message shows above the text field; × or Esc cancels. Replies show the message they answer above them.
- Reactions, replies, read state, Hide Alerts and Delete go through [Beeper's platform-imessage](https://github.com/beeper/platform-imessage), which drives a hidden second copy of Messages, so your own Messages window never moves.
- Right-click the menu bar item to quit.
- The expand button, and Open in Messages, open the thread in Messages, group chats included. Reduce Motion skips the grow and spread animations.

## Not supported

- Native voice-message bubbles. Voice notes arrive as audio files, which play inline in Messages.
- Link preview cards. Links are clickable text.
- Deleting or unsending.

## Develop

```sh
swift test                                              # reads a fixture chat.db
open build/Perch.app --env PERCH_DB=/path/to/chat.db   # another database; sends only pretend
```
