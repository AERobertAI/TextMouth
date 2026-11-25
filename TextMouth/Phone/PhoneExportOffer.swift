import Foundation

/// What the iPhone's Export sheet offers and says at each stage of an export
/// (FR31), decided from plain values so the Mac's test host reads it: which
/// kinds the iPhone offers, which buttons the sheet's bar holds in which order,
/// and what its folder row says. Every word is the Mac's, called where it
/// lives (`BookExportWording`); the sheet only draws what is decided here.
enum PhoneExportOffer {
    // MARK: - What Is Offered

    /// The kinds the iPhone offers: every kind but spoken audio, which waits
    /// for the continued processing task that lets it run with the screen
    /// locked (the design's phase 2).
    static let kinds: Set<BookExportKind> = Set(BookExportKind.allCases).subtracting([.spokenAudio])

    // MARK: - The Sheet's Stages

    /// Where the sheet is: the model's phase, without what it holds.
    enum Stage: Equatable, Sendable {
        /// Finding what the books hold.
        case listing
        /// Showing the kinds, ready to export.
        case ready
        /// An export is under way.
        case exporting
        /// An export has ended; the sheet stays open to say what it did.
        case finished

        /// The stage `phase` of the model is.
        init(_ phase: BookExportModel.Phase) {
            switch phase {
            case .listing: self = .listing
            case .ready: self = .ready
            case .exporting: self = .exporting
            case .finished: self = .finished
            }
        }
    }

    /// What fills the sheet's list under its bar.
    enum Content: Equatable, Sendable {
        /// "Finding what can be exported…", while the books are listed.
        case listing
        /// "There is nothing to export.", when the books hold nothing the
        /// iPhone offers.
        case nothingToExport
        /// A switch for each kind, the folder row, and what follows.
        case kinds
    }

    /// What fills the list at `stage`, when the books hold `kindCount` kinds
    /// the iPhone offers.
    static func content(stage: Stage, kindCount: Int) -> Content {
        if stage == .listing { return .listing }
        return kindCount == 0 ? .nothingToExport : .kinds
    }

    // MARK: - The Bar

    /// One button of the sheet's bar.
    struct BarButton: Equatable, Sendable {
        /// What the button does.
        enum Role: Hashable, Sendable {
            /// Closes the sheet without exporting.
            case cancel
            /// Stops the export under way.
            case stop
            /// Closes the sheet once an export has ended.
            case close
            /// Exports the kinds that are on.
            case export
        }

        /// What the button does.
        let role: Role
        /// The button's title, which is also its label.
        let title: String
        /// What VoiceOver says of what it does; empty for none.
        let hint: String
        /// Whether it can be pressed; a button that can't is dimmed.
        let isEnabled: Bool
    }

    /// The bar's buttons at `stage`, in VoiceOver's order, which is the
    /// order the spec gives after the title: Cancel, or Stop while an export
    /// runs, or Close once one has ended; then Export. Export is dimmed
    /// unless `canExport`: a folder is chosen and an available kind is on
    /// (`BookExportModel.canExport`).
    static func bar(stage: Stage, canExport: Bool) -> [BarButton] {
        let leading: BarButton
        switch stage {
        case .listing, .ready:
            leading = BarButton(role: .cancel, title: BookExportWording.cancelTitle, hint: "", isEnabled: true)
        case .exporting:
            leading = BarButton(role: .stop, title: BookExportWording.stopTitle, hint: BookExportWording.stopHint, isEnabled: true)
        case .finished:
            leading = BarButton(role: .close, title: BookExportWording.closeTitle, hint: "", isEnabled: true)
        }
        let export = BarButton(
            role: .export,
            title: BookExportWording.exportTitle,
            hint: BookExportWording.exportHint,
            isEnabled: canExport
        )
        return [leading, export]
    }

    // MARK: - The Folder Row

    /// The folder row's words, a button that opens the system's folder
    /// picker.
    struct FolderRow: Equatable, Sendable {
        /// What the row shows and VoiceOver reads: "Choose Folder…" until a
        /// folder is chosen, then "Export to: Downloads".
        let label: String
        /// What VoiceOver says of what it does.
        let hint: String
    }

    /// The folder row for the folder named `folderName`, nil while none is
    /// chosen.
    static func folderRow(folderName: String?) -> FolderRow {
        FolderRow(
            label: folderName.map { BookExportWording.destination(folderName: $0) } ?? BookExportWording.chooseFolderTitle,
            hint: BookExportWording.chooseFolderHint
        )
    }
}
