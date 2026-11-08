import Foundation

/// When the Speech Stopped sheet shows over the phone's reader. A screen
/// presents one sheet or alert at a time, so the report waits while a panel
/// sheet, the error alert, or another alert is over the reader, and shows as
/// the last of them closes, as the Mac's presenter does
/// (`SpeechRefusalReportPresenter.showsReport`).
enum PhoneSpeechRefusalPresentation {
    /// Whether the report shows now.
    /// - Parameters:
    ///   - hasReport: The reader keeps a report of a refusal.
    ///   - panelSheetShows: One of the reader's panel sheets is open.
    ///   - errorAlertShows: The reader's error alert is showing.
    ///   - otherAlertShows: Another alert is showing, such as the question
    ///     about removing a bookmark with a note.
    static func shows(hasReport: Bool, panelSheetShows: Bool, errorAlertShows: Bool, otherAlertShows: Bool) -> Bool {
        hasReport && !panelSheetShows && !errorAlertShows && !otherAlertShows
    }
}
