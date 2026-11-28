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
        SentenceWording.labelled(label, FeedThresholdControl.isOff(value, rule: rule) ? offPhrase : valuePhrase(value))
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
                FeedNumberField(
                    label: wording.label,
                    hint: wording.hint,
                    spokenValue: wording.valuePhrase(shownNumber),
                    range: rule.range,
                    number: numberBinding
                )
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

// MARK: - A Number Field and Its Stepper (FR03, FR11)

/// The number of one of the feed reader's settings, as every one of them is
/// drawn: a number field wide enough for the number, then a stepper over
/// the setting's range, each labelled with the setting's name and hinted,
/// the stepper speaking the number with its unit ("10 entries"), so
/// VoiceOver and a braille display meet the field and the stepper each on
/// its own. The threshold controls (`FeedThresholdControl`) and the "List
/// and download" number (`FeedItemPolicyControls`) draw their numbers with
/// it, and dim it with `.disabled(_:)`, which reaches both.
///
/// The caption naming the setting and its value is the caller's: the
/// field's own title is hidden, since in a Form macOS draws a text field's
/// title as a label inside the field's own width, leaving the number no
/// room.
struct FeedNumberField: View {
    /// The setting's name: the field's and the stepper's spoken label.
    let label: String
    /// The field's and the stepper's spoken hint.
    let hint: String
    /// The number as the stepper speaks it, with its unit.
    let spokenValue: String
    /// The numbers the stepper steps through.
    let range: ClosedRange<Int>
    /// The number, which the caller validates as it is set.
    let number: Binding<Int>

    var body: some View {
        TextField(label, value: number, format: .number)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 60)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
        // The stepper's own label is empty: a hidden label would be spoken
        // before the accessibility label.
        Stepper(value: number, in: range) {
            EmptyView()
        }
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
        .accessibilityHint(hint)
    }
}

// MARK: - The Feed Reader's Number Settings

extension FeedThresholdWording {
    /// How often feeds refresh while TextMouth runs.
    static var refreshInterval: FeedThresholdWording {
        FeedThresholdWording(
            // Translators: Label of the number field and stepper that say how many hours pass between refreshes of every feed.
            label: InterfaceText.line("feedThreshold.refreshInterval.every", "Refresh feeds every"),
            valuePhrase: { CountWording.hours($0) },
            // Translators: What the caption of the refresh interval says while the setting is off: "Refresh feeds every: only at launch and when you ask". Lower case.
            offPhrase: InterfaceText.line("feedThreshold.refreshInterval.launchAsk", "only at launch and when you ask"),
            // Translators: Title of the checkbox that turns the refresh interval off, so feeds refresh only at launch and on request.
            offTitle: InterfaceText.line("feedThreshold.refreshInterval.iAsk", "Only at launch and when I ask"),
            // Translators: VoiceOver hint of the refresh interval's number field and stepper. The range is the limits of the number, in hours.
            hint: InterfaceText.line("feedThreshold.refreshInterval.refreshes", "Hours between refreshes while TextMouth runs, from 1 to 168"),
            // Translators: VoiceOver hint of the checkbox that turns the refresh interval off. The first %@ is the name of the Check Feed command; the second is the name of the Refresh All Feeds command.
            offHint: InterfaceText.line("feedThreshold.refreshInterval.choose", "Feeds refresh only at launch, if that is on, and when you choose \(FeedWording.checkFeedTitle) or \(FeedWording.refreshAllCommand)")
        )
    }

    /// How long after playing a download is deleted.
    static var deleteDownloadsAfterPlaying: FeedThresholdWording {
        FeedThresholdWording(
            // Translators: Label of the number field and stepper that say how many days after an episode plays its download is deleted.
            label: InterfaceText.line("feedThreshold.deleteAfterPlaying.label", "Delete downloads after playing"),
            valuePhrase: { days in
                days == 0
                    // Translators: The value of the days after playing that a download is deleted, when it is 0: the download is deleted as soon as it has played. Lower case.
                    ? InterfaceText.line("feedThreshold.deleteAfterPlaying.once", "at once")
                    // Translators: A number of days, as the setting that deletes downloads after playing says it. %lld is the number of days.
                    : InterfaceText.line("common.countDays", "\(number: days) days")
            },
            // Translators: What the caption of the delete-after-playing setting says while the setting is off: "Delete downloads after playing: never". Lower case.
            offPhrase: InterfaceText.line("feedThreshold.deleteAfterPlaying.never", "never"),
            // Translators: Title of the checkbox that turns off deleting downloads after playing.
            offTitle: InterfaceText.line("feedThreshold.deleteAfterPlaying.played", "Never delete played downloads"),
            // Translators: VoiceOver hint of the delete-after-playing number field and stepper. The range is the limits of the number, in days.
            hint: InterfaceText.line("feedThreshold.deleteAfterPlaying.finishes", "Days after an episode finishes before its download is deleted, from 0 (at once) to 365; one open in a reader waits until it closes"),
            // Translators: VoiceOver hint of the checkbox that turns off deleting downloads after playing.
            offHint: InterfaceText.line("feedThreshold.deleteAfterPlaying.kept", "Played downloads are kept until you delete them")
        )
    }
}
