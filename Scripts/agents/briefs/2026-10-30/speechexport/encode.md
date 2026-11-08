# speechexport/encode: chapter files joined into an M4B, M4A, or MP3 through the editor's renderer (FMT43, step 3)

Slug `speechexport-encode`; branch `speechexport/encode`, made with `git checkout -b speechexport/encode team/speechexport`. Team `speechexport`, lead `speechexport-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-30/teams-common.md`, and the build section at the end of this brief, which overrides its build-folder rules.

## Goal

A speech export (FMT43) speaks each chapter of a book into a CAF file of its own (16-bit PCM, one per heading, kept so a stopped export can resume). This task joins those files into one AAC M4B or M4A with a chapter marker at each file's start, or an MP3 with ID3 chapter frames, through the audio editor's own renderer (`AudioEditRenderer`), which already writes all three with chapters, tags, and progress. No new encoder: one new initializer on the editor's timeline, and a small encoder type that drives the renderer.

## Read first (only these, by line range)

- `TextMouth/Models/AudioEditTimeline.swift` 1-125 (the timeline, `Source.processed`, `Segment`, `Chapter`, the private init) and 390-410 (`normalizeChapters`).
- `TextMouth/Services/AudioEditing/AudioEditComposition.swift` 1-100 (`AudioEditBase`, `load`, `Sources`) and 100-215 (`make`, `location(of:in:)`: a `.processed` name is a plain file name in `sources.scratch`).
- `TextMouth/Services/AudioEditing/AudioEditRenderer.swift` 300-330 (`AudioRenderMetadata`) and 423-585 (`render`, `chapterList`).
- `TextMouth/Services/AudioEditing/AudioExportFormat.swift` (all, 70 lines).
- `TextMouth/Services/AsyncBridge.swift` 17-35 (`waitForResult(of:)`).
- `TextMouth/Services/BookExportService.swift` 175-200 (`BookExportCancellation`).
- `TextMouthProductionTests/MP3EncoderTests.swift` 270-305 and `TextMouthProductionTests/AudioEditRenderingTests.swift` 100-135: reading chapters back with `AudioPlaybackService.extractChapters(from:)`.

## What to make

### 1. `TextMouth/Models/AudioEditTimeline.swift`: one initializer (its own commit)

`init(sampleRate: Double, joining files: [(name: String, frames: Int64, title: String?)])`: the files played whole, one after another, each a stretch `Segment(source: .processed(name), sourceStart: 0, length: frames)`, with a chapter marker at the start of each that has a title; a file of no frames (or fewer) is left out with its marker; markers normalized as every timeline's are (`normalizeChapters()`). Doc comment: FMT43's spoken chapters, each rendered into a file of its own in a scratch folder, joined into one. Nothing else in the file changes.

### 2. `TextMouth/Services/SpeechExport/SpeechExportEncoder.swift` (new; create the folder if it is not there yet)

1. `enum SpeechExportFormat: String, CaseIterable, Sendable { case m4b, m4a, mp3 }`, in that order (M4B is the dialog's default), with:
   - `var exportFormat: AudioExportFormat` (`.m4b`, `.m4a`, `.mp3`), and from it `var title: String` ("M4B Audiobook (AAC)", "M4A (AAC)", "MP3": the editor's words) and `var fileExtension: String`.
   - `static var available: [SpeechExportFormat]`: `allCases` whose `exportFormat` is in `AudioExportFormat.available(ffmpeg: nil)` (MP3 while the LAME built into TextMouth is), in order.
2. `struct SpeechExportChapterFile: Equatable, Sendable { let name: String; let title: String }`: one chapter's file in the encoder's folder, by its plain name, and the chapter marker's title.
3. `enum SpeechExportEncoder` with
   `static func encode(_ chapters: [SpeechExportChapterFile], in folder: URL, format: SpeechExportFormat, metadata: AudioRenderMetadata, to destination: URL, cancellation: BookExportCancellation, progress: @escaping @Sendable (Double) -> Void) throws`
   1. Throws `CancellationError` at once when already cancelled; `AudioEditError.renderFailed("no chapters")` for none; `AudioEditError.fileOutsidePackage` for a name that is not a plain file name (`BookOrigin.isPlainFileName`).
   2. Reads each file with `AVAudioFile(forReading:)`: its `length` and its `fileFormat`'s sample rate and channel count (unreadable: `AudioEditError.unreadableAudio`). Every file must share the first's rate and channel count, else `AudioEditError.renderFailed("the chapters' audio differs")`.
   3. The timeline: `AudioEditTimeline(sampleRate: <the rate>, joining: <each file's name, length, and title>)`.
   4. In one `AsyncBridge.waitForResult` operation: `let base = try await AudioEditBase.load(<first file's URL>, name: <its name>)`; `let sources = AudioEditComposition.Sources(base: base, package: folder, scratch: folder)`; then `AudioEditRenderer.render(timeline, sources: sources, to: destination, format: format.exportFormat.renderFormat, metadata: metadata, progress: progress)` raced against the cancellation in a throwing task group: a second child task polls `cancellation.isCancelled` every 0.1 s and throws `CancellationError`; whichever ends first wins and the other is cancelled. So Stop ends an encode within a fraction of a second, and the renderer leaves nothing at `destination` (it removes its file on any failure, cancellation included).
   5. Chapter titles come out as given (an M4B, M4A, or MP3 chapter list); the file's title and artist tags are `metadata`'s.

Comment every type, property, and function, and each non-obvious block.

## Tests: `TextMouthProductionTests/SpeechExportEncoderTests.swift` (new)

A private helper writes a chapter file in a sandbox folder (`makeSandboxDirectory`): a 16-bit integer linear PCM CAF, 22,050 Hz, mono, a quiet tone of given seconds, through `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`. Pin at least:

1. Three files of 1.0, 1.5, and 0.5 seconds titled "Harbour", "Market", and "Evening" make an M4B whose chapters, read back with `AudioPlaybackService.extractChapters(from:)`, are those titles starting at 0, 1.0, and 2.5 s (within 0.02 s), and whose duration is about 3 s (within 0.1 s); its title and artist tags are the metadata's (`AVURLAsset(url:).load(.commonMetadata)`).
2. The same for an M4A, and for an MP3 (its ID3 chapters read back the same way).
3. Progress is reported, never decreasing, ending at about 1.
4. A cancelled token throws `CancellationError` and leaves nothing at the destination, both before the encode starts and while it runs (cancel from the progress callback once it passes 0.2).
5. Files of different sample rates are refused; a name with a slash is refused; no chapters is refused.
6. The formats: titles, extensions, order, and `available` holding all three (LAME is built in).
7. The new timeline initializer: the segments are the files' `.processed` stretches with their lengths; the markers sit at 0, at the first file's length, and so on; a file of no frames is left out with its marker; a file without a title has no marker; `AudioEditRenderer.chapterList(of:leadingTitle:)` gives one chapter per titled file, the first at 0.

## Run

`SpeechExportEncoderTests AudioEditTimelineTests AudioEditRenderingTests MP3EncoderTests export`. Report the exact `Executed N tests, with S tests skipped and F failures` line.

## Do not

- Change the renderer, the composition, the MP3 encoder, or anything of the timeline but the one initializer.
- Play any audio (reading a file's chapters and tags is fine; never an `AVPlayer`), or touch Ogg.
- Read or write anything under `~/.TextMouth`. Edit any `*.md` file, or any file not named here.

## Build and test (this team's rules; they override teams-common.md's build folder rules)

- The team shares ONE build folder, used by one teammate at a time: `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport`. Never make another and never delete it: the lead deletes it at the end.
- Disk: before each build, `df -g /System/Volumes/Data` must show at least 2 GB available when that folder exists, 5 GB when it does not. Otherwise post to `speechexport-lead` and wait (`python3 .claude/skills/agent-bbs/scripts/bbs.py watch <slug> --timeout 600`), then check again.
- Build in the background, through the team's lock, which queues you behind a teammate's build (waiting is normal):
  `BBS_AGENT=<slug> /usr/bin/lockf -k /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-speechexport-build.lock python3 Scripts/test/run-area.py --derived-data /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport --log <your scratchpad>/<slug>-run.log <names>`
  Check on it no more often than every 4 minutes, with one short command.
- New files need `/opt/homebrew/bin/xcodegen generate`; commit the regenerated `TextMouth.xcodeproj/project.pbxproj` with them.
- Before reporting, `make lint-tests LINT_BASE=team/speechexport` must be clean, and the build must add no Swift warning.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
