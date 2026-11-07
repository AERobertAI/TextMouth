import SwiftUI

/// Apply Filter (FR04): the filter presets, by name, each with its chain in
/// ffmpeg's syntax shown under it; what to apply it to, the selection or
/// the whole file; Preview, which plays the processed sound without
/// applying anything; and Apply.
///
/// Every control is a native one VoiceOver reads by its label: the Filter
/// pop-up, where VoiceOver starts, or Cancel when there is no preset to
/// list; the chain, as text; and the Apply to radio buttons. Return
/// applies; Escape closes, stopping a preview. The presets are read from
/// audio-filters.json as the sheet opens, so those edited in Settings are
/// the ones listed. Apply's hint says what a press does now: with
/// "Preview filters before applying" on, that it plays the filtered audio
/// first, until that preset has been previewed on that target; after
/// that, or with the setting off, that it applies.
struct AudioEditorFilterSheet: View {
    /// The window's model.
    @ObservedObject var model: AudioEditorModel

    /// The presets.
    @StateObject private var presets: AudioFilterPresetLibrary
    /// The preset chosen. It starts at the first preset listed, so the pop-up
    /// has its choice from its first drawing; it stays nil only with no
    /// presets.
    @State private var presetID: UUID?
    /// What the filter applies to.
    @State private var target: AudioEditorFilterTarget

    /// The sheet for `model`, listing `presets`, those saved in Settings
    /// unless a test gives others, and applying to the selection when there
    /// is one. The first preset starts chosen; with no presets none is, and the
    /// sheet shows `AudioEditorWording.noPresets` and no pop-up.
    init(model: AudioEditorModel, presets: AudioFilterPresetLibrary = AudioFilterPresetLibrary()) {
        self.model = model
        _presets = StateObject(wrappedValue: presets)
        _presetID = State(initialValue: presets.presets.first?.id)
        _target = State(initialValue: model.selection != nil ? .selection : .wholeFile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AudioEditorWording.filterTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if presets.presets.isEmpty {
                Text(AudioEditorWording.noPresets)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(AudioEditorWording.presetLabel, selection: $presetID) {
                    ForEach(presets.presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel(AudioEditorWording.presetLabel)
                .modifier(InitialVoiceOverFocusModifier(isTarget: true))

                if let preset {
                    Text("\(AudioEditorWording.chainLabel): \(preset.chain)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(AudioEditorWording.chainLabel)
                        .accessibilityValue(preset.chain)
                }

                Picker(AudioEditorWording.applyToLabel, selection: $target) {
                    ForEach(AudioEditorFilterTarget.allCases) { target in
                        Text(AudioEditorWording.targetTitle(target)).tag(target)
                    }
                }
                .radioGroupPickerStyle()
                .accessibilityLabel(AudioEditorWording.applyToLabel)
            }
            HStack {
                Button(isPreviewing ? AudioEditorWording.stopPreviewButton : AudioEditorWording.previewButton) {
                    if isPreviewing {
                        model.endFilterPreview()
                    } else if let preset {
                        Task { await model.previewFilter(preset, on: target) }
                    }
                }
                .disabled(preset == nil || model.isWorking)
                Spacer()
                Button(AudioEditorWording.cancelButton) {
                    model.endFilterPreview()
                    model.sheet = nil
                }
                .keyboardShortcut(.cancelAction)
                // With no preset to list there is no pop-up to start on.
                .modifier(InitialVoiceOverFocusModifier(isTarget: presets.presets.isEmpty))
                Button(AudioEditorWording.applyButton) {
                    guard let preset else { return }
                    Task { await model.chooseApply(preset, to: target) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preset == nil || model.isWorking)
                .accessibilityHint(model.applyHint(for: preset, on: target))
            }
        }
        .padding()
        .frame(minWidth: 480)
        .onDisappear {
            // Closing the sheet stops a preview, and the edited audio comes
            // back.
            model.endFilterPreview()
        }
    }

    /// The preset chosen.
    private var preset: AudioFilterPreset? {
        presets.presets.first { $0.id == presetID }
    }

    /// Whether this sheet's preview is playing.
    private var isPreviewing: Bool {
        model.filterPreview != nil
    }
}
