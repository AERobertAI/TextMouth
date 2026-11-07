#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Saving or Exporting

/// The sheet of a save or an export under way (FR04): what it writes, the
/// length and the format, and a progress bar VoiceOver reads as a percent,
/// where it starts. The sheet can't be dismissed: it closes as the work
/// ends, and its quarters are announced when the work takes a while.
struct AudioEditorProgressSheet: View {
    /// The window's model.
    @ObservedObject var model: AudioEditorModel

    var body: some View {
        let fraction = model.progress?.fraction ?? 0
        VStack(alignment: .leading, spacing: 12) {
            Text(model.progress?.title ?? AudioEditorWording.savingTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(model.progress?.detail ?? "")
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: fraction)
                .accessibilityLabel(AudioEditorWording.progressLabel)
                .accessibilityValue(AudioEditorWording.percentDone(Int((fraction * 100).rounded(.down))))
                .modifier(InitialVoiceOverFocusModifier(isTarget: true))
        }
        .padding()
        .frame(minWidth: 440)
        .interactiveDismissDisabled()
    }
}

// MARK: - Export

/// Export (FR04): the formats TextMouth can write the edited audio in, MP3
/// among them, which TextMouth writes itself, then Export…, which asks where
/// in a save panel and writes the file there, the book's own file left as
/// it is. VoiceOver starts on the Format pop-up.
struct AudioEditorExportSheet: View {
    /// The window's model.
    @ObservedObject var model: AudioEditorModel
    /// The formats offered.
    private let formats: [AudioExportFormat]
    /// The format chosen.
    @State private var format: AudioExportFormat

    /// The sheet for `model`, offering its session's formats.
    init(model: AudioEditorModel) {
        self.model = model
        let formats = model.session.exportFormats
        self.formats = formats
        _format = State(initialValue: formats.first ?? .m4a)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AudioEditorWording.exportTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Picker(AudioEditorWording.formatLabel, selection: $format) {
                ForEach(formats, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(AudioEditorWording.formatLabel)
            .modifier(InitialVoiceOverFocusModifier(isTarget: true))
            Text(AudioEditorWording.exportButtonHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(AudioEditorWording.cancelButton) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(AudioEditorWording.exportButton, action: chooseDestination)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(AudioEditorWording.exportButtonHint)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    /// Asks where to export to, in a save panel named for the book, then
    /// closes the sheet and exports there.
    private func chooseDestination() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = AudioEditorWording.exportTitle
        panel.nameFieldStringValue = model.exportFileName(for: format)
        panel.allowedContentTypes = UTType(filenameExtension: format.fileExtension).map { [$0] } ?? []
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chosen = format
        model.sheet = nil
        Task { await model.export(as: chosen, to: url) }
        #else
        // Phase 1 asks where to export with a file exporter; until then the
        // button does nothing on iOS.
        #endif
    }
}

// MARK: - Audio Info

/// Audio Info (FR04): the audio's length, its file, the format a save
/// writes, its edits, and whether its original is kept; and what happens
/// to this book's original audio, the global setting first. Each fact is
/// one element VoiceOver reads by its label and value; the policy is a
/// pop-up, where VoiceOver starts, with a stepper for the days when that is
/// the choice. A change applies at once.
struct AudioEditorInfoSheet: View {
    /// The window's model.
    @ObservedObject var model: AudioEditorModel
    /// The days the stepper shows.
    @State private var days: Int

    /// The sheet for `model`.
    init(model: AudioEditorModel) {
        self.model = model
        _days = State(initialValue: model.policyDays)
    }

    var body: some View {
        let session = model.session
        VStack(alignment: .leading, spacing: 10) {
            Text(AudioEditorWording.infoTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            fact(AudioEditorWording.lengthLabel, AudioEditorWording.spoken(model.duration))
            fact(AudioEditorWording.fileLabel, (session.audioFile as NSString).lastPathComponent)
            fact(AudioEditorWording.savedAsLabel, model.saveFormatName ?? "…")
            fact(AudioEditorWording.editsLabel, AudioEditorWording.edits(session.list.cursor, unsaved: session.hasUnsavedEdits))
            fact(
                AudioEditorWording.originalLabel,
                AudioEditorWording.originalStatus(kept: session.list.original != nil, deletedAt: session.list.originalDeletedAt)
            )
            Divider()
            Picker(AudioEditorWording.policyLabel, selection: Binding(
                get: { model.policyChoice },
                set: { choice in Task { await model.setPolicy(choice, days: days) } }
            )) {
                ForEach(AudioEditorPolicyChoice.allCases) { choice in
                    Text(AudioEditorWording.choiceTitle(choice, global: model.globalPolicy)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(AudioEditorWording.policyLabel)
            .accessibilityHint(AudioEditingSettingsWording.policyHint)
            .modifier(InitialVoiceOverFocusModifier(isTarget: true))
            if model.policyChoice == .deleteAfterDays {
                Stepper(
                    value: Binding(get: { days }, set: { newDays in
                        days = newDays
                        Task { await model.setPolicy(.deleteAfterDays, days: newDays) }
                    }),
                    in: Int(SettingsPolicy.recordingOriginalDays.range.lowerBound)...Int(SettingsPolicy.recordingOriginalDays.range.upperBound)
                ) {
                    Text("\(AudioEditingSettingsWording.daysLabel): \(AudioEditingSettingsWording.days(days))")
                }
                // A stepper's title does not become its accessibility label.
                .accessibilityLabel(AudioEditingSettingsWording.daysLabel)
                .accessibilityValue(AudioEditingSettingsWording.days(days))
            }
            Text(AudioEditorWording.policyChanged(model.session.policyOverride, global: model.globalPolicy))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(AudioEditorWording.closeButton) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 460)
    }

    /// One fact: its label and value, read by VoiceOver as one element.
    private func fact(_ label: String, _ value: String) -> some View {
        Text("\(label): \(value)")
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}
