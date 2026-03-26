import SwiftUI

struct BookmarkPanelView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAddBookmark = false
    @State private var newBookmarkNote = ""
    @State private var editingBookmark: Bookmark?
    @State private var editingNote = ""
    @FocusState private var focusedBookmarkID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bookmarks")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()

                Button {
                    showAddBookmark = true
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
                VStack(spacing: 8) {
                    Text("No bookmarks yet.")
                        .foregroundColor(.secondary)
                    Text("Press Cmd+B to add a bookmark at the current position.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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
                                        editingBookmark = bookmark
                                        editingNote = bookmark.label
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
        .frame(width: 380, height: 400)
        .navigationTitle("Bookmarks: \(viewModel.book.title)")
        .accessibilityLabel("Bookmarks, \(viewModel.bookmarks.count) \(viewModel.bookmarks.count == 1 ? "bookmark" : "bookmarks")")
        .onAppear {
            guard let firstBookmark = sortedBookmarks.first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedBookmarkID = firstBookmark.id
            }
        }
        .sheet(isPresented: $showAddBookmark) {
            VStack(spacing: 16) {
                Text("Add Bookmark")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                TextField("Note (optional)", text: $newBookmarkNote)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Bookmark note")
                    .accessibilityHint("Optional note to describe this bookmark")

                HStack {
                    Button("Cancel") {
                        newBookmarkNote = ""
                        showAddBookmark = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])

                    Spacer()

                    Button("Add") {
                        viewModel.addBookmarkAtCurrentPosition(label: newBookmarkNote)
                        newBookmarkNote = ""
                        showAddBookmark = false
                    }
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding()
            .frame(width: 320)
            .navigationTitle("Add Bookmark: \(viewModel.book.title)")
        }
        .sheet(item: $editingBookmark) { bookmark in
            VStack(spacing: 16) {
                Text("Edit Bookmark \(bookmark.number)")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                TextField("Note", text: $editingNote)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Bookmark note")

                HStack {
                    Button("Cancel") {
                        editingBookmark = nil
                    }
                    .keyboardShortcut(.escape, modifiers: [])

                    Spacer()

                    Button("Save") {
                        viewModel.updateBookmarkLabel(bookmark, label: editingNote)
                        editingBookmark = nil
                    }
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding()
            .frame(width: 320)
            .navigationTitle("Edit Bookmark \(bookmark.number): \(viewModel.book.title)")
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
