import Foundation

// MARK: Historique des statuts

/// Ligne de `user_book_events`, écrite par trigger à chaque insertion, changement de statut ou
/// suppression d'un `user_books`. Sert aux bilans d'entrées et de sorties de la PAL.
struct UserBookEvent: Codable, Identifiable, Hashable, Sendable {
  let id: Int64
  let userId: UUID
  var userBookId: UUID?
  let bookId: UUID
  /// `nil` à l'insertion.
  var fromStatus: ReadingStatus?
  /// `nil` à la suppression.
  var toStatus: ReadingStatus?
  /// `timestamptz` renvoyé par Postgres.
  var occurredAt: String

  enum CodingKeys: String, CodingKey {
    case id
    case userId = "user_id"
    case userBookId = "user_book_id"
    case bookId = "book_id"
    case fromStatus = "from_status"
    case toStatus = "to_status"
    case occurredAt = "occurred_at"
  }

  var date: Date? { PostgresDate.parse(occurredAt) }

  /// Entrée en PAL : un passage vers `to_read`, insertion comprise.
  var isPALEntry: Bool { toStatus == .toRead && fromStatus != .toRead }
  /// Sortie de PAL : un passage de `to_read` vers un autre statut, ou la suppression d'une ligne `to_read`.
  var isPALExit: Bool { fromStatus == .toRead && toStatus != .toRead }
}

/// Bilan de la PAL sur une période : entrées, sorties et solde.
struct PALBalance: Equatable, Sendable {
  var entries = 0
  var exits = 0

  /// Variation de la taille de la PAL : négative quand elle baisse.
  var net: Int { entries - exits }
  var isEmpty: Bool { entries == 0 && exits == 0 }

  /// « +2 · −5 · −3 » : entrées, sorties, solde (signe moins typographique).
  var compactLabel: String {
    "+\(entries) · \(Self.signed(-exits)) · \(Self.signed(net))"
  }

  var accessibilityLabel: String {
    "\(entries) entrée\(entries > 1 ? "s" : ""), \(exits) sortie\(exits > 1 ? "s" : ""), solde \(Self.signed(net))"
  }

  /// `+3`, `−3` ou `0`.
  static func signed(_ value: Int) -> String {
    if value > 0 { return "+\(value)" }
    if value < 0 { return "\u{2212}\(-value)" }
    return "0"
  }
}

enum PALLedger {
  /// Bilan des événements dont l'instant tombe dans le mois de `date`, mois compté dans le fuseau
  /// de `calendar` (celui de l'utilisateur, jamais l'UTC).
  static func balance(of events: [UserBookEvent], inMonthOf date: Date, calendar: Calendar = PostgresDate.localCalendar) -> PALBalance {
    guard let month = calendar.dateInterval(of: .month, for: date) else { return PALBalance() }
    var balance = PALBalance()
    for event in events {
      guard let occurred = event.date, month.contains(occurred), occurred < month.end else { continue }
      if event.isPALEntry { balance.entries += 1 }
      if event.isPALExit { balance.exits += 1 }
    }
    return balance
  }

  /// Début du mois de `date` dans le fuseau de `calendar`.
  static func monthStart(of date: Date, calendar: Calendar = PostgresDate.localCalendar) -> Date {
    calendar.dateInterval(of: .month, for: date)?.start ?? date
  }
}

// MARK: Objectif

/// Objectif PAL du profil. Progression = (taille de départ − taille actuelle) / (départ − cible), bornée à [0, 1].
struct PALGoal: Equatable, Sendable {
  var target: Int
  /// Échéance facultative, jour `yyyy-MM-dd`.
  var deadline: String?
  /// Taille de la PAL quand l'objectif a été fixé (posée par trigger).
  var startSize: Int?

  func progress(currentSize: Int) -> Double {
    if currentSize <= target { return 1 }
    guard let startSize, startSize > target else { return 0 }
    return min(max(Double(startSize - currentSize) / Double(startSize - target), 0), 1)
  }

  /// Livres encore à sortir de la PAL pour atteindre l'objectif.
  func remaining(currentSize: Int) -> Int { max(currentSize - target, 0) }

  func isReached(currentSize: Int) -> Bool { currentSize <= target }
}

// MARK: Ancienneté et ordres de la PAL

enum PALAge {
  /// « depuis aujourd'hui », « depuis 3 jours », « depuis 2 semaines », « depuis 5 mois », « depuis 2 ans ».
  static func label(since start: Date, now: Date = .now, calendar: Calendar = PostgresDate.localCalendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now))
    let years = c.year ?? 0, months = c.month ?? 0, days = max(c.day ?? 0, 0)
    if years > 0 { return "depuis \(years) an\(years > 1 ? "s" : "")" }
    if months > 0 { return "depuis \(months) mois" }
    if days >= 14 { return "depuis \(days / 7) semaines" }
    if days >= 7 { return "depuis 1 semaine" }
    if days >= 2 { return "depuis \(days) jours" }
    if days == 1 { return "depuis hier" }
    return "depuis aujourd'hui"
  }
}

/// Ordre des livres de la PAL : pour le tri de la bibliothèque et pour la pioche.
enum PALOrder: String, CaseIterable, Identifiable, Sendable {
  /// Le plus ancien dans la PAL d'abord.
  case oldest
  /// Le plus court d'abord ; les livres sans nombre de pages à la fin.
  case shortest

  var id: String { rawValue }

  func sorted(_ items: [UserBook]) -> [UserBook] {
    items.sorted { a, b in
      switch self {
      case .oldest:
        return Self.isOlder(a, b)
      case .shortest:
        switch (a.book?.pageCount, b.book?.pageCount) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return Self.isOlder(a, b)
        }
      }
    }
  }

  private static func isOlder(_ a: UserBook, _ b: UserBook) -> Bool {
    switch (a.palSince, b.palSince) {
    case let (x?, y?) where x != y: return x < y
    case (.some, nil): return true
    case (nil, .some): return false
    default: return (a.book?.title ?? "") < (b.book?.title ?? "")
    }
  }
}

/// Mode de la pioche « Piocher dans ma PAL ».
enum PALDrawMode: String, CaseIterable, Identifiable, Sendable {
  case random, oldest, shortest

  var id: String { rawValue }

  var label: String {
    switch self {
    case .random: "Au hasard"
    case .oldest: "Le plus ancien"
    case .shortest: "Le plus court"
    }
  }

  /// Ordre de passage des suggestions ; « Autre » passe à la suivante.
  func order(_ items: [UserBook], shuffle: ([UserBook]) -> [UserBook] = { $0.shuffled() }) -> [UserBook] {
    switch self {
    case .random: shuffle(items)
    case .oldest: PALOrder.oldest.sorted(items)
    case .shortest: PALOrder.shortest.sorted(items)
    }
  }
}
