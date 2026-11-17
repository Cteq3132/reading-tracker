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

  static func parse(_ string: String?) -> Date? {
    guard var s = string, !s.isEmpty else { return nil }
    if s.count == 10 { return date(fromDay: s) }
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

  // MARK: Colonnes `date` (jour calendaire, sans heure ni fuseau)

  /// Jour calendaire de `date` dans le fuseau de `calendar`, au format Postgres `yyyy-MM-dd`.
  /// Lit les composants du calendrier local au lieu de formater en UTC : une lecture commencée
  /// à 23 h à Paris reste datée du jour même, et non du lendemain.
  static func day(from date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  /// Jour calendaire d'aujourd'hui, dans le fuseau local.
  static func today(calendar: Calendar = .current) -> String {
    day(from: .now, calendar: calendar)
  }

  /// Date à midi, heure locale, du jour `yyyy-MM-dd` : midi évite les jours où minuit n'existe
  /// pas (changement d'heure) et reste dans le bon jour quel que soit le fuseau.
  static func date(fromDay day: String, calendar: Calendar = .current) -> Date? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard day.count == 10, parts.count == 3 else { return nil }
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
    guard let date = calendar.date(from: components),
          calendar.component(.day, from: date) == parts[2] else { return nil }
    return date
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
