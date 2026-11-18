"""The areas of the app: which feature each Swift file belongs to.

An area is a feature, not a folder, so that one conversion agent can take "the sleep timer" on
both apps in one piece. The table lists, for each area, glob patterns over a file's path
relative to ``TextMouth/``; ``*`` matches any characters, including ``/``. The first area whose
pattern matches a file owns it, so a specific area comes before the one that holds its
neighbours (the iPhone's screens are first because every file of the iPhone's folders is theirs,
whatever it is about).

The tests keep the table complete: every Swift file under ``TextMouth/`` must be matched, so a
new file that no pattern covers fails ``Scripts/l10n/tests/test_scan_areas.py`` until someone
gives it an area here. ``area_of`` itself never fails: a file no pattern covers is reported
under ``UNMAPPED`` so that a report is still made.
"""

from __future__ import annotations

from fnmatch import fnmatchcase
from typing import Iterable, List, Optional, Tuple

# The name a report uses for a file no pattern covers.
UNMAPPED = "unmapped"

# (area, what it holds, patterns), in the order they are tried.
AREAS: List[Tuple[str, str, Tuple[str, ...]]] = [
    ("iphone", "the iPhone app's own screens, models, and services", (
        "Phone/*", "Platform/iOS/*", "ViewModels/Phone*",
    )),
    ("sleep-timer", "the sleep timer and its hand-over to the next book", (
        "*SleepTimer*", "*EndOfBook*", "*NextBookWindow*", "*TimeLeftEstimate*", "*TimeRemainingTally*",
    )),
    ("bookmarks", "bookmarks and saved places", (
        "*Bookmark*", "*SavedPlaces*", "*PlaceSnapshots*", "*PlaceRelocator*", "*PlaceClock*",
        "*TrackPlaces*", "*ReadingListPlace*",
    )),
    ("reading-list", "the Reading List", (
        "*ReadingList*",
    )),
    ("search", "searching the library and inside a book", (
        "Services/TextSearch/*", "*LibrarySearch*", "*BookSearch*", "*TextAnchor*", "*PatienceDiff*",
    )),
    ("transcription", "transcribing audio and editing transcripts", (
        "*Transcript*", "*Transcribed*", "Views/Transcription/*", "*TimedText*",
    )),
    ("braille", "braille files, tables, pages, and export", (
        "*Braille*",
    )),
    ("formats", "the readers of book and document formats", (
        "Parsers/*",
    )),
    ("audio-editor", "the audio editor and its filters", (
        "*AudioEdit*", "*AudioBuiltInFilter*", "Views/AudioEditor/*", "Services/AudioEditing/*", "*AudioFilter*",
        "*AudioOriginal*", "*AudioSampleForm*", "*AudioSegment*", "*AudioMarkerList*", "*ChapterPauses*",
        "*MP3*", "*AudioMetadata*", "*TimeEntry*",
    )),
    ("recording", "recording audio", (
        "*Recording*", "*AudioInput*",
    )),
    ("export", "exporting books and speech", (
        "Services/Export/*", "Services/SpeechExport/*", "Views/Export/*", "*BookExport*", "*SpeechExport*",
        "*ExportWriter*", "*ExportDeepChapter*", "*ChapterTrackWriter*", "*ChapterListWriters*",
    )),
    ("feeds", "podcast feeds and their episodes", (
        "*Feed*", "*PodcastChapters*", "*OPML*",
    )),
    ("storage-cloud", "the data folder, cloud storage, migration, and file safety", (
        "*Cloud*", "*Storage*", "*DataDirectory*", "*Migrat*", "*Persistence*", "*Quarantine*",
        "*IndexRecovery*", "*Ubiquitous*", "*MaintenanceFile*", "*SavedFile*", "*TextMouthPaths*",
        "*ConflictCopies*", "*LibraryFile*", "*LibraryFetch*", "*LibraryCopyReader*", "*LibrarySession*",
        "*LibraryLoadResult*", "*LibraryIdentity*", "*ArchiveBudget*", "*PublishedFileProgress*",
        "*OrphanedConversion*", "*PackageFileEditing*", "*NetworkReachability*", "*StoredKeyScan*",
        "*StoredPreference*", "*UnknownKeys*", "*LenientFields*", "*CacheFingerprint*", "*TextCache*",
        "*ReadingTextCache*", "*MarkdownCache*", "*ImportScratch*", "*ImportStaging*",
    )),
    ("import", "adding books: importing files, their conversion, and the decisions asked", (
        "*Import*", "*FFmpeg*", "*Ogg*", "*ConvertedOriginal*", "*AudioConverter*", "*PlaylistImport*",
        "*LaunchFiles*", "*MoveToLibrary*", "*AddToLibrary*", "*RefusedFormat*", "*Textutil*",
        "*ExtractionReport*", "*DocumentContent*", "*ArchiveExtraction*", "*TextExtraction*",
        "*MetadataRefresh*", "*PageImage*", "*CueSheet*", "*OriginalFileDeletion*", "*AudioFileInfo*",
        "*MarkdownNesting*",
    )),
    ("speech-voices", "speech, voices, pronunciation, and text substitution", (
        "*SpeechService*", "*SpeechMarkupGuard*", "*SpeechRefusal*", "*Voice*", "*Pronunciation*",
        "*TextSubstitution*", "*Lexicon*", "*RepeatedSymbol*", "*InProcessEngine*", "*SoundEffect*",
        "*AudioEngineService*", "*AudioPlaybackService*", "*PlaybackMemoryGuard*", "*FineWords*",
        "*ListeningOptions*", "*ListeningDay*", "*ReadingStats*", "*MediaGesture*", "*NowPlaying*",
    )),
    ("shortcuts-menus", "keyboard shortcuts, menus, and the app's windows", (
        "*KeyboardShortcut*", "*ShortcutEdits*", "*ShortcutPress*", "*TextEditingKeys*", "App/*",
        "Platform/macOS/App/*", "*MenuVisibility*", "*WindowSwitch*", "*FrontWindow*", "*WindowRouter*",
        "*VoiceOverFocus*", "*SwitchedWindowFocus*", "*SilentKeyEquivalent*", "*QuitNotice*",
        "*WindowAccessor*", "*ViewBodyCounter*",
    )),
    ("settings", "the Settings window and the settings it keeps", (
        "Views/Settings/*", "*SettingsViewModel*", "*ConfigService*", "*SettingsPolicy*", "*LeadingArticle*",
        "*SemanticVersion*", "*BuildIdentity*", "*SummaryPress*",
    )),
    ("reader", "reading a book: the reader window, playback, navigation, and text edits", (
        "Views/Reader/*", "*Reader*", "*Playback*", "*Headings*", "*SpeakInfo*", "*WhereAmI*",
        "*GoingOn*", "*Jump*", "*Pages*", "*TitleTyping*", "*ChapterSpeech*", "*LookAhead*",
        "*LongPauseWatch*", "*LiveReadingPositions*", "*OffsetMap*", "*ContentAnalysis*",
        "*ManifestEdit*", "*TextEdit*", "*EditedText*", "*TextEncoding*", "*ReadOnlyTextArea*",
        "*BookText*", "*BookManifest*", "*TrackFolderBooks*", "*EPUBMetadata*", "*BookRereadChoosing*",
    )),
    ("library", "the library: its books, folders, views, sorting, and sheets", (
        "Views/Library/*", "*Library*", "*Folder*", "Models/Book*", "*Duplicate*", "*ContentView*",
        "*TextInputView*", "*StableSort*", "*ListNeighbors*", "*Succession*", "*SortAndOrder*",
        "*KeptBooks*", "*RemovedFromLibrary*", "*RemovalWording*", "*OperationOutcome*", "*JSONValue*",
        "*ImportDecision*",
    )),
    ("other", "shared helpers and the debug log, which belong to no one feature", (
        "*CountWording*", "Platform/Platform*", "*DiagnosticLog*", "*LogWriter*", "*LogLocation*",
        "*LogsInFinder*", "*LogsSettings*", "*TimerCoalescing*", "*RunningClock*", "*AsyncBridge*",
        "*ObjCException*", "*WatchedProcess*",
    )),
]


def area_of(path: str) -> str:
    """The area that owns a file, given its path relative to ``TextMouth/`` (or starting with
    ``TextMouth/``, which is dropped), or ``UNMAPPED`` when no pattern covers it."""
    rel = path[len("TextMouth/"):] if path.startswith("TextMouth/") else path
    for name, _what, patterns in AREAS:
        if any(fnmatchcase(rel, pattern) for pattern in patterns):
            return name
    return UNMAPPED


def area_names() -> List[str]:
    """The area names, in table order."""
    return [name for name, _what, _patterns in AREAS]


def unmapped(paths: Iterable[str]) -> List[str]:
    """The paths no area owns."""
    return [p for p in paths if area_of(p) == UNMAPPED]
