import AppKit
import UniformTypeIdentifiers

/// The Mac's two commands on the person's own interface lines (FR39), both in the Interface Language group of Settings and
/// nowhere else: Edit Interface Text… and Export Interface Text….
///
/// Both write through `InterfaceTextOverridesWriter` (the one writer), by way of `InterfaceTextOverrides`; the iPhone's
/// export does too. Neither runs at launch: they are the person's request.
@MainActor
enum InterfaceTextEditing {
    // MARK: - Edit Interface Text…

    /// Fills `interface_text.json` with the interface language's lines as they read now, when the file does not exist or has
    /// none for the language, and opens it in the Mac's default editor. A file that has the language is opened as it is.
    ///
    /// - Parameters:
    ///   - service: The person's own lines.
    ///   - language: The interface language, whose lines are filled in.
    ///   - open: Opens the file in its default editor; tests open nothing.
    ///   - announce: Tells VoiceOver what could not be done.
    /// - Returns: Whether the file was opened.
    @discardableResult
    static func edit(
        service: InterfaceTextOverrides = .shared,
        language: String = InterfaceLanguage.current.language,
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        announce: (String) -> Void = { VoiceOverAnnouncer.announce($0) }
    ) -> Bool {
        if case .failed(let reason) = service.fillFileForEditing(language: language) {
            DiagnosticLog.event(.app, "INTERFACE_TEXT_PROBLEM: Edit Interface Text could not fill the file: \(reason)") // l10n: no (debug log text)
            announce(InterfaceTextOverridesWording.editFailed)
            return false
        }
        guard open(service.file) else {
            announce(InterfaceTextOverridesWording.editFailed)
            return false
        }
        return true
    }

    // MARK: - Export Interface Text…

    /// Asks where to save, then writes every line of the interface language as it reads now, the person's own marked.
    ///
    /// - Parameters:
    ///   - service: The person's own lines.
    ///   - language: The interface language, whose lines are exported.
    ///   - window: The window the panel belongs to; the panel stands alone when there is none.
    static func export(
        service: InterfaceTextOverrides = .shared,
        language: String = InterfaceLanguage.current.language,
        window: NSWindow? = NSApp.keyWindow
    ) {
        guard let data = service.exportData(language: language) else {
            VoiceOverAnnouncer.announce(InterfaceTextOverridesWording.exportFailed)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = InterfaceTextOverrides.exportFileName(language: language)
        panel.title = InterfaceTextOverridesWording.exportTitle
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            write(data, to: url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Writes an export to `url` in one step, and tells VoiceOver how it went.
    ///
    /// - Returns: Whether the file was written.
    @discardableResult
    static func write(_ data: Data, to url: URL, announce: (String) -> Void = { VoiceOverAnnouncer.announce($0) }) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            DiagnosticLog.event(.app, "INTERFACE_TEXT_PROBLEM: Export Interface Text could not write its file: \(InterfaceTextOverrides.describe(error))") // l10n: no (debug log text)
            announce(InterfaceTextOverridesWording.exportFailed)
            return false
        }
        announce(InterfaceTextOverridesWording.exported(fileName: url.lastPathComponent))
        return true
    }
}
