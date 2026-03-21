import SwiftUI
import AppKit

struct TextInputView: View {
    let onAdd: (String, String, String) -> Void  // title, author, text
    let onCancel: () -> Void

    @State private var title: String
    @State private var author = "Unknown"
    @State private var textContent = ""
    @State private var editorTempURL: URL?
    @State private var showReload = false

    init(onAdd: @escaping (String, String, String) -> Void, onCancel: @escaping () -> Void) {
        self.onAdd = onAdd
        self.onCancel = onCancel
        // Default title: "Paste YYYY-MM-DD HH:mm"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        self._title = State(initialValue: "Paste \(formatter.string(from: Date()))")
    }

    var body: some View {
        VStack(spacing: 12) {
            // MARK: - Title and Author Fields
            HStack {
                Text("Title:")
                    .accessibilityHidden(true)
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Title")
                    .accessibilityHint("Enter a title for the new book")
            }

            HStack {
                Text("Author:")
                    .accessibilityHidden(true)
                TextField("Author", text: $author)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Author")
                    .accessibilityHint("Enter the author name")
            }

            // MARK: - Top Button Bar
            HStack(spacing: 10) {
                Button("Paste from Clipboard") {
                    pasteFromClipboard()
                }
                .accessibilityLabel("Paste from Clipboard")
                .accessibilityHint("Replaces the text content with text from the system clipboard")

                Button("Open in Editor") {
                    openInEditor()
                }
                .accessibilityLabel("Open in Editor")
                .accessibilityHint("Opens the text content in an external text editor")

                if showReload {
                    Button("Reload from Editor") {
                        reloadFromEditor()
                    }
                    .accessibilityLabel("Reload from Editor")
                    .accessibilityHint("Reloads the text content from the external editor file")
                }

                Spacer()
            }

            // MARK: - Text Editor
            TextEditor(text: $textContent)
                .font(.body)
                .border(Color.secondary.opacity(0.3), width: 1)
                .accessibilityLabel("Text content")
                .accessibilityHint("Enter or paste the text for the new book")
                .accessibilityValue(textContent.isEmpty ? "Empty" : "\(textContent.count) characters")

            // MARK: - Bottom Buttons
            HStack {
                Spacer()

                Button("Cancel") {
                    cleanupTempFile()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel")
                .accessibilityHint("Cancels creating a new book and closes this view")

                Button("Add to Library") {
                    cleanupTempFile()
                    onAdd(title, author, textContent)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add to Library")
                .accessibilityHint(
                    textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Disabled. Enter some text content first."
                        : "Adds the new book to your library"
                )
            }
        }
        .padding()
        .frame(width: 600, height: 500)
        .navigationTitle("New Book from Text")
    }

    // MARK: - Actions

    private func pasteFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string) {
            textContent = string
        }
    }

    private func openInEditor() {
        let tempDir = NSTemporaryDirectory()
        let fileName = "TextMouth_\(UUID().uuidString).txt"
        let fileURL = URL(fileURLWithPath: tempDir).appendingPathComponent(fileName)

        do {
            try textContent.write(to: fileURL, atomically: true, encoding: .utf8)
            editorTempURL = fileURL
            NSWorkspace.shared.open(fileURL)
            showReload = true
        } catch {
            // If writing fails, do nothing; the user can try again.
        }
    }

    private func reloadFromEditor() {
        guard let url = editorTempURL else { return }
        do {
            textContent = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // If reading fails, leave content unchanged.
        }
    }

    private func cleanupTempFile() {
        guard let url = editorTempURL else { return }
        try? FileManager.default.removeItem(at: url)
        editorTempURL = nil
    }
}
