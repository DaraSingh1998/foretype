import Foundation

// User-interface text. The key of every string is its English text; translations live in
// mac/Localization/<language>.lproj/Localizable.strings (plain strings and formats) and
// Localizable.stringsdict (counted nouns), which scripts/build-mac.sh copies into
// Foretype.app/Contents/Resources. Lookups go through Bundle.main, so a bare dev binary
// (mac/.build/release/Foretype, no .lproj folders next to it) gets the key back: English.
//
// Formats with more than one argument number them (%1$@, %2$@) so a translation can put
// them in any order. Numbers are formatted before they go in (NumberFormatter, the locale's
// digits and grouping), so every argument is a string (%@).

/// The translation of `key`, or `key` itself (the English text).
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// The translation of the format `key`, filled in with `args`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

/// A counted noun or sentence: "1 keystroke", "1,234 keystrokes", "Imported 12 passages".
///
/// `key` is the English plural with `%@` for the number ("%@ keystrokes"), `one` the
/// English singular; `extra` fills further `%@`s in both. The Localizable.stringsdict entry
/// for `key` receives the count (`%1$ld`, which picks the plural form) and then the
/// formatted number and `extra` as `%2$@`, `%3$@`, ..., so its forms write the number as
/// `%2$@`. Without a .stringsdict (the bare dev binary) the English forms are used.
func LCount(_ n: Int, _ key: String, one: String, _ extra: CVarArg...) -> String {
    let number = formatNumber(n)
    let format = L(key)
    if format == key {
        return String(format: n == 1 ? one : key, locale: Locale.current, arguments: [number as CVarArg] + extra)
    }
    return String(format: format, locale: Locale.current, arguments: [n as CVarArg, number as CVarArg] + extra)
}

/// "1,234" (the locale's digits and grouping).
func formatNumber(_ n: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
}

/// "45%" for 0.45, in the locale's style.
func formatPercent(_ fraction: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .percent
    f.maximumFractionDigits = 0
    return f.string(from: NSNumber(value: fraction)) ?? String(format: "%.0f%%", fraction * 100)
}
