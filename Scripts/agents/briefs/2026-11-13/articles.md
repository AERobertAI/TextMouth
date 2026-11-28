# Leading articles: sorting, display, and letter navigation (November 13, 2026)

You are `articles`, an Opus lead. Your branch is `feature/title-articles`, made at local main. First read `common.md` beside this brief and follow it.

## The user's words

On November 13, 2026:

> "for a feature I don't think is implemented I want the possibility of better sorting of articles, as a setting somewhere but so before sorting aphabetically it would put all the "the" or "a"s after the name displayed in the table view like an encycliphedia to not crowd out a and t and make single letter navigation more useful... speaking of letternavaigation letter navigation (like typing the first few chars of a title to go to it) can this behavior be customized to like ignore articles if the letters are not for a article? like to allow for the options "articles treated as part of titles always" "articlesignored when jumping by title" and "articles ignored for typing and sorting purposes both" obviusly with better names but try researching this..."

So, in their words: a setting with three choices, (1) articles are part of the title, for sorting and for typing; (2) articles are ignored when jumping by typing a title; (3) articles are ignored for both typing and sorting. With sorting that ignores them, the list shows the article after the name, as an encyclopedia or an index does ("Hobbit, The"), so the A and T sections aren't crowded and a single typed letter goes somewhere useful. "Ignore articles if the letters are not for an article": typed letters that are themselves an article followed by more of the title still match a title as written.

## What the orchestrator found

- Kodi has "Ignore articles when sorting (e.g. "The")" under Settings > Appearance > File lists, with the words it ignores set in `advancedsettings.xml` (`sorttokens`). Plex and Emby ignore leading articles in sorting, with a list of words. calibre keeps a "title sort" for each book, made from per-language article patterns and the book's language (`per_language_title_sort_articles`). Librarians call such words non-filing: MARC field 245's second indicator counts a title's non-filing characters, and an index shows the title inverted. Search further where you need to, preferring primary sources (Apple's Human Interface Guidelines and AppKit documentation, the Library of Congress's MARC pages), and say what you found.
- The Library list is a SwiftUI `List(selection: $selectedBookIDs)` in `TextMouth/Views/Library/LibraryView.swift` (about line 474), with `.searchable(text:prompt: "Search books")` and a "Books" accessibility rotor. TextMouth has no type-select code of its own (a search for `typeSelect` finds nothing), so whatever letter navigation the user has today comes from SwiftUI's list or its AppKit table.
- Books are ordered by `TextMouth/Models/LibraryBookSorter.swift`: `.title` compares with `localizedCaseInsensitiveCompare`, and every other sort breaks ties by title. Feeds sort with `localizedStandardCompare` (`Services/Feeds/FeedStore.swift`, `Views/Feeds/LibraryFeedFolders.swift`).
- Settings has a Library tab (`Views/Settings/LibraryViewsSettingsView.swift`, `SettingsTab.library`), which orders the Library's views.

## Find out first

What letter navigation does today in the Library list, and say in the design how you found it:
- which string a typed letter matches (the row's text, its accessibility label, something else);
- whether it needs the list focused, and what VoiceOver says when it moves;
- whether a typed letter can reach the search field, a menu shortcut, or one of TextMouth's shortcuts (`KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md`, the shortcut registry);
- what the AppKit table under the list offers (`NSTableView.allowsTypeSelect`, the delegate's `tableView(_:typeSelectStringFor:row:)`, `tableView(_:nextTypeSelectMatchFromRow:toRow:for:)`, `tableView(_:shouldTypeSelectFor:withCurrentSearch:)`) and whether TextMouth can use it under SwiftUI, or must handle the keys itself (`onKeyPress` on macOS 14).

A hosted test can reach the list's table to find out. Never ship a reach into SwiftUI's private views if a public way exists; if none does, say so, and choose the way that survives a macOS update.

## The design

Write `TITLE-ARTICLES-RESEARCH-2026-11-13.md` in the repository root (stage it with `git add -f`; this is the one Markdown file you edit): what you found, the setting's name, its three choices' names and hints (short, plain, and spoken well by VoiceOver), where it lives, which lists it reaches, the typing rule exactly, the articles for each language, and questions for the user, each with the answer you built. Then build it.

## Required behavior

1. **One setting with the user's three choices**, in the Library tab of Settings, saved in `config.json` through `ConfigService` like the tab's other settings, defaulting to (1), so nothing changes until the user chooses. Its names are yours to find; the user asked for better ones than theirs.
2. **Sorting** (choice 3): a title's leading article is left out of the sort key, so "The Hobbit" sorts among the H's, and the row shows "Hobbit, The". Every sort that breaks ties by title uses the same key. The book's own title is never changed: Book Information, the reader's window title, Now Playing, export, and the files keep it as it is.
3. **Typing** (choices 2 and 3): typing the first letters of a title goes to the first row, in the list's order, whose title without its leading article starts with them; and, by the user's "if the letters are not for an article", letters that are an article followed by a space and more still match a title written with that article. Typed letters accumulate within the system's type-select interval, as AppKit's do.
   - Choice 2 keeps the list in its order and only changes where typing goes; choice 1 changes nothing.
   - The selection moves to the row, the row scrolls into view, and VoiceOver focus follows it and reads the row as it reads any row: no extra announcement.
   - A typed letter never starts playback, a command, or the search field's filter.
4. **Which titles:** books in every Library view and folder, and a feed's episodes and articles where they list as books. Feed titles in the Feeds view too, if their rows sort by title. The Reading List keeps its own order, but its rows show titles as the Library does and typing finds them the same way. Folder names, which the user types themselves, are left as they are; say so in the design.
5. **Languages:** English's "The", "A", and "An" always; a book whose language is known (its metadata's language) also uses that language's articles, for a handful of languages you choose and list in the design (French, German, Spanish, Italian, Portuguese, Dutch at least), so "Die Hard" in an English book keeps its "Die". Elided articles such as French "L'" and Italian "L'" join the next word; say how the display shows them.
6. **VoiceOver and braille read what the row shows.** The "Books" rotor lists the shown titles in the list's order. The search field (`searchable`) still finds a book by its title as written and as shown.
7. **The iPhone**, which shares the sorter, keeps compiling; a setting there is a follow-up, unless it costs only a row in its settings.

## Tests

- The sort key: each language's articles, case, punctuation ("A.I." is not an article; "The" alone is a title; "A Is for Alibi"; quotation marks and an opening parenthesis before the article; an article followed by a number), and the inverted display.
- The sorter: every field's tie-break uses the key; choice 1 orders exactly as main does (pin it against main's order on the same books).
- The typing rule: a typed prefix's match in each choice, articles typed as words, the interval, no match, and a match after the selection.
- A hosted test that the list moves its selection to the row a typed prefix names, for each choice.
- The setting's config round trip and the fixtures; `KeyboardReachabilityTests` if a key binding changes.

## Your report

Follow `common.md`'s report, and add: what letter navigation did before your change and how you found out; the setting's final words; the questions for the user; and the documentation each change needs (`docs/user/library-window.md`, `docs/user/settings.md`, `docs/architecture/state/preferences.md`).
