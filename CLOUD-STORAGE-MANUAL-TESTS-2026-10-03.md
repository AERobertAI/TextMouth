# Cloud library: manual test matrix with VoiceOver steps

October 3, 2026. Written by the real-drive test agent after its opt-in tests passed on Dropbox. Rows marked "in part" are partly covered by the automated tests in `CloudDriveIntegrationTests`. VO means Control-Option. "Use This Library" and "Move Library Here" are the labels planned for the Storage settings work; check them once that branch lands.

## Running the opt-in tests on a drive

The tests work only inside a folder you name in an environment variable, create their own run folder inside it, use small synthetic files (plus the repository's TestData books for the small-library test), and delete everything at the end. Create the folder first, for example:

```
mkdir "$HOME/Library/CloudStorage/Dropbox/TextMouth Cloud Tests"
```

Then run, from the repository root:

```
TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_ROOTS="/Users/<you>/Library/CloudStorage/Dropbox/TextMouth Cloud Tests" \
xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete \
  -only-testing:TextMouthProductionTests/CloudDriveIntegrationTests
```

Several drives are separated by colons. For iCloud Drive and Google Drive the folders are `~/Library/Mobile Documents/com~apple~CloudDocs/TextMouth Cloud Tests` and `~/Library/CloudStorage/GoogleDrive-<account>/My Drive/TextMouth Cloud Tests`. A run moves about 36 MB up and 10 MB down per drive and takes about 30 seconds, or under 20 minutes if every wait hits its limit. Two outcomes are answers, not bugs: Google Drive refusing eviction fails the round-trip test with its message, and iCloud reporting 0 bytes for evicted files or Google ignoring dot-folders is recorded.

## Setup for the manual rows

1. Build a small library that stays in the drive (about 5 MB stays there):

```
TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_ROOTS="$HOME/Library/CloudStorage/Dropbox/TextMouth Cloud Tests" \
TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_KEEP_SMALL_LIBRARY=1 \
xcodebuild test ... -only-testing:TextMouthProductionTests/CloudDriveIntegrationTests/testASmallLibraryForManualTesting
```

2. In TextMouth: press Command-Comma to open Settings; press VO-Right Arrow to the Storage tab, then VO-Space; Tab to "Change Location..." and press Space; press Command-Shift-G, type the path to `Small Library`, and press Return; choose Use This Library.
3. To return to the real library, repeat step 2 with `~/.TextMouth` (Command-Shift-Period shows hidden folders). Use This Library copies nothing, but make a backup first anyway.

## The rows (run each on each drive unless it names one)

- [ ] **1. Move a small library into the drive, then back.** In part. In Finder, create an empty local folder. Remove the download of one book (row 3). Settings, Storage, Change Location..., go to the folder, Move Library Here. Expect a refusal naming the book that is only in the cloud. Choose Download Now from that book's actions (VO-Command-Space), then repeat the move. Expect the size and destination warning spoken, progress announcements, and a working library. Move it into an empty folder in the drive the same way.
- [ ] **2. Use This Library from a second Mac or account.** In part. On the other Mac or account, signed in to the same drive, follow setup step 2. Expect VoiceOver to read "In Cloud" on rows whose files are only in the cloud. Press Return on one. Expect "Downloading <title> from Dropbox.", then the book opens.
- [ ] **3. Remove Download on several books.** In part. Interact with the list (VO-Shift-Down), select one book, and press Shift-Down Arrow twice. Press VO-Command-Space and choose "Remove Downloads of 3 Books". Expect each row to read "In Cloud". Check free space with `df -h /` in Terminal before and after. Choose "Show in Finder" from a row's actions, then press VO-Shift-M in Finder. Expect the menu to offer the drive's download command (Download Now on iCloud Drive, Make available offline on Dropbox).
- [ ] **4. Open an evicted text book and an evicted audiobook, Wi-Fi on.** In part. Remove the downloads of Pride and Prejudice and of a DAISY audiobook. Press Return on Pride and Prejudice. Expect "Downloading ... from Dropbox.", a progress indicator read as a percentage, then the text. Do the same for the audiobook and press Space. Expect playback.
- [ ] **5. Repeat with Wi-Fi off.** While online, remove the download of another book. Run `networksetup -setairportpower en0 off` (`networksetup -listallhardwareports` names the Wi-Fi device; unplug Ethernet too). Press Return on the book. Expect, at once: "This Mac is offline, so the book can't be downloaded from Dropbox. Connect to the internet and try again." and a Try Again button, with no beachball. Turn Wi-Fi back on and press Try Again. Expect the book to download and open.
- [ ] **6. Slow network.** Turn on Network Link Conditioner with the 3G profile. Import a large audiobook (the test books are too small to show this), wait for it to upload, then remove its download. Open it. Expect progress by file, Cancel (Escape) to work, and the app to stay responsive.
- [ ] **7. Remove the download in Finder during playback, then go offline.** In part. Start the audiobook playing. In Finder, press VO-Shift-M on its package and choose Make online-only (Dropbox) or Remove Download (iCloud Drive). Turn Wi-Fi off. Expect playback to continue to the end.
- [ ] **8. Quit Google Drive, then open an evicted book.** Run `osascript -e 'quit app "Google Drive"'`. Open the evicted book. Expect, within about 60 seconds: "Google Drive hasn't downloaded anything for 60 seconds. It may be paused, signed out, or not running." and Try Again, with no hang. Run `open -a "Google Drive"`, then press Try Again.
- [ ] **9. External drive.** Move the library to the drive (row 1's steps). Quit TextMouth, eject the drive (Command-E in Finder), unplug it, and launch TextMouth. Expect "Library Not Available", the reason, the path, and Try Again (Return) and Quit TextMouth buttons, with focus on the message. Plug the drive back in and press Return. Expect the library to open, and `ls /Volumes` to show nothing created for the missing drive.
- [ ] **10. Sign out of Dropbox, or move the library folder to the Trash, and launch.** Expect "Library Not Available" and nothing new under `~/Library/CloudStorage`. A plain rename may instead be followed by the library's bookmark and open normally; that is by design.
- [ ] **11. Two Macs open the same library.** Expect the second to show "TextMouth is also open on "<Mac>" (active ...)." and nothing deleted on either.
- [ ] **12. Optimize Mac Storage (iCloud Drive).** In part. Remove the downloads of most books, then relaunch TextMouth. Expect those books to read "In Cloud" and nothing to download at launch. Check `grep MAINTENANCE_SKIPPED_IN_CLOUD ~/Library/Logs/TextMouth/textmouth_debug.log`.

## What the Dropbox run answered

| Question | Dropbox |
| --- | --- |
| Download and eviction requests | Work: upload within 5 s, eviction immediate, re-download within 1 s |
| Progress subscriptions | Heard, but only 0% and 100% for small files |
| Size of an evicted file | The real size |
| Modification time after re-download | Moves by 9 to 118 ns; microseconds kept |
| Clone after the original's eviction | Stays readable |
| Package renamed in | Published as one item |
| Dot-folder sync | Within 4 s |
| Remove Download while uploading | Refused with "not uploaded" |

Still unverified on Dropbox: the app's own screens and commands (this matrix), behaviour while Dropbox is paused, quit, signed out, or offline, and progress within one large file. iCloud Drive and Google Drive runs wait for the go-ahead.
