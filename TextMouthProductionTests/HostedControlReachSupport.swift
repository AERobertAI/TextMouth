import AppKit
import XCTest

// Whether a hosted page's controls can be reached, as the Settings window's
// fit tests (`SettingsTabFitTests`) and the view editor sheet's
// (`LibraryViewEditorTests`) measure it: one copy of the rules, moved here
// from `SettingsTabFitTests` on October 31, 2026.

extension XCTestCase {
    /// The AppKit controls SwiftUI drew in `page` that a person could use:
    /// shown, with a size, and not a scroll bar.
    @MainActor
    func visibleControls(in page: NSView) -> [NSControl] {
        descendants(of: page, as: NSControl.self).filter {
            !($0 is NSScroller) && !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 && $0.frame.height > 0
        }
    }

    /// Whether `view` lies where `page` shows it: within its nearest scroll
    /// view's reach, that scroll view lying where `page` shows it, or, with
    /// no scroll view around it, within `page`. A scroll view reaches the
    /// whole height of its document, but only its own width of it unless it
    /// scrolls sideways. Half a point is allowed for rounding.
    @MainActor
    func isReachable(_ view: NSView, in page: NSView) -> Bool {
        let rounding: CGFloat = 0.5
        guard let scrollView = view.enclosingScrollView, scrollView.isDescendant(of: page),
              let document = scrollView.documentView else {
            return page.bounds.insetBy(dx: -rounding, dy: -rounding).contains(view.convert(view.bounds, to: page))
        }
        guard view !== document else { return isReachable(scrollView, in: page) }
        let visible = scrollView.documentVisibleRect
        let reach = NSRect(
            x: scrollView.hasHorizontalScroller ? document.bounds.minX : visible.minX,
            y: document.bounds.minY,
            width: scrollView.hasHorizontalScroller ? document.bounds.width : visible.width,
            height: document.bounds.height
        )
        return reach.insetBy(dx: -rounding, dy: -rounding).contains(view.convert(view.bounds, to: document))
            && isReachable(scrollView, in: page)
    }

    /// `control` as a failure names it: its kind, its label, and where it
    /// lies in `page`.
    @MainActor
    func describe(_ control: NSControl, in page: NSView) -> String {
        "\(type(of: control)) '\(control.accessibilityLabel() ?? "")' at \(control.convert(control.bounds, to: page))"
    }
}
