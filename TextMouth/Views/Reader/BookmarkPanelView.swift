import SwiftUI

struct BookmarkPanelView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAddBookmark = false
    @State private var newBookmarkNote = ""
    @State private var editingBookmark: Bookmark?
    @State private var editingNote = ""

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
                .background(VoiceOverFocus())
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sortedBookmarks) { bookmark in
                            BookmarkRow(bookmark: bookmark)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.navigateToBookmark(bookmark)
                                    dismiss()
                                }
                                .accessibilityAction(.default) {
                                    viewModel.navigateToBookmark(bookmark)
                                    dismiss()
                                }
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
                .background(VoiceOverFocus())
            }
        }
        .frame(width: 380, height: 400)
        .navigationTitle("Bookmarks: \(viewModel.book.title)")
        .accessibilityLabel("Bookmarks, \(viewModel.bookmarks.count) \(viewModel.bookmarks.count == 1 ? "bookmark" : "bookmarks")")
        .sheet(isPresented: $showAddBookmark) {
            VStack(spacing: 16) {
                Text("Add Bookmark")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                TextField("Note (optional)", text: $newBookmarkNote)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Bookmark note")
                    .accessibilityHint("Optional note to describe this bookmark")
                    .background(VoiceOverFocus())

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bookmarkAccessibilityLabel)
        .accessibilityHint("Double-tap to navigate to this bookmark")
    }

    private var bookmarkAccessibilityLabel: String {
        var parts = ["Bookmark \(bookmark.number)", "Chapter \(bookmark.chapterIndex + 1)"]
        if !bookmark.label.isEmpty {
            parts.append("Note: \(bookmark.label)")
        }
        return parts.joined(separator: ", ")
    }
}
