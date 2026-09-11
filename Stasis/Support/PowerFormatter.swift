import Foundation

/// Shared display policy for all power values in the menu.
///
/// Power is intentionally formatted with a fixed decimal point and one
/// fractional digit.  This keeps values stable in the compact menu and avoids
/// locale-dependent comma/period changes in the unit-bearing string.
enum PowerFormatter {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func string(_ watts: Double, includeUnit: Bool = true) -> String {
        let value = String(format: "%.1f", locale: locale, abs(watts))
        return includeUnit ? "\(value) W" : value
    }
}
