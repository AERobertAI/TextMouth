# Syncing on the iPhone
<!-- id: syncing-on-iphone; keys: iPhone, sync, Settings, Files, iCloud Drive, TextMouth Sync, VoiceOver; src: TextMouth/Platform/iOS/Views/Settings/PhoneSyncSettingsSection.swift, TextMouth/Phone/PhoneSyncSettingsModel.swift -->

Part of [TextMouth's documentation](../../README.md).

This page is the iPhone's half of [Syncing your library between your devices](syncing-your-library.md), which says what sync carries, when it runs, and what the status line means.
The words are the Mac's, with "this iPhone" where the Mac says "this Mac", and "your Mac" where the Mac says "iPhone".
Everything here is words that VoiceOver and a braille display read; nothing depends on colour or position.

## The Sync section
<!-- id: iphone-sync-section; keys: Settings, Set Up Sync, Join Sync Folder, Sync Now, Stop Syncing, status, About; src: TextMouth/Platform/iOS/Views/Settings/PhoneSyncSettingsSection.swift, TextMouth/Phone/PhoneSyncSettingsModel.swift, TextMouth/Phone/PhoneSettingsModel.swift -->

Settings ends with the Sync section, after About.
VoiceOver reads, in order, the heading Sync, "Keeps your books, places, and bookmarks the same on your Mac and iPhone, through iCloud Drive.", the status line, and the buttons.
The status line and the lines after it (who was last heard from, how far the backup is) are one element.

- With sync off the status line says "Sync is off." and the buttons are Set Up Sync… and Join Sync Folder….
- With sync on they are Sync Now and Stop Syncing….
  Sync Now is dimmed while a sync runs.

When the buttons change, VoiceOver's focus goes to the status line, so it is never left on a button that has gone.
While Set Up or Join works, the status line says "Syncing…", or for Join "Waiting for the sync folder's files to arrive from iCloud Drive.", and both buttons are dimmed.
When it ends, VoiceOver hears the status line, and a refusal or failure is a line of words under it that is spoken too.

## Setting up and joining
<!-- id: iphone-set-up-join; keys: Files picker, folder picker, bookmark, security scope, Recently Deleted; src: TextMouth/Platform/iOS/Views/Settings/PhoneSyncSettingsSection.swift, TextMouth/Platform/iOS/Services/PhoneSyncFolderAccess.swift, TextMouth/Phone/PhoneSyncSettingsModel.swift -->

Both buttons open the system's folder picker, which is Files.
- Set Up Sync…: choose a folder in iCloud Drive; TextMouth makes TextMouth Sync in it.
- Join Sync Folder…: choose the TextMouth Sync folder the Mac made.
  TextMouth waits up to 60 seconds for the folder's `store.json` to arrive from iCloud Drive.

Cancelling the picker changes nothing, and VoiceOver's focus comes back to the status line.
TextMouth keeps the folder as a bookmark.
If you move or rename the folder, the bookmark is renewed.
If you delete it, so that it is in Recently Deleted, it counts as gone: the status line says "TextMouth can't find the TextMouth Sync folder in iCloud Drive.
It may have been moved or deleted, or iCloud Drive signed out.
Your library on this iPhone is as it was."

What sync refuses is the Mac's list, with two sentences of the iPhone's own:
- "Sync needs a library kept on this iPhone, and this one isn't."
- Stop Syncing's question says "on this iPhone".

## Sync Now
<!-- id: iphone-sync-now; keys: Actions rotor, library summary, VoiceOver action, summary line; src: TextMouth/Platform/iOS/Views/Settings/PhoneSyncSettingsSection.swift, TextMouth/Phone/PhoneSyncSettingsModel.swift -->

Sync Now is the Sync section's button, and a VoiceOver action on the library's summary line ("743 books.
14 hours left."): move to the summary and choose it from the Actions rotor.
The action exists only while sync is on.
VoiceOver hears "Syncing.", then "Synced.
4 changes from" and the name the other device gives itself, "Synced.
Nothing new.", or the status line.

## When sync runs on the iPhone
<!-- id: iphone-when-sync-runs; keys: launch, active, background, 20 seconds, hourly; src: TextMouth/Phone/PhoneSyncLifeCycle.swift, TextMouth/Services/Sync/SyncScheduler.swift -->

The moments are the Mac's (launch, hourly, the network coming back, three minutes after a change, Sync Now), and two of the iPhone's life cycle:
- Each time TextMouth becomes active after the first, it syncs.
- When TextMouth goes to the background, it records and sends its outbox, and reads nothing.
  It asks the system for time to do this, at most 20 seconds, and ends the request when the send is done or the limit is reached, whichever is first.

Changes made with no network stay on the iPhone until iCloud Drive has uploaded them; the status line counts them.

## Keep on All Devices on the iPhone
<!-- id: iphone-keep-all-devices; keys: row action, Kept on all devices, switch, Book Information; src: TextMouth/Phone/PhoneLibraryOffer.swift, TextMouth/Phone/PhoneLibraryRows.swift, TextMouth/Platform/iOS/Views/Library/PhoneBookInfoSheet.swift, TextMouth/Phone/PhoneSyncSettingsModel.swift -->

While sync is on, a book's actions offer Keep on All Devices, or Stop Keeping on All Devices for a book kept already.
Book Information has a switch, "Kept on all devices", with the hint "Every device that syncs keeps this book's files, and downloads them when it can."
A kept book's row is read with ", Kept on all devices" after its other words.
VoiceOver hears "Keeping Moby-Dick on all devices." or "No longer keeping Moby-Dick on all devices."; a choice that is already so changes and says nothing.

The reading list's books are kept too, and the iPhone has no switch to turn that off.

## Books on the iPhone
<!-- id: iphone-books-downloads; keys: In Cloud, download on open, Wi-Fi, cellular, Low Data Mode, iCloud Backup; src: TextMouth/Services/Sync/StoreFetch.swift, TextMouth/Services/Sync/StoreBookStorage.swift, TextMouth/ViewModels/LibraryViewModel+Sync.swift -->

The Mac's books arrive as rows saying In Cloud, as soon as their copies have uploaded; opening one fetches its files, and shows the download view with Cancel and Try Again.
After each sync, kept books download by themselves, one at a time, only on Wi-Fi with Low Data Mode off, and only as far as the free space less 1 GB allows.
On cellular data nothing downloads unasked; a book you open downloads, and a download that stalls for 60 seconds says "iCloud Drive stopped sending this book's files.
If iCloud Drive can't use cellular data, connect to Wi-Fi."
Each book fetched is left out of the iPhone's iCloud Backup, since its files are in the sync folder already.

## Saving space on the iPhone
<!-- id: iphone-saving-space; keys: Books on this device, Books you open or keep, 7 days, Remove Download, stepper; src: TextMouth/Views/Settings/SyncSpaceControls.swift, TextMouth/Phone/PhoneLibraryOffer.swift, TextMouth/Platform/iOS/Views/Library/PhoneBookInfoSheet.swift, TextMouth/Platform/iOS/Views/Library/PhoneLibraryView.swift -->

The Sync section, once sync is on, has the Mac's two settings with the iPhone's first values: Books on this device is Books you open or keep, and Remove unopened downloads after is 7 days.
The days are one adjustable element: VoiceOver reads its label, value, and hint, and each step says the new value once.
[Syncing your library](syncing-your-library.md) says what the settings do and when a download is never removed.

Remove Download is a row action and a button in Book Information, for a book whole on the iPhone.
A refusal is an alert in words, and the iPhone never downloads over cellular data to check a copy: it says the book waits for Wi-Fi.
Stop Syncing's question counts the books only in iCloud Drive, as the Mac's does.

## What isn't synced yet on the iPhone
<!-- id: iphone-not-yet; keys: settings, feeds, text edits, Remove Download; src: TextMouth/Models/Sync/SyncProjection.swift; status: incomplete; issues: FR43 -->

What the Mac's page lists as not synced is not synced here either.
The iPhone's own settings are separate from the Mac's.
