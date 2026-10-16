# Team feedopts, addendum: FR20, one "Add to Library" toolbar button and its sheet

Added October 16, 2026, while the team was at work, because it changes the same toolbar as FR19's task F. Do it after F, in the same region.

## What the user asked for (in their words)

"to condence all the add from text / import book / add feed into a single "Add to Library" or similarly labeled button in the toolbar to popup a sheet with those buttons, plus doesn't the app have implemented support for audio recording? Where is that button now.... if its stable there should be a new recording button too, this could also probably be used to import from general urls and stuff in the future or similar..."

## The design (the orchestrator's; the user confirms it with FR19's questions)

1. **One toolbar button replaces three.** In the library toolbar (`LibraryView.swift:493-555`), Import (:504, built at :1730, "Import a book file"), New from Text (:506-512), and Add Feed (:516-526, `FeedWording.swift:20-26`) give way to one button, "Add to Library" (system image `plus`), with an accessibility label "Add to Library" and a hint naming what the sheet offers. It is shown wherever any of the three was shown; read each one's condition first.
2. **The Add to Library sheet**: a heading "Add to Library" (with the header trait), then one button for each way to add, in this order, each with its title and a one-line description shown under it and given as its accessibility hint:
   - Open Book… (`ShortcutAction.openBook`, the old Import button's action),
   - Import Folder… (`ShortcutAction.importDAISYFolder`, Library > Import Folder…),
   - New from Text… (`ShortcutAction.newFromText`),
   - New Recording… (`ShortcutAction.newRecording`: `RecordingWindowController.shared.show()`, `MenuCommands.swift:104,315`; recording is FR04, stable, with Option-Command-N),
   - Add Feed… (`ShortcutAction.addFeed`),
   then a Cancel button that Escape reaches. Each title is its action's own title (`ShortcutAction.title`), so the sheet and the menus say the same words; if the code already has a spoken form of an action's key in force (the Shortcuts tab shows one), show it beside the title.
3. **Each choice does exactly what its menu command does.** It closes the sheet, then runs the same code path its menu item runs (the same notification or function, never a copy), only after the sheet has gone, so a sheet it opens (New from Text, Add Feed) or the file panel (Open Book…) is not refused by SwiftUI while this one is closing. A choice is enabled only where its menu command works (FR12's branch E, `MenuCommands.swift:66-80`).
4. **Ready for more.** The choices are defined once (a small enum: its action, title, description, and how it runs), so a later "Import from URL…" is one more case.
5. **The menus stay as they are**: File > Open Book…, New from Text…, New Recording…, Library > Import Folder…, and Add Feed… keep their items and keys; only the three toolbar buttons go.
6. **Tests**: the toolbar shows Add to Library and none of the three it replaces; the sheet lists the five choices in order with their titles and hints; each choice runs its action once and closes the sheet; Cancel and Escape close it and run nothing; the wording is pinned. Existing tests that pin the three old toolbar buttons change, because the behavior changes on purpose: list each changed test, and why, in your report.

Add FR20's wording (the button's label and hint, the sheet's heading, titles, and descriptions) to your report's wording section.
