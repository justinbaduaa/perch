# Perch

iMessage in your menu bar. Your pinned Messages conversations sit in the menu bar as avatars. Click one and a glass panel drops down with that thread: read it, type a note, drop files in, drag photos out. The expand button opens the thread in Messages. The UI follows [Hoy](https://gethoy.app), with iMessage as the transport instead of CloudKit.

Requires macOS 26 or later.

## Run

```sh
./build.sh
open build/Perch.app
```

Then grant:

- **Full Disk Access**: System Settings > Privacy & Security > Full Disk Access, add `build/Perch.app`, relaunch. Perch reads `~/Library/Messages/chat.db` and your Messages pins.
- **Contacts**: prompted on first launch, for names and photos.
- **Automation > Messages**: prompted on your first send.

`build.sh` signs with your first Apple Development identity, so these grants survive rebuilds. With no identity it signs ad hoc, and macOS asks again after every build.

## How it works

- Reads `chat.db` read-only and checks for new rows every 1.5 s.
- The menu bar shows your Messages pins, or your 5 most recent chats if Perch can't read the pins.
- Sends go through Messages' AppleScript in an `osascript` child process. Files are copied into `~/Library/Messages/Attachments/Perch/` first because Messages won't reliably send from other folders.
- Right-click a message for Copy, Share, Show in Finder and Remind me. Right-click the menu bar item to quit.

## Not supported

- Sending tapbacks or threaded replies. Messages has no public API for either. Received tapbacks show under their message.
- Voice, screen and video recording from the composer.
- Link preview cards. Links are clickable text.
- Deleting or unsending.

## Develop

```sh
swift test                       # reads a fixture chat.db
open build/Perch.app --env PERCH_DB=/path/to/chat.db   # point at another database
```
