import Foundation

// MARK: - Destinations

/// Where the text of a group goes (FMT47). A group's destination is set by
/// its first control word (or, after `\*`, the word that follows); a group
/// inside another keeps its parent's.
enum RTFDestination: Equatable {
    /// The body of the document: text becomes paragraphs.
    case body
    /// Read by nobody: pictures, objects, headers, footers, footnote
    /// separators, field instructions, and every `\*` destination not known here.
    case skipped
    /// A picture or file that Cocoa's writer attaches to the text
    /// (`\NeXTGraphic`, `\NeXTPlainFile`): read by nobody, and followed in
    /// the text around it by one character that stands for it.
    case attachment
    /// A drawing shape (`\shp`, `\shpgrp`, `\do`), whose properties and
    /// pictures are read by nobody, and whose text box (`\shptxt`) is the
    /// body of the document set in a frame, so it is read.
    case shape
    /// The font table, read for its fonts' character sets.
    case fontTable
    /// The style sheet, whose groups are style definitions.
    case styleSheet
    /// One style definition inside the style sheet.
    case styleEntry
    /// The `\info` group, whose `\title` and `\author` are read.
    case info
    /// The document's `\title`.
    case title
    /// The document's `\author`.
    case author
    /// The list table and the list override table.
    case listTable
    /// The number or bullet a list item shows (`\listtext`, `\pntext`),
    /// read only to learn which kind of list it is, and never read aloud.
    case listText
    /// The text of a shape's text box (`\shptxt`, `\dptxbxtext`): the body of the
    /// document set in a frame, read right after the paragraph that holds the
    /// shape's anchor.
    case box
    /// A footnote or an endnote (`\footnote`, with `\ftnalt` for an
    /// endnote): its text is read after the main text, in the order the file
    /// keeps the notes. Its group's text is the body of the document, set
    /// apart. (Started by the interpreter, which knows whether the note's
    /// reference is read; no name leads here.)
    case note

    /// Whether the text of the destination is read by nobody: skipped
    /// groups and attachments.
    var isUnread: Bool {
        self == .skipped || self == .attachment || self == .shape
    }

    /// Whether the text of the destination is the document's own words,
    /// set in paragraphs: the body and a note.
    var isBody: Bool {
        self == .body || self == .note || self == .box
    }

    /// The destination the control word `name` starts when it is the first
    /// word of a group (or follows `\*`), or nil for a word that is not a
    /// destination.
    static func named(_ name: String) -> RTFDestination? {
        known[name]
    }

    /// The destinations this reader knows by name. `\upr` and `\ud` are
    /// deliberately not among them: `{\upr{ANSI}{\*\ud{Unicode}}}` holds the
    /// same words twice, and the reader reads the ANSI branch (the `\upr`
    /// group takes its parent's destination) and skips the `\*\ud` branch as
    /// an unknown starred destination, as textutil's reading does.
    private static let known: [String: RTFDestination] = {
        var table: [String: RTFDestination] = [
            "rtf": .body, "field": .body, "fldrslt": .body,
            "fonttbl": .fontTable, "stylesheet": .styleSheet, "info": .info,
            "listtable": .listTable, "listoverridetable": .listTable,
            "listtext": .listText, "pntext": .listText,
            "NeXTGraphic": .attachment, "NeXTPlainFile": .attachment,
            "shp": .shape, "shpgrp": .shape, "do": .shape
        ]
        // Destinations that hold nothing a listener should hear.
        let skippedNames = [
            "colortbl", "pict", "object", "header", "headerl", "headerr", "headerf",
            "footer", "footerl", "footerr", "footerf", "fldinst",
            "annotation", "comment", "atnauthor", "atndate", "atnid", "atnref", "atntime",
            "atrfend", "atrfstart", "bkmkstart", "bkmkend", "private",
            "nonshppict", "shppict", "falt", "panose", "fontemb", "fontfile",
            "filetbl", "generator", "themedata", "colorschememapping", "datastore",
            "latentstyles", "xmlnstbl", "rsidtbl", "revtbl", "protusertbl", "userprops",
            "pgdsctbl", "template", "tc", "tcn", "xe", "txe", "rxe", "ftnsep", "ftnsepc",
            "ftncn", "aftnsep", "aftnsepc", "aftncn", "pn", "pntxta", "pntxtb",
            "nesttableprops", "nonesttables", "wgrffmtfilter", "mmathPr", "mathPr",
            "listpicture", "stylerestrictions", "sp", "shpinst"
        ]
        for name in skippedNames { table[name] = .skipped }
        return table
    }()
}

// MARK: - Paragraph and Character State

/// The paragraph properties in force, which `\pard` resets and a group's end
/// restores.
struct RTFParagraphProperties: Equatable {
    /// The paragraph style, `\sN`.
    var style: Int?
    /// The paragraph's own `\outlinelevelN`, which wins over its style's.
    var outlineLevel: Int?
    /// The list override the paragraph is in, `\lsN`.
    var listOverride: Int?
    /// The paragraph's level in its list, `\ilvlN`.
    var listLevel = 0
    /// Whether the paragraph is in a table, `\intbl` or `\itapN`.
    var inTable = false
}

/// Everything a group inherits from the group around it and gives back when
/// it ends (FMT47): the destination, the character formatting, and the
/// paragraph properties.
struct RTFGroupState: Equatable {
    /// Where the group's text goes.
    var destination = RTFDestination.body
    /// Bold, `\b`.
    var isBold = false
    /// Italic, `\i`.
    var isItalic = false
    /// Hidden text, `\v`, which is not read.
    var isHidden = false
    /// Text a tracked change deleted or moved away, `\deleted` and `\mvf`,
    /// which is not read (text a change inserted, `\revised`, is, and moved
    /// text is read where it was moved to, `\mvt`). Microsoft's table lists
    /// `\deleted` with the character formatting properties, so `\plain`
    /// brings the text back, as the group that set it ending, or `\deleted0`,
    /// does.
    var isDeleted = false
    /// The font size in half points, `\fsN`; 24 (12 points) until set.
    var fontSize = RTFGroupState.defaultFontSize
    /// The font in force, `\fN`; nil until one is set, when the default
    /// font (`\deffN`) applies.
    var font: Int?
    /// How many characters follow each `\uN` as its fallback, `\ucN`.
    var unicodeSkip = 1
    /// The paragraph properties.
    var paragraph = RTFParagraphProperties()

    /// The font size `\plain` and a new document use: 12 points.
    static let defaultFontSize = 24

    /// Whether the text now is read by nobody: hidden by `\v`, or deleted
    /// by a tracked change. One place for the rule, so that the words, the
    /// line breaks, the page and section breaks, and the notes referred to
    /// all follow it. (A paragraph mark is not read in any case.)
    var isUnreadRun: Bool { isHidden || isDeleted }

    /// `\plain`: the character formatting back to its defaults. (The
    /// paragraph's properties and the destination are not character
    /// formatting.)
    mutating func resetCharacterFormatting() {
        isBold = false
        isItalic = false
        isHidden = false
        isDeleted = false
        fontSize = Self.defaultFontSize
        font = nil
    }
}
