# Perch

iMessage in your menu bar. The people you talked to last sit in the menu bar as avatars. Click one and a glass panel grows out of the menu bar with that thread: read it, type a note, drop files in, drag photos out. The expand button opens the thread in Messages. The UI follows [Hoy](https://gethoy.app), with iMessage as the transport instead of CloudKit.

Requires macOS 26 or later.

## Install

Download [Perch.dmg](https://github.com/justinbaduaa/perch/releases/latest/download/Perch.dmg), the newest release, and drag Perch to Applications. It isn't notarized, so macOS blocks the first open: click Open Anyway in System Settings > Privacy & Security. `./build.sh` builds the same `build/Perch.app` and `build/Perch.dmg` locally.

The first launch opens Set up Perch, which lists every permission with its own Allow button and ticks each one off as macOS grants it, so no feature stops to ask later. Allow All runs every prompt macOS can show there, one after another.

- **Full Disk Access** reads `~/Library/Messages/chat.db`. macOS has no prompt for it: Open Settings, then drag Perch from the window into the list.
- **Contacts** for names and photos, **Messages** (Automation) to send, **Accessibility** for reactions, replies and chat actions, **Notifications** for Remind me, and **Microphone** for voice notes.
- **Screen Recording** is listed only without CleanShot X, which captures for Perch otherwise.

Setup opens at every launch until Full Disk Access is on, and until you close it once. Right-click the menu bar for Set Up Perch… to see it again.

These grants survive updates because every build is signed with Perch's own certificate, `~/.config/perch/perch.p12`. Without that file `build.sh` signs ad-hoc, and each build asks again.

## Release

```sh
git tag v0.3 && git push origin v0.3
```

GitHub then builds Perch, runs the tests and publishes Perch.dmg as that version, and the download link above moves to it. The certificate is the repo secret `PERCH_P12`, the base64 of `perch.p12`. Keep a copy of that file somewhere safe: a release signed with any other certificate makes everyone grant Full Disk Access and the rest again.

## Interactions

- The menu bar shows your pinned chats, then the people you talked to last, 5 in all. A new message, in or out, moves that chat forward. Right-click an avatar, or a chat in the list behind "•••", for Messages' conversation menu: Pin, Mark as Read or Unread, Hide Alerts, Open in Messages and Delete… (which asks first).
- Avatars overlap in the menu bar, and the item is only as wide as that stack (85 pt with six slots). When the pointer is over them or the panel is open, they spread out side by side in a glass capsule floating over the menu bar, so nothing else in the menu bar moves. The hovered avatar's name and last activity show in a pill under it.
- A blue ring marks a chat with something new from them that you haven't opened in Perch or answered.
- "•••" opens every chat behind a search field. Return opens the top match.
- Clicking an avatar shows its name in a pill, which grows into the panel. Clicking another one slides the panel over; clicking the same one, or anywhere else, closes it.
- With the panel open, hovering another avatar changes the composer to "Switch to …".
- A message you send shows at once with Sending… under it, and goes out after the ones before it, so they arrive in order. Your last message then says Sent, Delivered, Read or Not Delivered, as in Messages. A failed send puts your text back.
- Drag a file toward the faces in the menu bar and a pill drops under the nearest one, "Drop to Ashley", following you from face to face. Let go and that chat opens with the file in its message box.
- Dropped files, pasted files and pictures (⌘V), the paperclip and screen captures wait in the message box with an × each; Send sends them, then your text.
- The waveform button records a voice note, with a live waveform: Send stops and sends it, × throws it away.
- The capture button opens CleanShot X's All-In-One if it's installed: pick an area, window or display, then take a screenshot, a recording or a GIF, and Perch picks up the file from CleanShot's media folder. Without CleanShot it opens macOS's capture toolbar, for a screenshot or a recording; stop a recording with ⌃⌘⎋, since the menu bar's Stop Sharing cancels without a file. The capture then waits in the composer for Send. QuickTime-format recordings are re-encoded as HEVC to fit iMessage's size limit.
- Scrolled up in a thread, a blue See more button sits above the message box; click it to scroll back down to the newest message.
- Click anywhere on a voice note to play or pause it. One plays at a time, and closing the panel stops it.
- Links show as cards with the page's picture, title and site, read from the preview Messages saved, so Perch fetches nothing itself. Click one to open it.
- Reactions sit in circles on the bubble's top corner, yours in blue.
- Four or more photos in one message sit in a stack under their count, as in Messages; click the count to open them out into a grid. Clicking a photo zooms it into Quick Look; the arrow keys step through the chat's media. Drag a photo out to copy the file.
- Double-click a message to react: ❤️ 👍 👎 😂 ‼️ ❓, then your five most recent emoji (the same row as Messages) and a smiley for any other. Your current one takes it off. Custom emoji go out in the default skin tone. Right-click for the same reactions, Reply, Copy, Share, Show in Finder, Forward to and Remind me. A reminder shows under its message until it fires.
- Swipe their message right or yours left with two fingers, past the arrow, to reply in its thread. The message shows above the text field; × or Esc cancels. Replies show the message they answer above them.
- Reactions, replies, read state, Hide Alerts and Delete go through [Beeper's platform-imessage](https://github.com/beeper/platform-imessage), which drives Messages through Accessibility without bringing its window up.
- Right-click the menu bar item to quit.
- The expand button, and Open in Messages, open the thread in Messages, group chats included. Reduce Motion skips the grow and spread animations.

## Not supported

- Native voice-message bubbles. Voice notes arrive as audio files, which play inline in Messages.
- Deleting or unsending.

## Develop

```sh
swift test                                              # reads a fixture chat.db
open build/Perch.app --env PERCH_DB=/path/to/chat.db   # another database; sends only pretend
```
