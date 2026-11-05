# Perch

iMessage in your menu bar. Your pinned Messages conversations sit in the menu bar as avatars. Click one and a glass panel grows out of the menu bar with that thread: read it, type a note, drop files in, drag photos out. The expand button opens the thread in Messages. The UI follows [Hoy](https://gethoy.app), with iMessage as the transport instead of CloudKit.

Requires macOS 26 or later.

## Install

```sh
./build.sh          # writes build/Perch.app and build/Perch.dmg
open build/Perch.dmg
```

Drag Perch to Applications, open it, then grant:

- **Full Disk Access**: System Settings > Privacy & Security > Full Disk Access, add Perch, relaunch. Perch reads `~/Library/Messages/chat.db` and your Messages pins.
- **Contacts**: prompted on first launch, for names and photos.
- **Automation > Messages**: prompted on your first send.
- **Notifications**: prompted the first time you use Remind me.

`build.sh` signs with your first Apple Development identity, so these grants survive rebuilds. The DMG is not notarized: it opens on your Mac, but another Mac's Gatekeeper will block it.

## Interactions

- Avatars overlap in the menu bar. The one under the pointer parts from its neighbours, and a "•••" appears at the end for chats outside the bar.
- Clicking an avatar shows its name in a pill, which grows into the panel. Clicking another one slides the panel over; clicking the same one, or anywhere else, closes it.
- With the panel open, hovering another avatar changes the composer to "Switch to …".
- A message you send shows at once, dimmed, and settles when Messages writes it. A failed send puts your text back.
- Clicking a photo zooms it into Quick Look; the arrow keys step through the chat's media. Drag a photo out to copy the file.
- Right-click a message for Copy, Share, Show in Finder, Forward to and Remind me. A reminder shows under its message until it fires.
- Right-click the menu bar item to quit. Reduce Motion skips the grow and parting animations.

## Not supported

- Sending tapbacks or threaded replies. Messages has no public API for either. Received tapbacks show under their message.
- Voice, screen and video recording from the composer.
- Link preview cards. Links are clickable text.
- Deleting or unsending.

## Develop

```sh
swift test                                              # reads a fixture chat.db
open build/Perch.app --env PERCH_DB=/path/to/chat.db   # another database; sends only pretend
```
