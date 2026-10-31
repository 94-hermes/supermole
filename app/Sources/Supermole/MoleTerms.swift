import Foundation

/// Translates the English words `mo` itself returns (overview places, health
/// ratings and issues, battery condition) through the MoleTerms table. A term
/// the table does not know is shown as `mo` wrote it.
enum MoleTerms {
    enum Context: String {
        case section
        case place
        case health
        case issue
        case battery
    }

    private static let table = "MoleTerms"

    static func localized(_ term: String, _ context: Context) -> String {
        Bundle.main.localizedString(forKey: "\(context.rawValue).\(term)", value: term, table: table)
    }
}
