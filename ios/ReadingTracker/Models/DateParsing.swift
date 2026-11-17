import Foundation

/// Postgres renvoie les `timestamptz` avec des microsecondes (« 2026-11-17T10:00:00.123456+00:00 »)
/// et les `date` sous la forme « 2026-11-17 ». On les garde en `String` dans les modèles et on
/// les convertit ici, à l'affichage.
enum PostgresDate {
  private static let withFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let plain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  private static let dayOnly: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f
  }()

  static func parse(_ string: String?) -> Date? {
    guard var s = string, !s.isEmpty else { return nil }
    if s.count == 10 { return dayOnly.date(from: s) }
    s = s.replacingOccurrences(of: " ", with: "T")
    // Ramène les fractions de seconde à 3 chiffres, seul format accepté par ISO8601DateFormatter.
    if let dot = s.firstIndex(of: ".") {
      let afterDot = s[s.index(after: dot)...]
      let digits = afterDot.prefix { $0.isNumber }
      let rest = afterDot.dropFirst(digits.count)
      let millis = String((digits + "000").prefix(3))
      s = String(s[..<dot]) + "." + millis + rest
    }
    return withFraction.date(from: s) ?? plain.date(from: s)
  }

  static func relative(_ string: String?) -> String? {
    guard let date = parse(string) else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "fr_FR")
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: .now)
  }

  static func long(_ string: String?) -> String? {
    guard let date = parse(string) else { return nil }
    return date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR")))
  }
}
