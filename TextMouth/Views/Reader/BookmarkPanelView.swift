import SwiftUI

/// Tracks which sub-view the bookmark panel is showing.
/// Using inline modes instead of nested sheets avoids a macOS SwiftUI bug
/// where dismissing a sheet-on-sheet breaks the outer sheet's responder
/// chain, trapping keyboard focus and making escape / Cmd+W unresponsive.
enum BookmarkPanelMode: Equatable {
    case list
    case add
    case edit(Bookmark)
}

struct BookmarkPanelView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: BookmarkPanelMode = .list
    @State private var noteText = ""
    @FocusState private var focusedBookmarkID: UUID?
    @FocusState private var noteFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .list:
                listContent
            case .add:
                addContent
            case .edit(let bookmark):
                editContent(bookmark)
            }
        }
        .frame(width: 380, height: 400)
        .navigationTitle(viewModel.book.title)
        .onAppear {
            guard let firstBookmark = sortedBookmarks.first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedBookmarkID = firstBookmark.id
            }
        }
    }

    // MARK: - List Mode

    private var listContent: some View {
        Group {
            // Header bar
            HStack {
                Text("Bookmarks")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()

                Button {
                    noteText = ""
                    mode = .add
                } label: {
                    Label("Add Bookmark", systemImage: "plus")
                }
                .accessibilityLabel("Add bookmark at current position")
                .modifier(EmptyBookmarksFocusModifier(isEmpty: viewModel.bookmarks.isEmpty))

                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            if viewModel.bookmarks.isEmpty {
                // Empty state — grouped into a single VoiceOver element
                VStack(spacing: 8) {
                    Text("No bookmarks yet.")
                        .foregroundColor(.secondary)
                    Text("Press Cmd+B to add a bookmark at the current position.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedBookmarks.enumerated()), id: \.element.id) { index, bookmark in
                            let row = BookmarkRow(bookmark: bookmark)

                            Button {
                                viewModel.navigateToBookmark(bookmark)
                                dismiss()
                            } label: {
                                row
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                                .focusable(index == 0)
                                .focused($focusedBookmarkID, equals: index == 0 ? bookmark.id : nil)
                                .accessibilityLabel(row.bookmarkAccessibilityLabel)
                                .accessibilityHint(row.accessibilityHintText)
                                .modifier(FirstItemFocusModifier(isFirst: index == 0, delay: 1.2))
                                .contextMenu {
                                    Button("Go To") {
                                        viewModel.navigateToBookmark(bookmark)
                                        dismiss()
                                    }
                                    Button("Edit Note") {
                                        noteText = bookmark.label
                                        mode = .edit(bookmark)
                                    }
                                    Button("Delete", role: .destructive) {
                                        viewModel.removeBookmark(bookmark)
                                    }
                                }
                            Divider()
                        }
                    }
                }
                .accessibilityRotor("Bookmarks") {
                    ForEach(sortedBookmarks) { bookmark in
                        AccessibilityRotorEntry(
                            "Bookmark \(bookmark.number), Chapter \(bookmark.chapterIndex + 1)\(bookmark.label.isEmpty ? "" : ", \(bookmark.label)")",
                            id: bookmark.id
                        )
                    }
                }
            }
        }
    }

    // MARK: - Add Bookmark (Inline)

    private var addContent: some View {
        VStack(spacing: 16) {
            Text("Add Bookmark")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Note (optional)", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Bookmark note")
                .accessibilityHint("Optional note to describe this bookmark")
                .focused($noteFieldFocused)

            HStack {
                Button("Cancel") {
                    noteText = ""
                    mode = .list
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Add") {
                    viewModel.addBookmarkAtCurrentPosition(label: noteText)
                    noteText = ""
                    mode = .list
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .onAppear {
            noteFieldFocused = true
        }
    }

    // MARK: - Edit Bookmark (Inline)

    private func editContent(_ bookmark: Bookmark) -> some View {
        VStack(spacing: 16) {
            Text("Edit Bookmark \(bookmark.number)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Note", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Bookmark note")
                .focused($noteFieldFocused)

            HStack {
                Button("Cancel") {
                    mode = .list
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Save") {
                    viewModel.updateBookmarkLabel(bookmark, label: noteText)
                    mode = .list
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .onAppear {
            noteFieldFocused = true
        }
    }
}

extension BookmarkPanelView {
    var sortedBookmarks: [Bookmark] {
        viewModel.bookmarks.sorted(by: { $0.number < $1.number })
    }
}

struct BookmarkRow: View {
    let bookmark: Bookmark

    var body: some View {
        HStack {
            Image(systemName: "bookmark.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Bookmark \(bookmark.number)")
                    .font(.headline)

                Text("Chapter \(bookmark.chapterIndex + 1)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !bookmark.label.isEmpty {
                    Text(bookmark.label)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .italic()
                }
            }

            Spacer()

            Text(bookmark.dateCreated, style: .date)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    var accessibilityHintText: String {
        "Double-tap to navigate to this bookmark"
    }

    var bookmarkAccessibilityLabel: String {
        var parts = ["Bookmark \(bookmark.number)", "Chapter \(bookmark.chapterIndex + 1)"]
        if !bookmark.label.isEmpty {
            parts.append("Note: \(bookmark.label)")
        }
        return parts.joined(separator: ", ")
    }
}

private struct EmptyBookmarksFocusModifier: ViewModifier {
    let isEmpty: Bool

    func body(content: Content) -> some View {
        if isEmpty {
            content
                .accessibilityIdentifier(voiceOverFocusID)
                .background(VoiceOverFocus(delay: 1.2))
        } else {
            content
        }
    }
}
