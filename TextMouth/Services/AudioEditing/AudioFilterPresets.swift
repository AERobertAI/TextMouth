import CryptoKit
import Foundation

/// A named filter chain the editor offers (FR04): one of TextMouth's premade
/// presets, edited or not, or one the user made, in ffmpeg's syntax
/// (`AudioFilterChain`), which serves TextMouth's own filters and ffmpeg
/// alike.
struct AudioFilterPreset: Codable, Equatable, Identifiable, Sendable {
    /// Its identity, kept through renames.
    var id: UUID
    /// Its name, as the editor lists it.
    var name: String
    /// Its chain.
    var chain: String
}

/// The filter presets (FR04), kept in audio-filters.json in the data
/// directory, so another Mac sharing the library has the same ones, and
/// shown like the substitution rules: premade entries the user can edit,
/// remove, reorder, add to, and reset.
///
/// The file is read and written as substitutions.json is: with no file, as
/// at first, the premade presets stand in, unsaved, until a change copies
/// them into it; a file that can't be read or decoded is preserved beside
/// itself (`SavedFile.preserveUnusable`) and the premade presets stand in;
/// a file only in the cloud is never read, which would download it, nor
/// written over: the premade presets stand in, the sync service is asked
/// for it, and a save waits until it is on this Mac. One AUDIO_FILTERS_FILE
/// line in the debug log tells of each.
@MainActor
final class AudioFilterPresetLibrary: ObservableObject {
    /// The presets, in the order the editor lists them.
    @Published private(set) var presets: [AudioFilterPreset]
    /// Whether the presets stand in for a file that isn't there: the
    /// premade ones, unsaved.
    private(set) var standsInForMissingFile = false
    /// Whether the presets stand in for a file only in the cloud.
    private(set) var awaitsFileInCloud = false

    /// The file's name in the data directory.
    nonisolated static let fileName = "audio-filters.json"
    /// The tag of the debug log's lines about the file.
    nonisolated static let logTag = "AUDIO_FILTERS_FILE"

    /// The file.
    private let url: URL
    /// How the file is read: without downloading it, unless a test stands
    /// in a reader of its own.
    private let reader: SavedFile.Reader

    /// The presets of the file at `url`, read at once through `reader`.
    init(url: URL = TextMouthPaths.audioFiltersFile, reader: @escaping SavedFile.Reader = SavedFile.readWithoutDownloading) {
        self.url = url
        self.reader = reader
        presets = Self.standard
        load()
    }

    // MARK: The Premade Presets

    /// The presets TextMouth comes with, each made of filters its own engine
    /// runs, so they work without ffmpeg, and do the same through it, but
    /// for loudnorm: ffmpeg runs it in one pass, changing its gain as it
    /// goes, where TextMouth applies the one gain that reaches the target.
    /// Silence is trimmed at the end by reversing the sound: ffmpeg's
    /// silenceremove stops at the first silence after the start, not at the
    /// end, when told to stop once (stop_periods=1).
    static let standard: [AudioFilterPreset] = [
        premade("Remove Rumble", "highpass=f=80"),
        premade("Clearer Voice", "highpass=f=80,equalizer=f=3000:t=q:w=1:g=3"),
        premade("Even Out the Level", "acompressor=threshold=-20dB:ratio=3:attack=10:release=200:makeup=2"),
        premade("Audiobook Loudness", "loudnorm=I=-18:TP=-3"),
        // Every pause longer than a second becomes a second long.
        premade("Shorten Long Pauses", "silenceremove=stop_periods=-1:stop_duration=1:stop_threshold=-50dB"),
        premade(
            "Trim Silence at Both Ends",
            "silenceremove=start_periods=1:start_threshold=-50dB,areverse,"
                + "silenceremove=start_periods=1:start_threshold=-50dB,areverse"
        ),
        premade("Fade In", "afade=t=in:d=1"),
        premade("Fade Out (Select the Last Second)", "afade=t=out:d=1"),
        premade("A Little Faster", "atempo=1.25"),
        premade("Louder", "volume=6dB"),
        premade("Quieter", "volume=-6dB"),
        premade("Reverse", "areverse"),
    ]

    /// A premade preset, its identity made from its name, so it is the same
    /// on every Mac and after every reset.
    private static func premade(_ name: String, _ chain: String) -> AudioFilterPreset {
        let digest = Array(SHA256.hash(data: Data("TextMouth premade filter: \(name)".utf8)))
        let uuid = UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
        return AudioFilterPreset(id: uuid, name: name, chain: chain)
    }

    // MARK: Changing

    /// Adds a preset named `name` running `chain`, at the end, and saves.
    /// - Throws: `AudioFilterPresetError` for a blank name or chain, or the
    ///   save's error.
    @discardableResult
    func add(name: String, chain: String) throws -> AudioFilterPreset {
        let preset = AudioFilterPreset(id: UUID(), name: try Self.checkedName(name), chain: try Self.checkedChain(chain))
        try change { $0.append(preset) }
        return preset
    }

    /// Puts `preset` in place of the preset of the same identity, and saves.
    func update(_ preset: AudioFilterPreset) throws {
        let checked = AudioFilterPreset(id: preset.id, name: try Self.checkedName(preset.name), chain: try Self.checkedChain(preset.chain))
        try change { presets in
            guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
            presets[index] = checked
        }
    }

    /// Removes the preset `id`, and saves.
    func remove(_ id: UUID) throws {
        try change { $0.removeAll { $0.id == id } }
    }

    /// Moves the preset `id` one place in `direction`, as the substitution
    /// rules move, and saves; nothing at either end.
    func move(_ id: UUID, _ direction: SubstitutionRuleMoveDirection) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              let destination = direction.destination(from: index, count: presets.count) else { return }
        try change { $0.swapAt(index, destination) }
    }

    /// Puts the premade presets back, and saves.
    func resetToDefaults() throws {
        try change { $0 = Self.standard }
    }

    /// Makes `edit` to the presets and saves them.
    private func change(_ edit: (inout [AudioFilterPreset]) -> Void) throws {
        var edited = presets
        edit(&edited)
        try save(edited)
    }

    /// `name` trimmed, or the error refusing a blank one.
    private static func checkedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AudioFilterPresetError.blankName }
        return trimmed
    }

    /// `chain` trimmed, or the error refusing a blank one. Its filters are
    /// checked where it runs, by the engine running it: ffmpeg has filters
    /// TextMouth's own engine doesn't.
    private static func checkedChain(_ chain: String) throws -> String {
        let trimmed = chain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AudioFilterError.empty }
        return trimmed
    }

    // MARK: The File

    /// How the file is laid out: its version, then the presets in order.
    private struct File: Codable {
        var version: Int
        var presets: [AudioFilterPreset]
    }

    /// The layout this version writes.
    private static let currentVersion = 1

    /// Reads the file into `presets`, as the type describes.
    func load() {
        guard !TextMouthPaths.isDataDirectoryUnavailable else {
            presets = Self.standard
            standsInForMissingFile = false
            return
        }
        takeUp(SavedFile.read(url, using: reader))
    }

    /// Takes up what a read of the file found.
    private func takeUp(_ read: SavedFile.Read) {
        let wasAwaitingCloud = awaitsFileInCloud
        standsInForMissingFile = false
        awaitsFileInCloud = false
        switch read {
        case .missing:
            presets = Self.standard
            standsInForMissingFile = true
        case .contents(let bytes):
            do {
                presets = try JSONDecoder().decode(File.self, from: bytes).presets
            } catch {
                standIn(bytes: bytes, because: TranscriptStore.describe(error))
            }
        case .unreadable(let reason):
            standIn(bytes: nil, because: reason)
        case .inCloud:
            presets = Self.standard
            awaitsFileInCloud = true
            guard !wasAwaitingCloud else { return }
            SavedFile.requestDownload(of: url)
            DiagnosticLog.event(
                .storage,
                "\(Self.logTag): \(url.lastPathComponent) is only in the cloud, so it was not read; "
                    + "asked the sync service for it, and the premade presets stand in until it is on this Mac"
            )
        }
    }

    /// Preserves the unusable file and puts the premade presets in its place.
    private func standIn(bytes: Data?, because reason: String) {
        SavedFile.preserveUnusable(
            url,
            bytes: bytes,
            because: reason,
            logging: Self.logTag,
            in: .storage,
            standIn: "the premade presets stand in"
        )
        presets = Self.standard
    }

    /// Writes `edited` to the file and makes them the presets. A file that
    /// arrived since the premade presets stood in for a missing one is taken
    /// up instead, dropping the change, as substitutions.json's is: it holds
    /// the presets made on another Mac.
    /// - Throws: `SavedFile.InCloudError` while the file is only in the
    ///   cloud, with nothing written over it; `AudioFilterPresetError.libraryUnavailable`
    ///   while the data directory can't be used; or the write's error.
    private func save(_ edited: [AudioFilterPreset]) throws {
        guard !TextMouthPaths.isDataDirectoryUnavailable else { throw AudioFilterPresetError.libraryUnavailable }
        if awaitsFileInCloud || standsInForMissingFile {
            let read = SavedFile.read(url, using: reader)
            switch read {
            case .inCloud:
                takeUp(read)
                throw SavedFile.InCloudError(fileName: url.lastPathComponent)
            case .contents, .unreadable:
                takeUp(read)
                throw AudioFilterPresetError.fileArrived
            case .missing:
                break
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(File(version: Self.currentVersion, presets: edited)).write(to: url, options: .atomic)
        presets = edited
        standsInForMissingFile = false
    }
}

/// Why a preset change wasn't made.
enum AudioFilterPresetError: LocalizedError, Equatable {
    /// A preset needs a name.
    case blankName
    /// The data directory can't be used, so nothing can be saved.
    case libraryUnavailable
    /// audio-filters.json arrived from another Mac while the premade presets
    /// stood in for it: its presets are in use now, and the change was not
    /// made.
    case fileArrived

    var errorDescription: String? {
        switch self {
        case .blankName:
            return "A filter preset needs a name."
        case .libraryUnavailable:
            return "The library isn't available, so the filter presets can't be saved."
        case .fileArrived:
            return "The filter presets saved on another Mac just arrived, so they replaced these. Make the change again."
        }
    }
}

extension TextMouthPaths {
    /// The filter presets' file in the data directory (FR04,
    /// `AudioFilterPresetLibrary`), beside substitutions.json.
    static var audioFiltersFile: URL {
        root.appendingPathComponent(AudioFilterPresetLibrary.fileName)
    }
}
