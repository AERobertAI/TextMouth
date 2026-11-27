# Syncing your library between your devices
<!-- id: syncing-your-library; keys: sync, iCloud Drive, TextMouth Sync, iPhone, two devices, Storage settings; src: TextMouth/Platform/macOS/Views/SyncSettingsSection.swift, TextMouth/ViewModels/SyncSettingsModel.swift, TextMouth/Services/Sync/SyncCenter.swift -->

Part of [TextMouth's documentation](../../README.md).

Sync keeps one library the same on your Mac and your iPhone, through a folder in iCloud Drive.
This page is for the Mac; [Syncing on the iPhone](syncing-on-iphone.md) says what the iPhone's screens read and do.

Each device keeps its own whole library on its own disk, and keeps working with no network.
What one device changes goes into a small file, which iCloud Drive carries to the other, and each device merges what it finds.
Nothing is asked of you after the set-up: sync runs by itself, and Sync Now runs it at once.

Nothing exists until you choose a folder: with sync off, TextMouth makes no file, runs no task, and says nothing about sync.

## What sync carries
<!-- id: sync-what-carries; keys: places, bookmarks, skipped headings, folders, reading list, removals, added books; src: TextMouth/Models/Sync/SyncProjection.swift, TextMouth/Models/Sync/SyncInterfaces.swift -->

Both ways, each device keeping the latest change of each thing:
- the books you add, and the books you remove;
- each book's place, bookmarks, and skipped headings;
- each book's details, such as title and author, and its own voice and speed settings;
- folders, and which book is in which;
- the reading list, its order, and its options.

A book's files are not carried at once.
A book you add on one device reaches the other as a row marked In Cloud, once its files have uploaded to iCloud Drive; opening the row, or Download Now, brings the files in.
A book's files are on a device only where it is downloaded or kept; every other book there is a placeholder.

## Setting up
<!-- id: sync-setting-up; keys: Set Up Sync, Join Sync Folder, Storage tab, folder panel, TextMouth Sync folder, first sync; src: TextMouth/Platform/macOS/Views/SyncSettingsSection.swift, TextMouth/ViewModels/SyncSettingsModel.swift, TextMouth/Models/Sync/SyncWording.swift -->

Open Settings, then the Storage tab; the Sync section comes after Library maintenance.
VoiceOver reads the heading Sync, a line saying what sync does, the status line, and then the buttons.
With sync off the status line says "Sync is off." and the buttons are Set Up Sync… and Join Sync Folder….

- Set Up Sync… is for the first device.
  It opens a folder panel as a sheet on the Settings window, titled Set Up Sync, where you choose a folder in iCloud Drive.
  TextMouth makes a folder named TextMouth Sync in it, and copies your books into it in the background.
- Join Sync Folder… is for every other device.
  Its panel, titled Join Sync Folder, cannot make folders: you choose the TextMouth Sync folder another device made.
  If that folder's files haven't arrived from iCloud Drive, VoiceOver hears "Waiting for the sync folder's files to arrive from iCloud Drive.", and TextMouth waits up to 60 seconds.

When it works, VoiceOver hears "Syncing…", the Set Up and Join buttons become Sync Now and Stop Syncing…, and VoiceOver's focus moves to the status line, so the button you pressed leaving does not lose it.
When the first sync ends, VoiceOver hears the status line.
A refusal or failure is a red line of words under the status line, and VoiceOver hears it as well.

## What sync refuses
<!-- id: sync-refusals; keys: not in iCloud Drive, library in a cloud folder, Change Location, already there, another library's sync; src: TextMouth/ViewModels/SyncSettingsModel.swift, TextMouth/Models/Sync/SyncWording.swift, TextMouth/Services/Sync/SyncCenter.swift -->

Sync works only for a library kept on this Mac's own disk, with its sync folder in iCloud Drive.
The first refusal below says why: a library in iCloud Drive, Dropbox, or Google Drive is kept by that drive, and two services would work over the same files.
Each refusal changes nothing, and is spoken:
- "Sync is for a library kept on this Mac.
  Move this one here with Change Location first."
  (see [Where TextMouth keeps your library](where-your-library-lives.md));
- "That folder isn't in iCloud Drive.
  Choose a folder in iCloud Drive.";
- Set Up Sync, finding a folder named TextMouth Sync already there: "A folder named TextMouth Sync is already there.
  To use it, choose Join Sync Folder.";
- Join Sync Folder, finding no store: "That isn't a TextMouth Sync folder, or its files haven't arrived from iCloud Drive yet.";
- a folder that now holds another library's sync: "The sync folder now holds another library's sync.
  Choose Join Sync Folder again.";
- iCloud Drive with no room, while setting up: "iCloud Drive is full.
  Free some space in iCloud Drive, then try again."

## The status line
<!-- id: sync-status-line; keys: Up to date, Offline, Syncing, last synced, Last heard from, Backing up books, VoiceOver status; src: TextMouth/Services/Sync/SyncStatusLine.swift, TextMouth/Models/Sync/SyncWording.swift -->

The status line says the first of these that is true, in this order:
1. "Sync is off."
2. "Syncing…"
3. "Offline.
   3 changes wait on this Mac, and will be sent when the network is back."
4. "TextMouth can't find the TextMouth Sync folder in iCloud Drive.
   It may have been moved or deleted, or iCloud Drive signed out.
   Your library on this Mac is as it was."
5. "iCloud Drive is full, so 3 changes and 138 books aren't uploaded.
   Your library on this Mac is as it was."
6. "A later TextMouth made this sync folder.
   Update TextMouth to use it."
7. A mass removal held back (see below).
8. "3 changes are waiting for iCloud Drive to upload them."
9. "Some changes from iPhone haven't downloaded yet.
   TextMouth will try again."
10. "Up to date.
    Last synced at 9:41 AM."

The sentences for a folder that isn't a sync folder, another library's sync, a folder outside iCloud Drive, and a library in a cloud folder (the refusals above) are spoken in the same place when they come up while syncing.
After the status line, in the same element for VoiceOver, come lines that apply: "Last heard from iPhone at 9:40 AM." for each other device, and "Backing up books: 612 of 750." while books are copied into the folder.

## Sync Now
<!-- id: sync-now; keys: Command-Option-S, Option-Command-S, Library menu, announcement, VoiceOver; src: TextMouth/App/MenuCommands.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Services/Sync/SyncCenter.swift -->

Sync Now runs a sync at once.
It is the button in the Sync section, and the Library menu's Sync Now, whose default key is Command-Option-S; Settings' Shortcuts tab can change it.
The menu item and the button exist only while sync is on, and the button is dimmed while a sync runs.

VoiceOver hears "Syncing.", and when the sync ends one of:
- "Synced.
  4 changes from iPhone.", naming the device the changes came from as it names itself;
- "Synced.
  Nothing new.";
- the status line, when something is wrong or changes are still waiting.

A sync already running makes one more run after it, and Sync Now then says nothing new.
Automatic syncs are silent, but for one notice when sync stops working, and "Moved to the place saved on iPhone." for an open book, below.

## When sync runs
<!-- id: sync-when-runs; keys: launch, hourly, network back, three minutes, quit, one at a time; src: TextMouth/Services/Sync/SyncScheduler.swift, TextMouth/Services/Sync/SyncCenter.swift -->

A sync runs
- when TextMouth launches and has opened its library;
- every hour while it runs;
- when the network comes back, once it has stayed back 30 seconds, and at most once in five minutes;
- three minutes after your first change that hasn't been sent, and then at most every three minutes;
- when you choose Sync Now;
- when TextMouth quits, which only sends your changes and waits at most 2 seconds.

Only one sync runs at a time; a moment that comes during one makes one more run after it.
Syncing waits while the library is busy with a move, a recovery, or other storage work, and never blocks the Library window.
With no network, or with the folder missing, your changes stay on this Mac and go the next time a sync reaches the folder.

## Books on each device
<!-- id: sync-books-each-device; keys: In Cloud, Download Now, download view, placeholder, Keep on This Mac, backing up books; src: TextMouth/Services/Sync/StoreBookStorage.swift, TextMouth/Services/SyncPlaceholder.swift, TextMouth/Services/Sync/StoreBackup.swift -->

A book that another device added, and this one hasn't fetched, is a row like any cloud book: it shows and speaks In Cloud, and its context menu and VoiceOver actions offer Download Now.
Opening it shows the reader's download view, with its progress, Cancel, and Try Again; see [Keeping your library in the cloud](cloud-library.md).
Each file is checked after it arrives, so a book is never half there.
A stalled download says "iCloud Drive stopped sending this book's files.", and on a cellular or hotspot connection adds "If iCloud Drive can't use cellular data, connect to Wi-Fi."

Your Mac copies its books into the TextMouth Sync folder in the background: text books first, smaller ones first.
A book reaches other devices once its copy has uploaded.
A book already in the folder is not copied again, whichever device made it, and a book that is the same file on both devices stays one book on each.

## Saving space on this Mac
<!-- id: sync-saving-space; keys: Books on this device, All books, Books you open or keep, Remove Download, unopened, days, Off; src: TextMouth/Services/Sync/StoreRemoval.swift, TextMouth/Services/Sync/SyncSpaceSettings.swift, TextMouth/Models/Sync/SyncDeviceSettings.swift, TextMouth/Views/Settings/SyncSpaceControls.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

While sync is on, the Sync section has two settings of this Mac alone; they never reach another device.
- Books on this device: All books, or Books you open or keep.
  All books, this Mac's choice at first, downloads every book it lacks after each sync, and never removes one.
  Books you open or keep downloads only kept books, the reading list's, and the books you open.
- Remove unopened downloads after: Off, or 1 to 30 days.
  It is Off on the Mac at first, and shows only under Books you open or keep.
  A download goes once its book has gone unopened that long, counting from its last opening on any device, its last play here, the day its files arrived, or the day you turned this on, whichever is latest.
  Choosing Books you open or keep removes nothing at once.
  One sweep after a sync takes at most 25 books, and VoiceOver hears one summary: "Removed downloads of 3 books not opened in 7 days.
  All stay in iCloud Drive."

Remove Download frees one book or a selection, from a book's context menu and VoiceOver actions, the Library menu, and Book Information.
The book stays in the library with its place, bookmarks, and details, and its row says In Cloud; opening it downloads it again.
Under All books, a book you freed stays freed until you open it, and the result says "Opening a book downloads it again."

A download is removed only when the TextMouth Sync folder holds every file of the book.
TextMouth reads the copy back and checks it against what was backed up, and looks again just before the files go.
A book kept on all devices or on the reading list, one that is open, playing, exported, transcribed, edited, or downloading, a feed's item, and a book the backup hasn't finished with, are never removed.
When the proof falls short the book stays whole and the alert says why, in words such as "TextMouth hasn't confirmed that iCloud Drive holds every file of this book, so its download stays."
The check downloads the book again if this Mac gave its copy in the folder up, so it needs room for one more copy and, on cellular data, Wi-Fi.
The status line counts books kept for want of a proven copy, and books not downloaded for want of room.

## Keep on All Devices
<!-- id: sync-keep-all-devices; keys: Kept on all devices, Stop Keeping on All Devices, Book Information checkbox, reading list keeps; src: TextMouth/ViewModels/LibraryViewModel+Cloud.swift, TextMouth/Services/KeptBooks.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/App/MenuCommands.swift -->

Keep on All Devices asks every device that syncs to keep a book's files and to download them when it can.
While sync is on it replaces Keep on This Mac, in
- a book's context menu and VoiceOver actions, as Keep on All Devices or Stop Keeping on All Devices, and with several books selected "Keep 3 Books on All Devices";
- the Library menu, for the books selected;
- Book Information, where a checkbox says "Kept on all devices", with the hint "Every device that syncs keeps this book's files, and downloads them when it can."

VoiceOver hears "Keeping Moby-Dick on all devices." or "No longer keeping Moby-Dick on all devices."
A kept book's row says "Kept on this Mac", as any kept book's does.
The choice syncs, so it holds on the iPhone as well.
Stopping removes nothing.

The reading list's books are kept as well, on a device that keeps them: the Reading List's checkbox "Keep these books on this Mac" shows while sync is on, and each device chooses for itself.
A book that leaves the list returns to its own choice.

## Downloads after a sync
<!-- id: sync-downloads-after; keys: Wi-Fi, Ethernet, Low Data Mode, cellular, hotspot, free space, one GB; src: TextMouth/Services/NetworkReachability.swift, TextMouth/ViewModels/LibraryViewModel+Sync.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

After each sync, TextMouth downloads the books that are kept on all devices or on a reading list it keeps, and that are only in the cloud here; under All books, every book that is only in the cloud, except one you freed.
It does so one at a time, only as many as fit in the free space less 1 GB, and only on Wi-Fi or Ethernet with Low Data Mode off, checked before each book.
A book that doesn't fit is left, and the status line says how many.
On a cellular or hotspot connection it waits for a later sync, so it spends none of that data.
A book you open downloads on any network, and offline nothing starts.
Kept books download quietly, their rows saying "Downloading 40%"; the reading list's books are announced once, as "Downloading 12 reading list books".

## Reading while another device changes your place
<!-- id: sync-reader-place; keys: Moved to the place saved, open book, playing, paused; src: TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift -->

When another device saved a later place in a book that is open and at rest here, the reader moves there, and VoiceOver hears "Moved to the place saved on iPhone."
A book that is playing, or paused in the middle of its speech, is never moved: it plays on, and its next saved place wins.

## A large removal is held
<!-- id: sync-held-removals; keys: mass removal, held back, looked like a mistake, 20 books, Sync Now confirms; src: TextMouth/Services/Sync/SyncEngine.swift, TextMouth/Models/Sync/SyncWording.swift -->

A removal reaches the other devices only when you made it in a running TextMouth.
When this library would remove more than 20 books at once, or more than half of a library of four books or more, TextMouth sends none of those removals and says "TextMouth held back removing 42 books, since it looked like a mistake.
Check the library on this Mac, then choose Sync Now."
Choosing Sync Now confirms exactly the removals held then and sends them; any other removal held later stays held.
A book or folder that is missing when TextMouth launches is put back, unless its package holds the mark of a removal you made.
A removal arriving from another device waits while the book is open in a reader, being edited, exported, transcribed, or fetched, and is tried at the next sync.

## Stop Syncing
<!-- id: sync-stop; keys: Stop Syncing, confirmation, nothing is deleted, forget the folder; src: TextMouth/Platform/macOS/Views/SyncSettingsSection.swift, TextMouth/Services/Sync/SyncCenter.swift -->

Stop Syncing… asks "Stop syncing this library?
Nothing is deleted, on this Mac or in iCloud Drive."
When some books are only in iCloud Drive, it adds "12 books: only in iCloud Drive.
Keep the TextMouth Sync folder to open them."
Those books won't open without that folder.
Cancel is first and the default, so Return keeps sync on.
Stopping forgets the folder, says "Sync is off.", and leaves every book, the TextMouth Sync folder, and this Mac's own sync files where they are.
To use the folder again, choose Join Sync Folder….

## Older versions
<!-- id: sync-older-versions; keys: version 0.6.0, later TextMouth, placeholder; src: TextMouthProductionTests/SyncOlderVersionsTests.swift -->

A TextMouth before version 0.6.0 reads the library as before and ignores the sync files, but it can't open a book that is only in the cloud.
Update every device before you set up sync.
A TextMouth that finds a folder made by a later one leaves it alone and says "A later TextMouth made this sync folder.
Update TextMouth to use it."

## What isn't synced yet
<!-- id: sync-not-yet; keys: settings, feeds, statistics, sorts, views, Dropbox, text edits, books imported on both; src: TextMouth/Models/Sync/SyncProjection.swift, TextMouth/Models/Sync/SyncApplier.swift; status: incomplete; issues: FR43 -->

- Settings, text substitutions, feeds, statistics, sorts, views, folders' sort and listening options, and the manual order stay on each device.
- An edit of a book's text doesn't reach a device that has the book already.
- Only iCloud Drive is used; Dropbox and Google Drive aren't.
- Nothing is deleted from the TextMouth Sync folder, and books that are the same on two devices aren't folded together there.
- So a book imported on both devices before they synced stays one book on each, but its place and bookmarks don't pass between them.
