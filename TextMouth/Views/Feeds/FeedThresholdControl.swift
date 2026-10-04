import SwiftUI

// MARK: - A Number Setting With an Off Value (FR03)

/// The words of one of the feed reader's number settings that has an off
/// value (`ThresholdSettingRule`): what it is called, how a value of it
/// reads with its unit, and what its off checkbox says.
struct FeedThresholdWording: Sendable {
    /// What the setting is called, which is the stepper's and the field's
    /// spoken label: "Delete downloads after playing".
    let label: String
    /// A value as its caption shows it and the stepper speaks it, with its
    /// unit: 1 as "1 day", 0 as "at once".
    let valuePhrase: @Sendable (Int) -> String
    /// What the caption says while the setting is off: "never".
    let offPhrase: String
    /// The off checkbox's title: "Never delete played downloads".
    let offTitle: String
    /// The field's and the stepper's spoken hint.
    let hint: String
    /// The off checkbox's spoken hint.
    let offHint: String

    /// The caption for `value` under `rule`: "Delete downloads after
    /// playing: 1 day", or "…: never" while it is off.
    func caption(_ value: Int, rule: ThresholdSettingRule) -> String {
        "\(label): \(FeedThresholdControl.isOff(value, rule: rule) ? offPhrase : valuePhrase(value))"
    }
}

/// One of the feed reader's number settings that has an off value (FR03),
/// drawn as the Repeated Symbols threshold is: a caption naming the setting
/// and its value with its unit, a number field and a stepper over the
/// setting's range, both labelled, with the unit in the value they speak,
/// and a checkbox for the off value, which dims the number while checked
/// and, unchecked, restores the last number. A number typed is validated as
/// a stored one is, so typing the off value, or any number below it, checks
/// the box.
struct FeedThresholdControl: View {
    /// The setting's range, off value, and default.
    let rule: ThresholdSettingRule
    /// The setting's words.
    let wording: FeedThresholdWording
    /// The value, the off value included.
    @Binding var value: Int
    /// Whether the controls are unavailable, as while Feed Info follows the
    /// global setting.
    var isDisabled = false

    /// The number the field and stepper show while the setting is off, and
    /// the one unchecking the box restores: the last number in the range,
    /// or the default when there has been none.
    @State private var lastOnValue: Int

    /// A control for `value` under `rule`, worded by `wording`.
    init(rule: ThresholdSettingRule, wording: FeedThresholdWording, value: Binding<Int>, isDisabled: Bool = false) {
        self.rule = rule
        self.wording = wording
        _value = value
        self.isDisabled = isDisabled
        _lastOnValue = State(initialValue: Self.onValue(value.wrappedValue, rule: rule))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The caption repeats what the field and stepper say, so it is
            // hidden from VoiceOver rather than read twice.
            Text(wording.caption(value, rule: rule))
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Group {
                    // In a Form, macOS draws a text field's title as a label
                    // beside it, inside the field's own width, leaving the
                    // number no room; the caption above already says it, and
                    // VoiceOver hears the accessibility label.
                    TextField(wording.label, value: numberBinding, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .accessibilityLabel(wording.label)
                        .accessibilityHint(wording.hint)
                    // The stepper's own label is empty: a hidden label would
                    // be spoken before the accessibility label.
                    Stepper(value: numberBinding, in: rule.range) {
                        EmptyView()
                    }
                    .accessibilityLabel(wording.label)
                    .accessibilityValue(wording.valuePhrase(shownNumber))
                    .accessibilityHint(wording.hint)
                }
                .disabled(isDisabled || isOff)

                Spacer(minLength: 12)

                Toggle(wording.offTitle, isOn: offBinding)
                    .disabled(isDisabled)
                    .accessibilityHint(wording.offHint)
            }
        }
        .onChange(of: value) { _, newValue in
            // A value set elsewhere, such as in config.json, becomes the one
            // unchecking the box restores.
            if !Self.isOff(newValue, rule: rule) {
                lastOnValue = newValue
            }
        }
    }

    // MARK: Bindings

    /// Whether the setting is off.
    private var isOff: Bool {
        Self.isOff(value, rule: rule)
    }

    /// The number the field and stepper show: the value, or while the
    /// setting is off, the last number, dimmed.
    private var shownNumber: Int {
        Self.shownNumber(value, remembering: lastOnValue, rule: rule)
    }

    /// The field's and the stepper's number, validated as a stored value is.
    private var numberBinding: Binding<Int> {
        Binding(
            get: { shownNumber },
            set: { number in
                value = rule.validated(number)
                if !Self.isOff(value, rule: rule) {
                    lastOnValue = value
                }
            }
        )
    }

    /// The off checkbox: checked while the setting is off; checking it
    /// stores the off value, and unchecking it the last number.
    private var offBinding: Binding<Bool> {
        Binding(
            get: { isOff },
            set: { off in
                value = Self.value(off: off, remembering: lastOnValue, rule: rule)
            }
        )
    }

    // MARK: Logic

    // The control's rules, apart from the view, so that tests can check what
    // its checkbox stores: SwiftUI's checkboxes take no press from a test.

    /// Whether `value` switches the setting off under `rule`: the off value,
    /// or any number below it.
    nonisolated static func isOff(_ value: Int, rule: ThresholdSettingRule) -> Bool {
        value <= rule.offValue
    }

    /// The number the field and stepper show for `value`: the value itself,
    /// or while it is off, `remembered`, the number unchecking the box
    /// restores.
    nonisolated static func shownNumber(_ value: Int, remembering remembered: Int, rule: ThresholdSettingRule) -> Int {
        isOff(value, rule: rule) ? remembered : value
    }

    /// The value to store as the off checkbox becomes `off`: the off value,
    /// or `remembered`, the last number in the range.
    nonisolated static func value(off: Bool, remembering remembered: Int, rule: ThresholdSettingRule) -> Int {
        off ? rule.offValue : remembered
    }

    /// `value` when it is in the range, and otherwise the default: the
    /// number to remember as the control opens.
    nonisolated static func onValue(_ value: Int, rule: ThresholdSettingRule) -> Int {
        isOff(value, rule: rule) ? rule.defaultValue : value
    }
}

// MARK: - The Feed Reader's Number Settings

extension FeedThresholdWording {
    /// How often feeds refresh while TextMouth runs.
    static let refreshInterval = FeedThresholdWording(
        label: "Refresh feeds every",
        valuePhrase: { CountWording.phrase($0, singular: "hour", plural: "hours") },
        offPhrase: "only at launch and when you ask",
        offTitle: "Only at launch and when I ask",
        hint: "Hours between refreshes of every feed while TextMouth runs, from 1 to 168",
        offHint: "When checked, feeds refresh only when TextMouth opens, if that is on, and when you choose Check Feed or Refresh All Feeds"
    )

    /// How many of each feed's newest entries are kept besides its downloads.
    static let keepEntries = FeedThresholdWording(
        label: "Keep the newest",
        valuePhrase: { CountWording.phrase($0, singular: "entry", plural: "entries") },
        offPhrase: "every entry",
        offTitle: "Keep every entry",
        hint: "How many of each feed's newest episodes and articles are listed, from 0 to 2,000; downloaded ones are always kept",
        offHint: "When checked, every entry the feed has listed since you subscribed is kept"
    )

    /// How long after playing a download is deleted.
    static let deleteDownloadsAfterPlaying = FeedThresholdWording(
        label: "Delete downloads after playing",
        valuePhrase: { $0 == 0 ? "at once" : CountWording.phrase($0, singular: "day", plural: "days") },
        offPhrase: "never",
        offTitle: "Never delete played downloads",
        hint: "Days after an episode plays to the end that its download is deleted, from 0, at once, to 365; one open in a reader waits until it closes",
        offHint: "When checked, played downloads are kept until you delete them"
    )
}
