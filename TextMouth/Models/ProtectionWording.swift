import Foundation

/// The words of password-protected books (FR41): the unlock panel's labels,
/// hints, and outcomes, and the refusals. Every line is short, so a braille
/// display shows a control's name with its role, and VoiceOver speaks each
/// outcome in one sentence.
enum ProtectionWording {

    // MARK: The Panel

    /// The panel's heading: "Unlock “Title”".
    static func heading(title: String) -> String {
        // Translators: The heading of the panel that asks for a protected book's password. %@ is the book's title.
        InterfaceText.line("protection.heading", "Unlock “\(title)”")
    }

    /// The line under the heading.
    static var explanation: String {
        // Translators: Under the heading of the password panel: says the book needs a password.
        InterfaceText.line("protection.explanation", "This book is protected by a password.")
    }

    /// The password field's name.
    static var passwordLabel: String {
        // Translators: The name of the field where a book's password is typed.
        InterfaceText.line("protection.password", "Password")
    }

    /// The password field's hint.
    static var passwordHint: String {
        // Translators: Hint of the password field: what to type, and how to finish.
        InterfaceText.line("protection.passwordHint", "Type the book's password, then press Return.")
    }

    /// The checkbox that shows the typed password.
    static var showPassword: String {
        // Translators: Checkbox that shows the typed password as plain text, so it can be read back.
        InterfaceText.line("protection.show", "Show password")
    }

    /// The checkbox that remembers the password.
    static var remember: String {
        // Translators: Checkbox in the password panel: keep the password in this device's Keychain.
        InterfaceText.line("protection.remember", "Remember this password")
    }

    /// Its hint.
    static var rememberHint: String {
        // Translators: Hint of the Remember checkbox: where the password is kept and what it saves.
        InterfaceText.line("protection.rememberHint", "Keeps it in this device's Keychain, so TextMouth does not ask again for this book.")
    }

    /// The checkbox that removes the password from the book.
    static var removePassword: String {
        // Translators: Checkbox in the password panel: take the password off the book's file in the library.
        InterfaceText.line("protection.removePassword", "Remove the password from this book")
    }

    /// Its hint.
    static var removePasswordHint: String {
        // Translators: Hint of the Remove Password checkbox: what it changes and what it leaves alone.
        InterfaceText.line("protection.removePasswordHint", "Rewrites the book's file in your library without its password. Your original is never changed.")
    }

    /// The default button.
    static var unlock: String {
        // Translators: Button that opens a protected book with the typed password.
        InterfaceText.line("protection.unlock", "Unlock")
    }

    /// The button that leaves the book locked.
    static var cancel: String {
        // Translators: Button that closes the password panel and leaves the book locked.
        InterfaceText.line("protection.cancel", "Cancel")
    }

    // MARK: Adding Protected Books

    /// The heading of the panel that asks before protected books are added.
    static var importHeading: String {
        // Translators: The heading of the panel that asks for the password of books being added.
        InterfaceText.line("protection.importHeading", "Add protected books")
    }

    /// The line under that heading.
    static var importExplanation: String {
        // Translators: Under the heading of the panel shown when some books being added are protected by a password.
        InterfaceText.line("protection.importExplanation", "Some of these books are protected by a password.")
    }

    /// The button that adds the books without unlocking them.
    static var importLocked: String {
        // Translators: Button that adds protected books to the library without their password; they stay locked.
        InterfaceText.line("protection.importLocked", "Import Locked")
    }

    /// Its hint.
    static var importLockedHint: String {
        // Translators: Hint of the Import Locked button: what it does and how to unlock the books later.
        InterfaceText.line("protection.importLockedHint", "Adds the books locked. You can unlock each one when you open it.")
    }

    /// What is said when the password opened only some of the books.
    static var partlyOpened: String {
        // Translators: Said when a typed password opened some of the protected books being added but not all.
        InterfaceText.line("protection.partlyOpened", "Some books did not open with this password. Try another, or choose Import Locked.")
    }

    // MARK: Outcomes

    /// What is said once the password is off the book's file.
    static var removed: String {
        // Translators: Said after the password was taken off a book's file in the library.
        InterfaceText.line("protection.removed", "Password removed.")
    }

    /// What is said when the password could not be taken off.
    static var removeFailed: String {
        // Translators: Said when taking the password off a book's file failed; the book stays as it was and opens for now.
        InterfaceText.line("protection.removeFailed", "The password could not be removed. The book is as it was.")
    }

    /// What is said when the password could not be kept in the Keychain.
    static var rememberFailed: String {
        // Translators: Said when the Keychain would not keep a book's password; the book opens anyway.
        InterfaceText.line("protection.rememberFailed", "The password could not be kept in the Keychain. The book is open.")
    }

    /// What is said when a section of a protected book is chosen to skip.
    static var cannotSkipSections: String {
        // Translators: Said when someone tries to skip a section of a book that has a password: a skipped section is saved with its words, which a protected book never keeps. Remove the password first.
        InterfaceText.line("protection.cannotSkip", "Sections of a book with a password can't be skipped. Remove its password first.")
    }

    /// What is said while a password is being tried.
    static var unlocking: String {
        // Translators: Said while a typed password is being tried on a book.
        InterfaceText.line("protection.unlocking", "Unlocking.")
    }

    /// The hint of the Show password checkbox.
    static var showPasswordHint: String {
        // Translators: Hint of the Show password checkbox: it lets the typed password be read back.
        InterfaceText.line("protection.showHint", "Lets you read back what you typed.")
    }

    /// What a wrong password says, on screen and aloud.
    static var wrongPassword: String {
        // Translators: Said and shown when a typed password does not open the book.
        InterfaceText.line("protection.wrong", "Wrong password. Try again.")
    }

    /// What an unsupported protection says.
    static var unsupported: String {
        // Translators: Why a protected book cannot be unlocked: its kind of password protection is not one TextMouth opens.
        InterfaceText.line("protection.unsupported", "TextMouth can't open this book's kind of password protection.")
    }

    /// What a damaged file says.
    static var damaged: String {
        // Translators: Why a protected book cannot be unlocked: its file is damaged.
        InterfaceText.line("protection.damaged", "This book's file is damaged, so it can't be unlocked.")
    }

    /// What is spoken once the book has opened.
    static var unlocked: String {
        // Translators: Said after a protected book's password was accepted.
        InterfaceText.line("protection.unlocked", "Unlocked.")
    }

    /// The refusal when something needs a locked book's text.
    static var lockedRefusal: String {
        // Translators: Why a book's text could not be read: it is protected by a password and has not been unlocked.
        InterfaceText.line("protection.locked", "This book is locked. Open it and enter its password.")
    }

    // MARK: The Library

    /// The spoken word for a locked book's row.
    static var lockedState: String {
        // Translators: Spoken after a book's title in the library list: the book is protected by a password.
        InterfaceText.line("protection.lockedState", "Locked")
    }
}

/// A book that is protected and not unlocked was asked for its text: the
/// backstop of every reader of it that does not ask for the password
/// first, so none writes a copy of it or fails with a puzzling message.
struct BookLockedError: LocalizedError, LogDescribing {
    var errorDescription: String? { ProtectionWording.lockedRefusal }
    var logDescription: String { "A locked book was asked for its text." } // l10n: no (debug log)
}
