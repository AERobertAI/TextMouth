# Task afinfo: what an audio file holds, asked of afinfo in a watched child process (FMT09, step 2)

Slug `audiofmt-afinfo`, branch `audiofmt/afinfo` made from `team/audiofmt`. Read `Scripts/agents/briefs/2026-10-18/audiofmt/common.md` first.

The import is about to convert AC-3, AMR, MP2, AIFC, CAF, Wave64 and others with afconvert, as it converts Ogg. Before it can, it needs each file's codec, channels, sample rate, bit depth, and length. These must come from a child process (the October 14 rule), never from AudioFile or AVFoundation in the app. `/usr/bin/afinfo -x -r <file>` prints them as XML. But `WatchedProcess` sends a child's output to the null device, so it cannot be read yet. This task adds both pieces; task `formats` uses them.

## 1. `WatchedProcess`: a run that keeps what the child prints
In `TextMouth/Services/WatchedProcess.swift`:
- The private `watch(...)` (lines 267-342) takes a new parameter `standardOutput: FileHandle?`. When it is given, it takes the place of `FileHandle.nullDevice` for the child's standard output; standard input and errors stay on the null device.
- `run(...)` (lines 234-260) passes nil, so its signature and behavior stay exactly as they are. Team textfmt calls it for textutil; the lead has told them.
- Add `static func runCapturingOutput(_ executable: URL, arguments: [String], limits: Limits, maximumOutputBytes: Int = 1 << 20, residentMemory: … = WatchedProcess.residentMemory(of:), uptime: … = { ProcessInfo.processInfo.systemUptime }) async throws -> (outcome: Outcome, output: Data)`. It behaves as `run` does, and also:
  - the child's standard output goes to a new hidden file, `.<UUID>.watched-output`, in `FileManager.default.temporaryDirectory`;
  - the watchdog watches that file's growth (its `output`), so `maximumStalledSeconds` counts from the child's last output;
  - it returns the file's first `maximumOutputBytes` bytes;
  - the file is removed whatever happens: an exit, a kill, a failure to start, or a cancellation.
- Share the code with `run` (one private helper both call), not a copy.

## 2. `AudioFileInfo`, a new file `TextMouth/Services/AudioFileInfo.swift`
```swift
/// What afinfo, run in a watched child process, says about an audio file (FMT09) ...
struct AudioFileInfo: Equatable, Sendable {
    let fileType: String          // "caff", "ac-3", "NeXT": <file_type> with its quotes removed
    let formatID: String          // "lpcm", "alac", "flac", "aac ", "ac-3", "samr", ".mp2", "ima4", "ulaw", "opus"…: <format_type> as printed, spaces kept
    let channels: Int
    let sampleRate: Double
    let duration: TimeInterval
    let bitsPerSample: Int?       // see below
    let isFloat: Bool
    var isLossless: Bool { ["lpcm", "alac", "flac"].contains(formatID) }
}
```
- **`static func parse(xml: Data) -> AudioFileInfo?`** reads the first `<track>` of the first `<audio_file>` with Foundation's `XMLParser`, keeping a stack of element names so that only these paths count:
  - `audio_info/audio_file/file_type`;
  - and, under `audio_info/audio_file/tracks/track/`: `num_channels`, `sample_rate`, `format_type`, `bit_depth`, `duration`, `pcm_info/data_type`, and `source_info/bit_depth`.

  An AC-3 track nests `<format>` elements with their own `num_channels` and `sample_rate`, which must not be taken. Run `afinfo -x -r TestData/format-samples/ac3/tones.ac3`, and the CAF and FLAC samples, in a shell to see the shapes. It returns nil for malformed XML, no track, channels below 1, a sample rate or duration that is not a finite number above zero, or an empty format.
- **`bitsPerSample`:**
  - for `lpcm`, the track's own `bit_depth`, unless `pcm_info/data_type` is `float` (then nil, and `isFloat` is true);
  - for `alac` and `flac`, `source_info/bit_depth` when above zero;
  - otherwise nil.
- **`struct Tool: Sendable`**, as `OggAudioConverter.Tool` is (`OggAudioConverter.swift:233-259`): `command: @Sendable (URL) -> (executable: URL, arguments: [String])`, `limits: @Sendable (_ bytes: Int64) -> WatchedProcess.Limits`, and `residentMemory`. `static let afinfo` runs `/usr/bin/afinfo -x -r <path>`. Its limits are:
  - `maximumSeconds: 30 + Double(bytes) / 20_000_000`;
  - `maximumResidentBytes: 536_870_912`;
  - `maximumStalledSeconds` equal to `maximumSeconds`, since afinfo prints only when it ends.
- **`static func read(_ url: URL, using tool: Tool = .afinfo) async throws -> AudioFileInfo?`** returns nil when:
  - the file is missing, or only in the cloud (`DatalessFiles.isDataless`);
  - the tool cannot start, or exits with a status other than 0;
  - it is killed: logged with `DiagnosticLog.event(.storage, "AUDIO_INFO_KILLED: <file name>: <reason.words>")`;
  - its output does not parse.

  It throws only `CancellationError`. It never opens the file itself.

## 3. Tests: a new file `TextMouthProductionTests/AudioFileInfoTests.swift`
- **`parse`, on canned XML** (copy each from real afinfo output, trimmed):
  - a 16-bit PCM CAF;
  - ALAC with `source_info` 16;
  - float PCM;
  - AC-3 with its nested `<format>`;
  - a file name with `&amp;`;
  - malformed XML, no track, and zero channels.
- **`read`, on every audio sample** (`ac3/tones.ac3`, `eac3/tones.ec3`, `amr/tones.amr`, `3gp/tones-aac.3gp`, `3gp/tones-amr.3gp`, `mp2/tones.mp2`, `au/tones.au`, `aifc/tones-ima4.aifc`, `aifc/tones-ulaw.aifc`, `caf/tones-pcm.caf`, `caf/tones-alac.caf`, `caf/tones-opus.caf`, `w64/tones.w64`, `rf64/tones.rf64.wav`, `bwf/tones-bwf.wav`, and the three in `wav-variants/`), each copied into the test's temporary folder first.
  - Pin the format, channels, sample rate, `isLossless`, and `bitsPerSample` that afinfo reports, and the duration to within 0.05 seconds.
  - Take the expected values from a shell run of `afinfo -x -r` on each, and put them in a table in the test.
- **The stand-in tools:**
  - `/bin/sleep 30`, with `maximumSeconds` of 1, gives nil within a few seconds;
  - `/bin/sh -c "exit 3"` gives nil;
  - `/bin/echo hello` (output that is not XML) gives nil.
- **`runCapturingOutput`:**
  - with `/bin/echo` it returns the text;
  - it leaves no `.watched-output` file in the temporary directory: count them before and after;
  - a cancelled run removes its file too.
- `/opt/homebrew/bin/xcodegen generate`, and commit the project with the tests.

## Commits
1. `WatchedProcess.runCapturingOutput`, with its tests in `WatchedProcessSafetyTests` (append a section; change no existing test).
2. `AudioFileInfo`, with `AudioFileInfoTests`.

## Test classes (one run)
`AudioFileInfoTests WatchedProcessSafetyTests OggAfconvertTests UncheckedConcurrencyPolicyTests LogContentPolicyTests`

## Do not touch
`OggAudioConverter.swift` (task `convert` is renaming it), `FileImportService*`, `Book.swift`, and any `*.md`. Use `AudioFileInfo` nowhere yet: task `formats` does.
