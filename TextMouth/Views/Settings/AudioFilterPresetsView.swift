import SwiftUI

// MARK: - Words

/// The words of the filter presets' sheet (FR04), shared by its controls,
/// its announcements, and the tests.
enum AudioFilterPresetsWording {
    /// The sheet's title.
    static let title = "Filter Presets"
    /// What the presets are.
    static let explanation = "The presets the audio editor's Apply Filter lists, in this order. Each is a chain of "
        + "filters in ffmpeg's syntax, such as highpass=f=80,volume=3dB. TextMouth runs its own filters, and every "
        + "filter ffmpeg has when ffmpeg is installed and turned on above."
    /// The button that adds a preset.
    static let addButton = "Add Preset"
    /// The button that puts the premade presets back.
    static let resetAllButton = "Reset All to Defaults"
    /// What Reset All does.
    static let resetAllHint = "Puts back TextMouth's premade presets, removing the ones you added."
    /// The button that closes the sheet.
    static let doneButton = "Done"
    /// Shown when there are no presets.
    static let noPresets = "No filter presets. Add one, or reset to the defaults."
    /// The editor's titles.
    static let newTitle = "New Filter Preset"
    static let editTitle = "Edit Filter Preset"
    /// The editor's fields.
    static let nameLabel = "Name"
    static let chainLabel = "Chain"
    /// The chain field's hint.
    static let chainHint = "Filters in ffmpeg's syntax, separated by commas, each with its options after an equals sign, "
        + "separated by colons."
    /// The editor's buttons.
    static let saveButton = "Save"
    static let cancelButton = "Cancel"

    /// A preset's row, as VoiceOver reads it: its name, its chain, and
    /// whether it is a premade one changed.
    static func row(_ preset: AudioFilterPreset, isChangedPremade: Bool) -> String {
        "\(preset.name): \(preset.chain)\(isChangedPremade ? ", changed from its default" : "")"
    }

    /// Said as a preset moves.
    static func moved(_ name: String, to index: Int, of count: Int) -> String {
        "\(name) moved to position \(index + 1) of \(count)"
    }

    /// Said as a preset is deleted.
    static func deleted(_ name: String) -> String {
        "\(name) deleted"
    }

    /// Said as a premade preset is put back as it came.
    static func reset(_ name: String) -> String {
        "\(name) reset to its default"
    }

    /// Said as every preset is put back.
    static let resetAll = "The filter presets are reset to the defaults."

    /// Said as a preset is added.
    static func added(_ name: String) -> String {
        "Added \(name)"
    }

    /// Said as a preset is saved.
    static func saved(_ name: String) -> String {
        "Saved \(name)"
    }

    /// What the editor says of a chain: that TextMouth's own filters run
    /// it, or why they don't (ffmpeg may), or why it isn't a chain at all.
    static func chainCheck(_ chain: String) -> String {
        let trimmed = chain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Type a chain of filters." }
        do {
            let parsed = try AudioFilterChain.parse(trimmed)
            do {
                _ = try parsed.builtInFilters()
                return "TextMouth's own filters run this chain."
            } catch {
                return "\(error.localizedDescription) It runs only through ffmpeg."
            }
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - A Preset's Commands

/// A command for one filter preset (FR04). Each row shows every command as
/// a button, offers those that can act as VoiceOver actions, and repeats
/// them in its context menu, always under the same name, as the
/// substitution rules' commands do. Main-actor isolated, as the premade
/// presets it compares with are.
@MainActor
enum AudioFilterPresetCommand: CaseIterable {
    case edit
    case reset
    case moveUp
    case moveDown
    case delete

    /// The command's name.
    var title: String {
        switch self {
        case .edit: return "Edit"
        case .reset: return "Reset"
        case .moveUp: return "Move Up"
        case .moveDown: return "Move Down"
        case .delete: return "Delete"
        }
    }

    /// The SF Symbol drawn on its row button.
    var systemImage: String {
        switch self {
        case .edit: return "pencil"
        case .reset: return "arrow.counterclockwise"
        case .moveUp: return "arrow.up"
        case .moveDown: return "arrow.down"
        case .delete: return "trash"
        }
    }

    /// The step this command moves a preset, or nil.
    var moveDirection: SubstitutionRuleMoveDirection? {
        switch self {
        case .moveUp: return .up
        case .moveDown: return .down
        case .edit, .reset, .delete: return nil
        }
    }

    /// Whether the command can act on `preset`, at `index` of `count`:
    /// Reset only on a premade preset changed from how it came, and the
    /// moves only away from the ends.
    func isAvailable(for preset: AudioFilterPreset, at index: Int, of count: Int) -> Bool {
        switch self {
        case .reset:
            return Self.premade(preset).map { $0 != preset } ?? false
        case .moveUp, .moveDown:
            guard let moveDirection else { return false }
            return moveDirection.destination(from: index, count: count) != nil
        case .edit, .delete:
            return true
        }
    }

    /// The commands that can act on `preset`, in button order.
    static func available(for preset: AudioFilterPreset, at index: Int, of count: Int) -> [AudioFilterPresetCommand] {
        allCases.filter { $0.isAvailable(for: preset, at: index, of: count) }
    }

    /// The premade preset `preset` began as, or nil for one the user made.
    static func premade(_ preset: AudioFilterPreset) -> AudioFilterPreset? {
        AudioFilterPresetLibrary.standard.first { $0.id == preset.id }
    }
}

// MARK: - The Sheet

/// The audio editor's filter presets (FR04), opened from Storage settings'
/// Audio Editing group and shown like the substitution rules: each preset a
/// row VoiceOver reads whole, its name and chain, holding a button for
/// every command, which are also its VoiceOver actions and its context
/// menu. A premade preset changed can be reset alone, or every preset put
/// back. A new or edited preset's chain is checked as it is typed, by
/// `AudioFilterChain.parse`, and a chain that isn't one can't be saved.
/// The presets are kept in audio-filters.json in the data directory.
struct AudioFilterPresetsView: View {
    /// The presets.
    @StateObject private var library: AudioFilterPresetLibrary
    /// Closes the sheet.
    let close: () -> Void

    /// The preset being edited or added, if any.
    @State private var draft: AudioFilterPresetDraft?
    /// Why the last change couldn't be made, shown under the list.
    @State private var problem = ""

    /// The sheet over `library`'s presets: the data directory's, unless a
    /// test hands in its own.
    init(library: AudioFilterPresetLibrary = AudioFilterPresetLibrary(), close: @escaping () -> Void) {
        _library = StateObject(wrappedValue: library)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AudioFilterPresetsWording.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(AudioFilterPresetsWording.explanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(AudioFilterPresetsWording.addButton) {
                    draft = AudioFilterPresetDraft(id: UUID(), name: "", chain: "", isNew: true)
                }
                .modifier(InitialVoiceOverFocusModifier(isTarget: true))
                Spacer()
                Button(AudioFilterPresetsWording.resetAllButton) { change(saying: AudioFilterPresetsWording.resetAll) { try library.resetToDefaults() } }
                    .accessibilityHint(AudioFilterPresetsWording.resetAllHint)
                    .help(AudioFilterPresetsWording.resetAllHint)
            }
            if library.presets.isEmpty {
                Text(AudioFilterPresetsWording.noPresets)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(Array(library.presets.enumerated()), id: \.element.id) { index, preset in
                        AudioFilterPresetRow(
                            preset: preset,
                            index: index,
                            count: library.presets.count,
                            perform: { perform($0, on: preset) }
                        )
                        .contextMenu {
                            ForEach(AudioFilterPresetCommand.allCases, id: \.self) { command in
                                Button(command.title) { perform(command, on: preset) }
                                    .disabled(!command.isAvailable(for: preset, at: index, of: library.presets.count))
                            }
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            if !problem.isEmpty {
                Text(problem)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(AudioEditorWording.problemLabel(problem))
            }
            HStack {
                Spacer()
                Button(AudioFilterPresetsWording.doneButton, action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 460)
        .sheet(item: $draft) { draft in
            AudioFilterPresetEditor(draft: draft, save: save, cancel: { self.draft = nil })
        }
    }

    // MARK: - Commands

    /// Carries out `command` on `preset`, whichever control asked for it.
    private func perform(_ command: AudioFilterPresetCommand, on preset: AudioFilterPreset) {
        switch command {
        case .edit:
            draft = AudioFilterPresetDraft(id: preset.id, name: preset.name, chain: preset.chain, isNew: false)
        case .reset:
            guard let premade = AudioFilterPresetCommand.premade(preset) else { return }
            change(saying: AudioFilterPresetsWording.reset(premade.name)) { try library.update(premade) }
        case .moveUp, .moveDown:
            guard let direction = command.moveDirection else { return }
            change(saying: nil) {
                try library.move(preset.id, direction)
                if let index = library.presets.firstIndex(where: { $0.id == preset.id }) {
                    VoiceOverAnnouncer.announce(AudioFilterPresetsWording.moved(preset.name, to: index, of: library.presets.count))
                }
            }
        case .delete:
            change(saying: AudioFilterPresetsWording.deleted(preset.name)) { try library.remove(preset.id) }
        }
    }

    /// Saves `draft`, a new preset or a changed one; returns why it can't
    /// be saved, or nil once saved and the editor closed.
    private func save(_ draft: AudioFilterPresetDraft) -> String? {
        do {
            VoiceOverAnnouncer.announce(try Self.save(draft, in: library))
            problem = ""
            self.draft = nil
            return nil
        } catch {
            VoiceOverAnnouncer.announce(error.localizedDescription)
            return error.localizedDescription
        }
    }

    /// Saves `draft` into `library`, its chain checked as a chain first,
    /// and returns what to say of it.
    /// - Throws: `AudioFilterError` for a chain that isn't one, or the
    ///   library's errors, such as a blank name.
    static func save(_ draft: AudioFilterPresetDraft, in library: AudioFilterPresetLibrary) throws -> String {
        let chain = try AudioFilterChain.parse(draft.chain).text
        if draft.isNew {
            return AudioFilterPresetsWording.added(try library.add(name: draft.name, chain: chain).name)
        }
        try library.update(AudioFilterPreset(id: draft.id, name: draft.name, chain: chain))
        return AudioFilterPresetsWording.saved(draft.name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Makes a change through the library, saying `sentence` once made;
    /// a change that couldn't be made is shown and said.
    private func change(saying sentence: String?, _ make: () throws -> Void) {
        do {
            try make()
            problem = ""
            if let sentence {
                VoiceOverAnnouncer.announce(sentence)
            }
        } catch {
            problem = error.localizedDescription
            VoiceOverAnnouncer.announce(problem)
        }
    }
}

// MARK: - A Preset's Row

/// One preset in the list: its name and chain, then a button for every
/// command, dimmed where it can't act. For VoiceOver the row is a container
/// labelled with its name and chain, offering the commands that can act as
/// its actions.
struct AudioFilterPresetRow: View {
    /// The preset.
    let preset: AudioFilterPreset
    /// Its place in the list.
    let index: Int
    /// How many presets the list holds.
    let count: Int
    /// Runs a command on the preset.
    let perform: (AudioFilterPresetCommand) -> Void

    var body: some View {
        let isChangedPremade = AudioFilterPresetCommand.reset.isAvailable(for: preset, at: index, of: count)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.headline)
                Text(preset.chain)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
            }
            .accessibilityHidden(true)
            Spacer()
            ForEach(AudioFilterPresetCommand.allCases, id: \.self) { command in
                Button(action: { perform(command) }) {
                    Label(command.title, systemImage: command.systemImage)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!command.isAvailable(for: preset, at: index, of: count))
                .help(command.title)
                .accessibilityLabel("\(command.title) \(preset.name)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AudioFilterPresetsWording.row(preset, isChangedPremade: isChangedPremade))
        .accessibilityActions {
            ForEach(AudioFilterPresetCommand.available(for: preset, at: index, of: count), id: \.self) { command in
                Button(command.title) { perform(command) }
            }
        }
    }
}

// MARK: - The Editor

/// A preset being added or edited (FR04).
struct AudioFilterPresetDraft: Identifiable, Equatable {
    /// The preset's identity; a new one's own.
    let id: UUID
    /// Its name as typed.
    var name: String
    /// Its chain as typed.
    var chain: String
    /// Whether it is new.
    let isNew: Bool
}

/// The editor of one preset (FR04): its name and its chain, two plain text
/// fields VoiceOver reads as edit text, the name first, where VoiceOver
/// starts; a line under the chain says, as it is typed, whether TextMouth's
/// own filters run it, or why not. Save keeps it, unless its name is blank
/// or its chain isn't a chain, which keeps the editor open saying why.
struct AudioFilterPresetEditor: View {
    /// The preset as it was when the editor opened.
    let draft: AudioFilterPresetDraft
    /// Saves a draft; returns why it can't be saved, or nil.
    let save: (AudioFilterPresetDraft) -> String?
    /// Closes the editor with nothing saved.
    let cancel: () -> Void

    /// The name typed.
    @State private var name: String
    /// The chain typed.
    @State private var chain: String
    /// Why the last Save failed.
    @State private var problem = ""

    /// The editor of `draft`.
    init(draft: AudioFilterPresetDraft, save: @escaping (AudioFilterPresetDraft) -> String?, cancel: @escaping () -> Void) {
        self.draft = draft
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: draft.name)
        _chain = State(initialValue: draft.chain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.isNew ? AudioFilterPresetsWording.newTitle : AudioFilterPresetsWording.editTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            TextField(AudioFilterPresetsWording.nameLabel, text: $name)
                .accessibilityLabel(AudioFilterPresetsWording.nameLabel)
                .modifier(InitialVoiceOverFocusModifier(isTarget: true))
            TextField(AudioFilterPresetsWording.chainLabel, text: $chain)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel(AudioFilterPresetsWording.chainLabel)
                .accessibilityHint(AudioFilterPresetsWording.chainHint)
            Text(AudioFilterPresetsWording.chainCheck(chain))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !problem.isEmpty {
                Text(problem)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(AudioEditorWording.problemLabel(problem))
            }
            HStack {
                Spacer()
                Button(AudioFilterPresetsWording.cancelButton, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(AudioFilterPresetsWording.saveButton) {
                    problem = save(AudioFilterPresetDraft(id: draft.id, name: name, chain: chain, isNew: draft.isNew)) ?? ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 460)
    }
}
