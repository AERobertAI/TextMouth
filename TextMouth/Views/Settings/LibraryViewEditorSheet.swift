import SwiftUI

/// A folder a Folder condition can name, as the editor's folder pop-up
/// lists it: by its identity, which survives renaming and moving it, and
/// its path, as the Move dialog names it.
struct LibraryFolderChoice: Identifiable, Equatable {
    /// The folder's identity.
    let id: UUID
    /// Its path, such as "Fiction/Short".
    let path: String

    /// The folders of `library`, in tree order.
    static func choices(in library: Library) -> [LibraryFolderChoice] {
        library.folders.sortedTreeOrder().map { LibraryFolderChoice(id: $0.id, path: $0.fullPath) }
    }

    /// The name a description or the pop-up gives the folder `id` among
    /// `choices`: Library Root for nil, its path, or that it is no longer in
    /// the library.
    static func name(of id: UUID?, among choices: [LibraryFolderChoice]) -> String {
        guard let id else { return LibraryFolderOption.rootLabel }
        return choices.first { $0.id == id }?.path ?? LibraryViewEditorWording.missingFolder
    }
}

/// The sheet that makes and changes a view (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 7): its name, what it
/// lists, its conditions, its sort and limit, and a live count of what it
/// lists, over the Settings window. Every control has a spoken label naming
/// its condition, every pop-up a bounded width, and Return saves and Escape
/// cancels. The Library tab checks and saves the draft.
struct LibraryViewEditorSheet: View {
    /// The draft.
    @ObservedObject var model: LibraryViewEditorModel
    /// The folders a Folder condition can name.
    let folders: [LibraryFolderChoice]
    /// What the draft lists now, as the count says it, worked out by the
    /// tab with the draft's own sort (review of October 31, 2026, finding 8).
    let count: () -> String
    /// Closes the sheet, changing nothing.
    let onCancel: () -> Void
    /// Asks the tab to check and save the draft.
    let onSave: () -> Void

    /// The sheet's size, within the Settings window.
    static let size = CGSize(width: 620, height: 520)
    /// The widest any pop-up grows.
    static let popUpWidth: CGFloat = 220

    /// The wording, named once.
    private typealias Wording = LibraryViewEditorWording

    var body: some View {
        VStack(spacing: 0) {
            Text(model.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding()
            Form {
                nameSection
                listsSection
                conditionsSection
                orderSection
                Section {
                    Text(count())
                }
            }
            .formStyle(.grouped)
            .checkboxToggleStyle()
            .textFieldStyle(.roundedBorder)
            Divider()
            HStack {
                if let problem = model.problem {
                    Text(problem)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(Wording.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(Wording.save, action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: - Sections

    /// The name.
    private var nameSection: some View {
        Section {
            TextField(Wording.nameLabel, text: $model.name)
                .accessibilityLabel(Wording.nameLabel)
        }
    }

    /// What the view lists: a checkbox per kind, under what conditions test.
    private var listsSection: some View {
        Section(Wording.listsLabel) {
            Text(Wording.listsCaption)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(LibraryViewItemKind.allCases, id: \.self) { kind in
                Toggle(Wording.kindName(kind), isOn: Binding(
                    get: { model.lists.contains(kind) },
                    set: { isOn in
                        if isOn {
                            model.lists.insert(kind)
                        } else {
                            model.lists.remove(kind)
                        }
                    }
                ))
            }
        }
    }

    /// Match, the conditions, and Add Condition.
    private var conditionsSection: some View {
        Section(Wording.conditionsHeader) {
            Picker(Wording.matchLabel, selection: $model.match) {
                ForEach(LibraryViewMatch.allCases, id: \.self) { match in
                    Text(Wording.matchName(match)).tag(match)
                }
            }
            .frame(maxWidth: Self.popUpWidth + 120)
            if model.conditions.isEmpty {
                Text(Wording.noConditions)
                    .foregroundColor(.secondary)
            }
            ForEach(Array(model.conditions.enumerated()), id: \.element.id) { index, draft in
                conditionRow(draft.id, number: index + 1)
            }
            Button(Wording.addCondition) { model.addCondition() }
                .disabled(!model.canAddCondition)
                .help(model.canAddCondition ? "" : Wording.conditionLimitHint)
                .accessibilityHint(model.canAddCondition ? "" : Wording.conditionLimitHint)
        }
    }

    /// One feed's latest, the sort, and the limit.
    private var orderSection: some View {
        Section {
            // Dimmed, its hint saying why, while no episode or article is
            // listed (review of October 31, 2026, finding 6).
            Toggle(Wording.onePerFeedTitle, isOn: $model.onePerFeed)
                .disabled(!model.onePerFeedApplies)
                .accessibilityHint(model.onePerFeedApplies ? Wording.onePerFeedHint : Wording.onePerFeedUnavailableHint)
                .help(model.onePerFeedApplies ? Wording.onePerFeedHint : Wording.onePerFeedUnavailableHint)
            if model.lists == [.feeds] {
                Text(Wording.feedsOnlySortNote)
                    .foregroundColor(.secondary)
            } else {
                Picker(Wording.sortByLabel, selection: $model.sortField) {
                    ForEach(LibrarySortField.allCases, id: \.self) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .frame(maxWidth: Self.popUpWidth + 120)
                Picker(Wording.orderLabel, selection: $model.sortAscending) {
                    Text(Wording.orderName(ascending: true)).tag(true)
                    Text(Wording.orderName(ascending: false)).tag(false)
                }
                .frame(maxWidth: Self.popUpWidth + 120)
                .disabled(model.sortField == .manual)
                .help(model.sortField == .manual ? LibrarySortState.manualOrderHasNoDirection : "")
                .accessibilityHint(model.sortField == .manual ? LibrarySortState.manualOrderHasNoDirection : "")
            }
            // Dimmed with its field and Chosen By, its hint saying why, while
            // the view lists feeds alone (review finding 6).
            Toggle(Wording.limitTitle, isOn: $model.limitIsOn)
                .disabled(!model.limitApplies)
                .accessibilityHint(model.limitApplies ? "" : Wording.limitUnavailableHint)
                .help(model.limitApplies ? "" : Wording.limitUnavailableHint)
            HStack {
                TextField(Wording.limitFieldLabel, value: $model.limitCount, format: .number)
                    .frame(width: 80)
                    .accessibilityLabel(Wording.limitFieldLabel)
                Stepper(Wording.limitFieldLabel, value: $model.limitCount, in: LibraryViewLimit.countRange)
                    .labelsHidden()
                    .accessibilityLabel(Wording.limitFieldLabel)
                Picker(Wording.chosenByLabel, selection: $model.limitChosenBy) {
                    ForEach(LibraryViewLimit.Order.allCases, id: \.self) { order in
                        Text(Wording.limitOrderName(order)).tag(order)
                    }
                }
                .frame(maxWidth: Self.popUpWidth + 100)
            }
            .disabled(!model.limitIsOn || !model.limitApplies)
        }
    }

    // MARK: - A Condition

    /// The row of the condition `id`, numbered `number` in every spoken
    /// label: its test and relation, Remove, then the value its test needs.
    private func conditionRow(_ id: UUID, number: Int) -> some View {
        let draft = binding(for: id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(Wording.conditionLabel(number), selection: draft.kind) {
                    ForEach(LibraryViewCondition.Kind.allCases, id: \.self) { kind in
                        Text(Wording.testName(kind)).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: Self.popUpWidth)
                .accessibilityLabel(Wording.conditionLabel(number))
                Picker(Wording.relationLabel(number), selection: draft.isNegated) {
                    Text(Wording.relationName(draft.wrappedValue.kind, isNegated: false)).tag(false)
                    Text(Wording.relationName(draft.wrappedValue.kind, isNegated: true)).tag(true)
                }
                .labelsHidden()
                .frame(maxWidth: Self.popUpWidth)
                .accessibilityLabel(Wording.relationLabel(number))
                Spacer(minLength: 0)
                Button(Wording.removeTitle) { model.removeCondition(id) }
                    .accessibilityLabel(Wording.removeLabel(number))
            }
            valueControls(draft, number: number)
        }
    }

    /// The control the condition's test needs for its value, if any.
    @ViewBuilder
    private func valueControls(_ draft: Binding<LibraryViewConditionDraft>, number: Int) -> some View {
        switch draft.wrappedValue.kind {
        case .format:
            Picker(Wording.formatLabel(number), selection: draft.format) {
                ForEach(BookFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .labelsHidden()
            .frame(maxWidth: Self.popUpWidth)
            .accessibilityLabel(Wording.formatLabel(number))
        case .folder:
            HStack {
                Picker(Wording.folderLabel(number), selection: draft.folderID) {
                    Text(LibraryFolderOption.rootLabel).tag(UUID?.none)
                    ForEach(folders) { folder in
                        Text(folder.path).tag(UUID?.some(folder.id))
                    }
                    // A folder no longer in the library stays chosen, named so.
                    if let missing = draft.wrappedValue.folderID, !folders.contains(where: { $0.id == missing }) {
                        Text(Wording.missingFolder).tag(UUID?.some(missing))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: Self.popUpWidth)
                .accessibilityLabel(Wording.folderLabel(number))
                Toggle(Wording.subfoldersTitle, isOn: draft.includingSubfolders)
                    .accessibilityLabel(Wording.subfoldersLabel(number))
            }
        case .readingState:
            Picker(Wording.readingStateLabel(number), selection: draft.readingState) {
                ForEach(LibraryReadingState.allCases, id: \.self) { state in
                    Text(Wording.stateName(state)).tag(state)
                }
            }
            .labelsHidden()
            .frame(maxWidth: Self.popUpWidth)
            .accessibilityLabel(Wording.readingStateLabel(number))
        case .addedWithin, .openedWithin:
            HStack {
                TextField(Wording.daysLabel(number), value: draft.days, format: .number)
                    .frame(width: 70)
                    .accessibilityLabel(Wording.daysLabel(number))
                Stepper(Wording.daysLabel(number), value: draft.days, in: LibraryViewCondition.dayRange)
                    .labelsHidden()
                    .accessibilityLabel(Wording.daysLabel(number))
                Text(Wording.daysCaption)
                    .accessibilityHidden(true)
            }
        case .titleOrAuthorContains:
            TextField(Wording.textLabel(number), text: draft.text)
                .frame(maxWidth: Self.popUpWidth + 160)
                .accessibilityLabel(Wording.textLabel(number))
        case .inReadingList, .hasNewItems, .subscribed:
            EmptyView()
        }
    }

    /// A binding to the condition `id`, found by its identity each time, so
    /// a row removed while SwiftUI still draws it reads its last value
    /// rather than another row's, and never an index out of range.
    private func binding(for id: UUID) -> Binding<LibraryViewConditionDraft> {
        let fallback = model.conditions.first { $0.id == id } ?? .newCondition()
        return Binding(
            get: { model.conditions.first { $0.id == id } ?? fallback },
            set: { changed in
                if let index = model.conditions.firstIndex(where: { $0.id == id }) {
                    model.conditions[index] = changed
                }
            }
        )
    }
}
