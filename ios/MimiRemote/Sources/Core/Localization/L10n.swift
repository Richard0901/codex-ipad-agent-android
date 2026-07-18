import Foundation

/// App UI strings must use a stable catalog key instead of embedding display copy in Swift.
///
/// `Bundle.localizedString` keeps dynamic keys compatible with the generated
/// `Localizable.xcstrings` bundle while allowing state-layer messages to share the same catalog.
enum L10n {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: Any...) -> String {
        formatTemplate(text(key), arguments: arguments)
    }

    /// Formatter implementation kept separate from Bundle lookup for deterministic tests.
    /// Catalog entries used by `format` are intentionally restricted to object placeholders
    /// (`%@`). Converting every argument to NSString keeps `Any` safe, including Int values.
    static func formatTemplate(_ template: String, arguments: [Any]) -> String {
        let cVarArgs: [CVarArg] = arguments.map {
            ($0 as? NSString) ?? (String(describing: $0) as NSString)
        }
        return String(format: template, locale: .autoupdatingCurrent, arguments: cVarArgs)
    }

    /// Use catalog plural variations for new count-dependent UI text.
    static func plural(_ key: String, count: Int) -> String {
        String.localizedStringWithFormat(text(key), count)
    }
}
