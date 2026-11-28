import Foundation

// Formatters for what the interface shows and speaks (FR39): they write a number or a date in the interface language's
// locale (`InterfaceLanguage.current.locale`), not the system's. After a live switch of language, `Locale.current` still holds
// the launch's language, so a figure written with it would keep the old grouping and digits; these follow the switch.

extension BinaryInteger {
    /// This integer as the interface language writes it: "1,234" in English, "1.234" in German.
    func interfaceFormatted() -> String {
        formatted(IntegerFormatStyle<Self>().locale(InterfaceLanguage.current.locale))
    }
}

extension Date {
    /// This date, and time of day when `time` asks for one, as the interface language writes them, in the system's time
    /// zone and calendar: what `formatted(date:time:)` gives, in the interface language's locale.
    func interfaceFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(InterfaceLanguage.current.locale))
    }
}
