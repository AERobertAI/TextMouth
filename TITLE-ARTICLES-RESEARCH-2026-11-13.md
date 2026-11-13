# Leading articles in the Library: research and design

November 13, 2026. Branch `feature/title-articles`, agent `articles`.

## The request

On November 13, 2026 the user asked:

> "for a feature I don't think is implemented I want the possibility of better sorting of articles, as a setting somewhere but so before sorting aphabetically it would put all the "the" or "a"s after the name displayed in the table view like an encycliphedia to not crowd out a and t and make single letter navigation more useful... speaking of letternavaigation letter navigation (like typing the first few chars of a title to go to it) can this behavior be customized to like ignore articles if the letters are not for a article? like to allow for the options "articles treated as part of titles always" "articlesignored when jumping by title" and "articles ignored for typing and sorting purposes both" obviusly with better names but try researching this..."

So: one setting with three choices: articles are part of the title, for sorting and for typing; articles are ignored when jumping by typing a title; articles are ignored for typing and sorting both. While sorting ignores them, the list shows the article after the title, as an index does ("Hobbit, The"). Letters that are an article followed by a space and more still reach a title written with that article.

## What I found

### How others do it

- **Kodi** has "Ignore articles when sorting (e.g. "The")" under Settings, Appearance, File lists, with the words it ignores set in `advancedsettings.xml` (`sorttokens`). **Plex** and **Emby** ignore leading articles in sorting, from a list of words. **calibre** keeps a "title sort" for each book, made from per-language article patterns and the book's language (`per_language_title_sort_articles`, a tweak its manual documents; its code was not read, as it is GPL).
- **Libraries** call such words non-filing. MARC 21 field 245's second indicator counts a title's nonfiling characters, which sorting and filing pass over (Library of Congress, MARC 21 Bibliographic, 245, Title Statement: <https://www.loc.gov/marc/bibliographic/bd245.html>). Its examples settle the counting rules TextMouth follows: "The Year book of medicine." counts 4 ("The " with its space); "L'enfant criminal." counts 2 (the elided "L'" joins the next word, with no space); "[The Part of Pennsylvania...]" counts 5 (a bracket before the article counts with it); "--the serpent--snapping eye" counts 6; and "L'été." counts 2, since "any diacritic associated with the first filing character is not included". A title that does not begin with an article counts 0, whatever punctuation opens it.
- **The articles of each language** are listed in MARC 21 Bibliographic, Appendix F, "Initial Definite and Indefinite Articles" (<https://www.loc.gov/marc/bibliographic/bdapndxf.html>, revised 12/07/2023). TextMouth's table (below) is taken from it.
- **An index** shows the title inverted: "Hobbit, The", which is the display the user asked for.

### What Apple documents

- **SwiftUI** `View.typeSelectEquivalent(_:)` (macOS 13 and later): "By default, a type select equivalent is automatically derived from any Text or TextField content in a list or table." An explicit value is for rows "when there is no textual content or when a different value is desired compared to what's displayed"; "Setting an empty string value disables text selection for the view, and a value of nil results in the view using its default value." (<https://developer.apple.com/documentation/swiftui/view/typeselectequivalent(_:)>)
- **AppKit**: `NSTableView.allowsTypeSelect` is true by default. The delegate's `tableView(_:typeSelectStringFor:row:)` gives the string a row is matched by (by default the prepared cell's `stringValue`); `tableView(_:nextTypeSelectMatchFromRow:toRow:for:)` returns the first match in a range "from startRow to endRow", and "it's possible for endRow to be less than startRow if the search will wrap"; `tableView(_:shouldTypeSelectFor:withCurrentSearch:)` is asked for each key, with "the search string or nil if no type select has began". Apple's Table View Programming Guide ("Enabling Row Selection and User Actions") says "a user types the first few letters of an entry and the table view content is searched for a matching row", and that returning NO from the last "prevents the specified event from being used for type selection; it doesn't prevent standard event processing". Neither page says where AppKit's search starts or how long typed letters add up; the probe below measured both.
- **SwiftUI** `onKeyPress` (macOS 14): a `KeyPress` holds its phase, key, characters, and modifiers, and no timestamp; returning `.handled` keeps the key from going further.
- The Human Interface Guidelines' page on lists and tables did not load for reading, and nothing found in Apple's pages describes ignoring articles.

### What letter navigation does today in the Library list

Found by typing into hosted lists: a probe test class, `LibraryTypeSelectProbeTests`, that prints each finding on a `TYPE-SELECT-PROBE:` line and runs only on GitHub's runner, since a key nobody takes could beep. Train 1113-0322, macOS 26.7.2 (25G332):

- **The list is AppKit's.** The Library list, a SwiftUI `List`, is drawn by `SwiftUI.SwiftUIOutlineListView`, a subclass of `NSOutlineView` and `NSTableView`, with `allowsTypeSelect` on. Its delegate, SwiftUI's `OutlineListCoordinator`, implements none of the three type-select methods, so AppKit matches each row by its text.
- **A title is matched from its first letter as written.** With Apple Pie selected, H selected Hamlet, not The Hobbit.
- **The search starts after the selection and wraps.** With nothing selected, B selected Banana Republic; with Banana Republic selected, A selected Avocado Toast below it, not Apple Pie above it; with Avocado Toast selected, A moved on to A Tale of Two Cities. So pressing the same letter again goes on to the next title with it.
- **A space joins a search under way.** "the h", typed key by key into the hosted list, stayed on The Hobbit. In the app a Space never reached the list: the shortcut manager takes it first, as Play or Pause.
- **Typed letters add up by the clock, not by the events' times.** Two keys stamped 10 seconds apart and sent together added up; two stamped 0.1 seconds apart and sent 2.5 seconds apart did not. Letters 0.3, 0.6, 0.9, and 1.2 seconds apart added up; 1.6 and 2.2 seconds apart started a new search. The runner's key repeat delay was 0.5 seconds, its repeat interval 0.083, and its double-click interval 0.5, with `InitialKeyRepeat` and `KeyRepeat` unset.
- **The search field never got the letters**, and nothing was announced beyond the new selection.
- **A row's `typeSelectEquivalent(_:)`, when it names one, is what typing matches:** H selected The Hobbit, named "Hobbit, The". One string a row can't serve both "h" and "the h", so the design does not rest on it.
- **`onKeyPress` on a list sees each letter before AppKit does:** returning `.handled` kept the letter from AppKit's type select (nothing selected), and `.ignored` passed it on (Zebra Crossing selected).
- **A row selected in code is not scrolled into view** (row 150 selected, rows 0 to 12 still in view); `ScrollViewReader`'s `scrollTo` scrolled it into view in a plain list (rows 138 to 150). In the Library list, with its taller rows, `scrollTo` fell short (row 62 selected, rows 47 to 54 in view), so letter navigation scrolls through the table itself.

## The design

### The setting

- **Where:** the Library tab of Settings, in a section headed **Titles**, under the views' controls.
- **Its label:** **Leading articles**, a pop-up, with the hint "Chooses whether The, A, and An at the start of a title count when the Library sorts titles and when you type a title's first letters to go to it."
- **Its choices**, title case as the tab's other pop-ups are:
  1. **Part of the Title** (the default, so nothing changes until the user chooses): "Titles sort, and are found by typing, as they are written: The Hobbit is among the T's."
  2. **Ignored When Typing**: "Typing H goes to The Hobbit. The list keeps its order and shows each title as it is written."
  3. **Ignored When Typing and Sorting**: "The Hobbit sorts among the H's and shows as Hobbit, The. Typing H goes to it."
- Under the pop-up, the choice in force's sentence and a second one: "A book whose metadata names French, German, Spanish, Italian, Portuguese, Dutch, Catalan, Swedish, Danish, or Norwegian passes over that language's articles too, such as Le and Die. Folder names stay as you typed them." The text is read by VoiceOver as text, so a listener with hints off still hears what the choice does.
- **Stored** under `leadingArticles` in the preferences store and in `config.json`, as `"partOfTitle"`, `"ignoredWhenTyping"`, or `"ignoredWhenTypingAndSorting"`; an empty value, or any other word, leaves the choice alone, as the log location's does.

### What a title's leading article is

A title files from after its nonfiling part, as MARC counts it:

- **A word article** ("The", "A", "An", "Le", "Die") must be followed by a space and more of the title holding a letter or a number. "The" alone is a title, and so are "The." and "A.I. Superpowers"; "Thebes" and "Anne of Green Gables" begin with words, not articles.
- **An elided article** ("L'", "Gl'", "Un'") joins the next word, which begins with a letter: "L'Étranger" files under É.
- **An article beginning with an apostrophe** (Dutch "'t" and "'n", German "'s") is followed by a space.
- **English "A" is the letter A**, not an article, before "is", "was", "to", "for", "and", "or", "through", "thru", "versus", "vs", "&", "+", or a single letter: "A Is for Alibi" and "A to Z of Gardening" file under A.
- **Opening punctuation** before an article (quotation marks, parentheses, brackets, ¡ and ¿, and » and ›, which German and Danish open a quotation with) is nonfiling with it, as MARC counts "[The ": `"The Raven"` files under R. Opening punctuation right after an article is nonfiling too, as MARC counts it, so `The "Best" Of` files under B. Punctuation before no article is left alone.
- **Case and apostrophes:** an article matches in any letter case and with any apostrophe typists use (', ’, ʼ). **Accents count:** "À la recherche du temps perdu" keeps its "À".
- **One article only:** "The A.B.C. Murders" files under A.

### The articles of each language

English's articles count for every title. A book whose metadata language (its EPUB's `dc:language`, kept as `Book.epubLanguage`, editable in Book Information) is one of these adds that language's, so "Die Hard" in an English book keeps its "Die" and "Die Verwandlung" in a German one files under V. A language tag's region and script are passed over ("fr-CA", "pt_BR"), and its ISO 639-2 codes ("fre", "fra", "deu") and names ("French", "Deutsch") are read too. Only EPUB books keep a metadata language, so a Word, MOBI, PDF, or text book, and every feed with its episodes and articles, files with English's articles alone: "Le Petit Prince" as a Word document stays among the L's.

| Language | Articles (MARC 21 Appendix F) |
| --- | --- |
| English | the, a, an (Appendix F's archaic "ye" and "d'", and "de", left out) |
| French | le, la, les, un, une, l' |
| German | der, die, das, den, dem, des, ein, eine, einen, einem, einer, eines, 's |
| Spanish | el, la, los, las, lo, un, una |
| Italian | il, lo, la, i, gli, le, un, uno, una, l', gl', un' |
| Portuguese | o, a, os, as, um, uma |
| Dutch | de, het, een, eene, 't, 'n |
| Catalan | el, els, la, les, en, un, una, l' |
| Swedish | den, det, de, en, ett |
| Danish | den, det, de, en, et |
| Norwegian | den, det, de, dei, en, ei, ein, et, eit (Appendix F's dialect "e" left out, as a letter more often than an article) |

### Sorting (the third choice)

- Every library order compares titles by their filing text, ignoring case, in the user's locale, as titles were compared before; two titles with the same filing text fall by the titles as written ("Hobbit" before "The Hobbit"), then by identity. The Title sort and every tie broken by title use this one key: Author, Date Added, Last Opened, File Size, and Manual Order, a view's limits, Recently Opened, a folder's manual order with Move Book Up and Down and dragging, and Continue to Next Book.
- The first and second choices order exactly as TextMouth did before the setting, which a test pins against a copy of the old comparator for every field and direction.
- The Feeds section's rows, always listed by title, sort by their filing text too.
- The Reading List keeps the order the user arranged.

### What the rows show

- In the third choice every row whose title is a book's, an episode's, an article's, or a feed's shows it with its article after the main title: "Hobbit, The", "Étranger, L'", "39 Steps, The", "Hobbit, The: There and Back Again", "Fellowship of the Ring, The (The Lord of the Rings, Book 1)", and, inside the marks that opened it, `"Raven, The" and Other Poems` and "(Hobbit, The)". It does so in every Library view and folder, in the Reading List, and in a feed's folder, whatever the sort, so a title reads the same everywhere.
- VoiceOver and braille read what the row shows: each row's label begins with the title as shown, and the Books rotor lists the titles as shown, in the list's order.
- **Folder names** are left as written, since the user types them.
- **The book's own title never changes:** Book Information, the reader's window title, Now Playing, Speak Info, Export, the files, and every command and announcement keep it as it is written.
- **The search field** finds a book by its title as written and, in the third choice, as shown ("hobbit, the"), and by its author.

### Typing (the second and third choices)

- **How the keys reach the list.** A key-press handler on the Library list (`LibraryTitleTyping`) takes each key that types (a letter, number, punctuation mark, symbol, or space, with neither Command nor Control) before AppKit's type select can, and keeps it, so AppKit's own type select never runs in these choices. In the first choice the handler passes every key on, and AppKit's works exactly as before.
- **The rule** (`TitleTyping`): the letters typed so far go to the first row, in the list's order, whose title past its leading article begins with them: H goes to The Hobbit. Letters longer than an article and a space also reach a title written with that article: "the h" goes to The Hobbit. "the" alone reaches a title that files under "the", such as Theory of Everything, never one that only begins with the article. In the third choice the letters reach the title as shown too: "hobbit, t" goes to The Hobbit. Folder rows are typed to by their names as written.
- **Matching** ignores letter case, accents, and character width, and reads every apostrophe as one: E reaches L'Étranger, and so do "l'e" and "l’é".
- **Letters add up** while each comes within 1.5 seconds of the one before, AppKit's own time as the probe measured it; after a longer pause the next letter starts a new search. A held key types once. Any key that does not type, such as an arrow, Return, or Escape, ends the search.
- **Where it starts:** from the top of the list, the first title in the list's order, as the brief asks, not after the selection as AppKit's does (question 4).
- **No match:** a key that reaches no title leaves the selection where it was, and makes no sound.
- **A Space** joins the letters only while a title in the list goes on with them and a space ("the", "lord", "hobbit,"), within the time letters add up, and only while the list's table has the keyboard; at every other time it is Play or Pause, as before (question 3). The list claims it from the shortcut manager (`TitleTypingSpaceClaim`), which both time by one clock.
- **The row** is selected, which VoiceOver follows and reads as it reads any row, with nothing more announced, and once the list has drawn it selected, its table scrolls it into view whole (`scrollRowToVisible`), looking again a moment later, up to four times, in case rows drawn only once scrolled to moved it on.

### The iPhone

The iPhone shares the sorter and the library model, and keeps compiling; it has no row for the setting, so its lists show and sort titles as written. A setting there is a follow-up.

## Questions for the user

Each question has the answer TextMouth now has built; a different answer is a small change.

1. **The setting's words.** Is "Leading articles" with "Part of the Title", "Ignored When Typing", and "Ignored When Typing and Sorting" clear when VoiceOver reads them? Built: those words.
2. **The letter A.** Should "A Is for Alibi", "A to Z", and "A for Effort" keep their "A", since it is the letter there, not an article? Built: yes, from a short list of words that follow the letter A (is, was, to, for, and, or, through, versus, vs, &, +, or a single letter).
3. **A Space while typing.** In a Library window Space is Play or Pause, so a Space could never be typed into the list's letter navigation. Should a Space typed right after letters that some title goes on from with a space ("the", "a", "lord", "hobbit,") join the title, as Finder lets a Space join its type select, so "the h" and "lord of" can be typed, while a Space at any other time plays or pauses as before? Built: yes, in the second and third choices, within the time letters add up, and only while the list has the keyboard; the first choice is unchanged.
4. **Where typing starts.** Should typing go to the first title in the list's order that it reaches, wherever the selection is (as the brief asks), or to the next one after the selection, as the list's own type select does, so that pressing T again goes on to the next title under T? Built: the first in the list's order; Down Arrow goes on from there.
5. **Episodes in a feed's folder.** Should a feed's episodes and articles, which its folder lists by date, also show "One About Tides, The" in the third choice, as the book rows beside them do? Built: yes, so every title reads the same everywhere.
6. **Feeds in the Feeds section.** Should feeds sort and show without their articles too, "Digital Antiquarian, The"? Built: yes, since their rows sort by title.
7. **Quotation marks.** For a title in quotation marks, is `"Raven, The"`, with the article inside the marks, right? Built: yes.
8. **More languages.** Beside the six the brief named, should Catalan, Swedish, Danish, and Norwegian books pass over their articles? Built: yes; each language's articles come from the Library of Congress's list, and apply only to books whose metadata names that language.
9. **The iPhone.** Should the iPhone get the setting? Built: not yet; its lists keep titles as written whatever is stored, a follow-up.
10. **No title reached.** Should a typed letter that reaches no title say so ("No title begins with Z")? Built: no; the selection stays where it was and nothing is said, as with the list's own type select, so fast typing is never talked over.
