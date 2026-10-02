import Combine
import SwiftUI

// MARK: - Edit Mode Bar

/// Toolbar shown at the top of the library when edit mode is active.
/// Provides batch actions and selection controls that work reliably with VoiceOver.
struct EditModeBar: View {
    let selectedCount: Int
    let totalCount: Int
    /// Whether removing asks first and where deleted files go, so the
    /// Remove button says what it will do.
    let removalPreferences: RemovalPreferences
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onMove: () -> Void
    let onRemove: () -> Void
    let onDone: () -> Void

    /// The words for removing the selected books.
    private var removal: LibraryRemoveCommandWording {
        LibraryRemoveCommandWording(preferences: removalPreferences, count: selectedCount)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(selectedCount) of \(totalCount) selected")
                .font(.callout)
                .fontWeight(.medium)

            Spacer()

            Button(selectedCount == totalCount ? "Deselect All" : "Select All") {
                if selectedCount == totalCount {
                    onDeselectAll()
                } else {
                    onSelectAll()
                }
            }
            .accessibilityLabel(selectedCount == totalCount ? "Deselect all books" : "Select all \(totalCount) books")

            Button("Move") { onMove() }
                .disabled(selectedCount == 0)
                .accessibilityLabel("Move \(selectedCount) \(selectedCount == 1 ? "book" : "books") to folder")

            Button(removal.shortTitle, role: .destructive) { onRemove() }
                .disabled(selectedCount == 0)
                .accessibilityLabel(removal.accessibilityLabel)
                .accessibilityHint(removal.accessibilityHint)

            Button("Done") { onDone() }
                .fontWeight(.semibold)
                .accessibilityLabel("Exit edit mode")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit mode, \(selectedCount) of \(totalCount) books selected")
    }
}

// MARK: - Time Remaining Bar

struct TimeRemainingBar: View {
    let books: [Book]
    let wpm: Double
    /// Optional fallback focus target for the library when Continue Listening is absent.
    /// This summary is part of the content area and shows up reliably in the AX tree,
    /// unlike List section headers in this view hierarchy.
    var focusIdentifier: String? = nil
    var shouldTriggerFocus = false

    var body: some View {
        let (time, known, unknown) = computeTimeRemaining()
        if known > 0 || unknown > 0 {
            HStack(spacing: 12) {
                Label {
                    if known > 0 {
                        Text("\(TimeFormatting.format(time)) remaining")
                    }
                } icon: {
                    Image(systemName: "clock")
                        .foregroundColor(.green)
                }
                .font(.caption)

                if unknown > 0 {
                    Text("(\(unknown) \(unknown == 1 ? "book" : "books") not yet opened)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(books.count) \(books.count == 1 ? "book" : "books")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(time: time, known: known, unknown: unknown))
            .accessibilityIdentifier(focusIdentifier ?? "")
            .background(
                Group {
                    if shouldTriggerFocus {
                        StandardVoiceOverFocus(delay: 1.2)
                    }
                }
            )
        }
    }

    private func computeTimeRemaining() -> (TimeInterval, Int, Int) {
        var total: TimeInterval = 0
        var known = 0
        var unknown = 0
        for book in books {
            if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
                total += remaining
                known += 1
            } else {
                unknown += 1
            }
        }
        return (total, known, unknown)
    }

    private func accessibilityLabel(time: TimeInterval, known: Int, unknown: Int) -> String {
        var parts: [String] = []
        parts.append("\(books.count) \(books.count == 1 ? "book" : "books")")
        if known > 0 {
            parts.append("\(TimeFormatting.spoken(time)) total remaining at current speed")
        }
        if unknown > 0 {
            parts.append("\(unknown) \(unknown == 1 ? "book has" : "books have") not been opened yet")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Breadcrumb Bar

struct BreadcrumbBar: View {
    let path: String
    let onNavigate: (String) -> Void
    let onNavigateRoot: () -> Void

    var body: some View {
        HStack {
            Button("Library") { onNavigateRoot() }
                .buttonStyle(.plain)
                .accessibilityLabel("Navigate to library root")

            let parts = path.components(separatedBy: "/")
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                Button(part) {
                    let subPath = parts[0...index].joined(separator: "/")
                    onNavigate(subPath)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Navigate to \(part)")
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Folder Row

struct FolderRow: View {
    let folder: BookFolder
    var bookCount: Int = 0

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text(folder.name)
                .font(.headline)
            Spacer()
            Text("\(bookCount) \(bookCount == 1 ? "book" : "books")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(bookCount) \(bookCount == 1 ? "book" : "books")")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to open folder")
    }
}

// MARK: - Book Row

struct BookRow: View {
    let book: Book
    var isOpenInWindow: Bool = false
    var wpm: Double = 200
    var isEditMode: Bool = false
    var isEditSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Selection indicator in edit mode
            if isEditMode {
                Image(systemName: isEditSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isEditSelected ? .accentColor : .secondary)
                    .font(.title3)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(book.title)
                        .font(.headline)

                    if book.lastOpened == nil {
                        Text("New")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                    } else if isOpenInWindow {
                        Text("Now Reading")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                    }
                }
                HStack {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    if let progress = Self.progressText(for: book) {
                        Text(progress.visible)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
                        Text("\(TimeFormatting.format(remaining)) left")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(book.format.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityHint(isEditMode
            ? "Double-tap to \(isEditSelected ? "deselect" : "select")"
            : "Press Enter to open, Command I for info")
        .accessibilityAddTraits(isEditSelected ? [.isSelected] : [])
    }

    /// Spoken label for the whole row, replacing its combined children.
    var rowAccessibilityLabel: String {
        var parts: [String] = []
        if isEditMode && isEditSelected {
            parts.append("Selected")
        }
        parts.append(book.title)
        parts.append("by \(book.author)")
        if book.lastOpened == nil {
            parts.append("New")
        } else if isOpenInWindow {
            parts.append("Now Reading")
        }
        if let progress = Self.progressText(for: book) {
            parts.append(progress.spoken)
        }
        if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
            parts.append("\(TimeFormatting.spoken(remaining)) remaining")
        }
        parts.append(book.format.displayName)
        return parts.joined(separator: ", ")
    }

    /// Progress shown in a library row — visible "42%", spoken "42 percent" —
    /// or nil to hide it when it cannot be known without parsing the book.
    /// Whole percents are rounded the same way Where Am I speaks them.
    static func progressText(for book: Book) -> (visible: String, spoken: String)? {
        guard let percent = book.percentComplete else { return nil }
        let wholePercent = String(format: "%.0f", percent)
        return (visible: "\(wholePercent)%", spoken: "\(wholePercent) percent")
    }
}

// MARK: - Tree-Order Folder Sorting

extension Array where Element == BookFolder {
    /// Sort folders in tree order: each parent is immediately followed by its children,
    /// then the next sibling. Siblings are sorted alphabetically.
    /// This prevents unrelated folders like "Misc SciFi anthologies" from appearing
    /// between "Misc SciFi" and "Misc SciFi/Sub" in picker lists.
    func sortedTreeOrder() -> [BookFolder] {
        // Sort so that a folder's children appear immediately after it,
        // before any unrelated folder that shares a prefix (e.g. "Misc SciFi"
        // children before "Misc SciFi anthologies").
        //
        // Replace "/" with "\0" for comparison so path separators sort before
        // any printable character (space is 0x20, "/" is 0x2F — both after "\0").
        // This ensures "Misc SciFi\0Sub" < "Misc SciFi anthologies".
        sorted {
            let a = $0.fullPath.lowercased().replacingOccurrences(of: "/", with: "\0")
            let b = $1.fullPath.lowercased().replacingOccurrences(of: "/", with: "\0")
            return a < b
        }
    }
}

// MARK: - Removal Preferences

/// The removal preferences as config.json changes them, one value per
/// change to either preference. One shared stream, so a view that draws
/// again keeps its subscription rather than subscribing anew each time.
@MainActor
private enum RemovalPreferencesFeed {
    static let changes = ConfigService.shared.$config
        .map { RemovalPreferences($0) }
        .removeDuplicates()
}

extension View {
    /// Keeps `preferences` equal to the removal preferences in config.json,
    /// so removal buttons and confirmations always describe what removing
    /// will really do, even right after the preferences change in Settings.
    /// Only a change to one of the two preferences updates it, so other
    /// settings changes cause no redraw.
    @MainActor
    func trackingRemovalPreferences(_ preferences: Binding<RemovalPreferences>) -> some View {
        onReceive(RemovalPreferencesFeed.changes) { current in
            preferences.wrappedValue = current
        }
    }
}
