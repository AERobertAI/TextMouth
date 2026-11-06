import Foundation

/// What a KFX style says that matters to a listener (KFX-FORMAT-NOTES-2026-11-05.md,
/// part 6.2): whether text in it is bold or italic, and whether it marks a
/// heading. Size, colour, and underline are not spoken and are not read.
struct KFXStyle: Equatable {
    var isBold = false
    var isItalic = false
    /// The style's layout hints include "heading".
    var marksHeading = false

    /// The style that a struct of properties describes (a style fragment,
    /// or a run or node that sets properties of its own).
    init(properties: IonStruct?) {
        guard let properties else { return }
        if let weight = properties[KFXSymbol.fontWeight]?.symbolID {
            isBold = KFXSymbol.boldWeights.contains(weight)
        }
        if let slant = properties[KFXSymbol.fontStyle]?.symbolID {
            isItalic = KFXSymbol.italicStyles.contains(slant)
        }
        marksHeading = properties[KFXSymbol.layoutHints]?.listValue?
            .contains { $0.symbolID == KFXSymbol.headingHint } ?? false
    }

    /// This style with the properties `other` sets over it: bold or italic
    /// if either is.
    func adding(_ other: KFXStyle) -> KFXStyle {
        var merged = self
        merged.isBold = isBold || other.isBold
        merged.isItalic = isItalic || other.isItalic
        merged.marksHeading = marksHeading || other.marksHeading
        return merged
    }
}

/// The book's styles, by name, read once.
struct KFXStyles {
    private var styles: [String: KFXStyle] = [:]

    /// Reads every style fragment of `fragments`.
    init(_ fragments: KFXFragments) {
        for (name, value) in fragments.all(KFXSymbol.style) {
            styles[name] = KFXStyle(properties: value.structValue)
        }
    }

    /// The style a node or run names (by `$157`), plus any property the node
    /// or run sets directly. A name the book has no style for is a plain style.
    func style(of properties: IonStruct) -> KFXStyle {
        var style = KFXStyle(properties: properties)
        if let name = properties[KFXSymbol.styleName]?.stringValue, let named = styles[name] {
            style = named.adding(style)
        }
        return style
    }
}
