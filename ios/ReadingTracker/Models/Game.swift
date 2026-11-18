import Foundation

// Moteur de la gamification (voir « Gamification » dans `docs/CONTRAT.md`) : places dans la PAL, mois au
// vert, série et badges, calculés à partir de l'historique `user_book_events`, dans le fuseau local.
// Code pur, sans dépendance à l'interface ni au réseau.

// MARK: Catalogue des badges

/// Badges du catalogue. `rawValue` = `badge_id` stable de `user_badges`.
enum Badge: String, CaseIterable, Identifiable, Codable, Sendable {
  case firstExit = "first_exit"
  case bottomOfPile = "bottom_of_pile"
  case archaeologist
  case bigCleanup = "big_cleanup"
  case brick
  case greenMonth = "green_month"
  case greenStreak3 = "green_streak_3"
  case halfPile = "half_pile"
  case goalReached = "goal_reached"
  case tenOut = "ten_out"
  case pickAccepted = "pick_accepted"

  var id: String { rawValue }

  var name: String {
    switch self {
    case .firstExit: "Premier pas"
    case .bottomOfPile: "Fond de pile"
    case .archaeologist: "Archéologue"
    case .bigCleanup: "Grand ménage"
    case .brick: "Pavé"
    case .greenMonth: "Mois au vert"
    case .greenStreak3: "Trois à la suite"
    case .halfPile: "Moitié moins"
    case .goalReached: "Objectif atteint"
    case .tenOut: "Dix de moins"
    case .pickAccepted: "Coup de dé"
    }
  }

  /// Règle en une ligne, affichée sous un badge à obtenir.
  var rule: String {
    switch self {
    case .firstExit: "Sortir un premier livre de ta PAL"
    case .bottomOfPile: "Commencer le livre le plus ancien de ta PAL"
    case .archaeologist: "Sortir un livre resté plus de 2 ans dans ta PAL"
    case .bigCleanup: "Libérer 5 livres dans le même mois"
    case .brick: "Finir un livre de plus de 600 pages"
    case .greenMonth: "Un mois avec plus de sorties que d'entrées"
    case .greenStreak3: "Enchaîner 3 mois au vert"
    case .halfPile: "Diviser par deux ta PAL de départ"
    case .goalReached: "Atteindre ton objectif PAL"
    case .tenOut: "Sortir 10 livres de ta PAL"
    case .pickAccepted: "Commencer sous 7 jours un livre pioché"
    }
  }

  var systemImage: String {
    switch self {
    case .firstExit: "figure.walk"
    case .bottomOfPile: "arrow.down.to.line"
    case .archaeologist: "fossil.shell.fill"
    case .bigCleanup: "bird.fill"
    case .brick: "scalemass.fill"
    case .greenMonth: "leaf.fill"
    case .greenStreak3: "flame.fill"
    case .halfPile: "circle.lefthalf.filled"
    case .goalReached: "target"
    case .tenOut: "10.circle.fill"
    case .pickAccepted: "dice.fill"
    }
  }
}

// MARK: Places dans la PAL

/// Places dans la PAL, en nombres entiers : deux sorties libèrent une place, une entrée en occupe une.
/// Places = ⌊sorties ÷ 2⌋ − entrées, depuis le démarrage du défi.
struct PALPlaces: Equatable, Sendable {
  /// Sorties de PAL comptées depuis le démarrage du défi.
  var exits = 0
  /// Entrées en PAL comptées depuis le démarrage du défi.
  var entries = 0

  /// Places libres ; négatif quand la PAL déborde.
  var free: Int { exits / 2 - entries }
  var isOverflowing: Bool { free < 0 }
  /// Nombre impair de sorties : la prochaine sortie libère une place.
  var isOneExitAway: Bool { exits % 2 == 1 }

  /// Texte principal de la carte PAL : « 2 places libres », « Aucune place libre », « PAL en débord de 3 ».
  var label: String {
    if free < 0 { return "PAL en débord de \(-free)" }
    if free == 0 { return "Aucune place libre" }
    return "\(free) place\(free > 1 ? "s" : "") libre\(free > 1 ? "s" : "")"
  }

  /// Précision sous le texte principal, quand le nombre de sorties est impair.
  var nextPlaceHint: String? { isOneExitAway ? "encore 1 sortie pour la prochaine place" : nil }

  /// Rappel au moment d'ajouter un livre en PAL : « Il te reste 2 places », « Aucune place libre »,
  /// « Ta PAL déborde déjà de 1 ».
  var addReminder: String {
    if free < 0 { return "Ta PAL déborde déjà de \(-free)" }
    if free == 0 { return "Aucune place libre" }
    return "Il te reste \(free) place\(free > 1 ? "s" : "")"
  }
}

// MARK: Entrées et sorties du moteur

/// Suggestion de « Piocher dans ma PAL », mémorisée localement pour le badge `pick_accepted`.
struct PickSuggestion: Codable, Equatable, Sendable {
  var userBookId: UUID
  var suggestedAt: Date
}

/// Badge obtenu d'après le calcul : quand, et grâce à quel livre s'il y en a un.
struct BadgeAward: Equatable, Sendable {
  var badge: Badge
  var earnedAt: Date
  var userBookId: UUID?
}

/// Mois civil, dans le fuseau du calendrier qui l'a calculé.
struct MonthKey: Hashable, Comparable, Sendable {
  var year: Int
  var month: Int

  init(year: Int, month: Int) {
    self.year = year
    self.month = month
  }

  init(_ date: Date, calendar: Calendar) {
    let c = calendar.dateComponents([.year, .month], from: date)
    year = c.year ?? 0
    month = c.month ?? 0
  }

  var previous: MonthKey { month == 1 ? MonthKey(year: year - 1, month: 12) : MonthKey(year: year, month: month - 1) }

  static func < (a: MonthKey, b: MonthKey) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

/// Entrées et sorties comptées d'un mois (paires neutralisées exclues).
struct MonthTally: Equatable, Sendable {
  var entries = 0
  var exits = 0
  var isGreen: Bool { exits > entries }
}

/// Tout ce que le jeu affiche, à un instant donné.
struct GameState: Equatable, Sendable {
  /// Le défi est démarré (`gamification_started_at` posé) ; sinon rien ne compte et tout reste à zéro.
  var isStarted = false
  var places = PALPlaces()
  /// Entrées et sorties comptées, par mois.
  var months: [MonthKey: MonthTally] = [:]
  /// Mois au vert consécutifs jusqu'au mois précédent, plus le mois en cours s'il est déjà au vert.
  var streak = 0
  /// Badges obtenus d'après les règles, dans l'ordre du catalogue.
  var awards: [BadgeAward] = []
  /// Livres libérés ce mois-ci (progression de `big_cleanup`).
  var releasedThisMonth = 0

  var greenMonths: Set<MonthKey> { Set(months.filter { $0.value.isGreen }.keys) }

  func award(_ badge: Badge) -> BadgeAward? { awards.first { $0.badge == badge } }
}

// MARK: Moteur

enum GameEngine {
  /// Paire neutralisée : une entrée en PAL suivie d'une sortie du même livre en moins de 24 h.
  static let neutralizedPairWindow: TimeInterval = 24 * 3600
  static let pickWindowDays = 7
  static let brickPages = 600
  static let archaeologistYears = 2
  static let bigCleanupCount = 5
  static let tenOutCount = 10

  /// Calcule le jeu.
  /// - Parameters:
  ///   - events: historique du compte, le plus complet possible : les entrées antérieures au démarrage du défi
  ///     ne comptent pas, mais donnent l'ancienneté d'un livre dans la PAL ;
  ///   - library: bibliothèque actuelle (taille de la PAL, nombre de pages) ;
  ///   - goal: objectif PAL ;
  ///   - startedAt: `profiles.gamification_started_at` ; `nil` tant que le défi n'est pas démarré, et alors
  ///     rien ne compte : ni places, ni mois au vert, ni badges ;
  ///   - picks: suggestions de la pioche mémorisées localement.
  static func compute(
    events: [UserBookEvent], library: [UserBook], goal: PALGoal?, startedAt: Date?, picks: [PickSuggestion] = [],
    now: Date = .now, calendar: Calendar = PostgresDate.localCalendar
  ) -> GameState {
    guard let startedAt else { return GameState() }
    var state = GameState(isStarted: true)

    let timeline = chronological(events)
    let neutralized = neutralizedIndices(timeline.map { $0.event }, dates: timeline.map { $0.date })
    let pages = Dictionary(
      library.compactMap { item in item.book?.pageCount.map { (item.bookId, $0) } }, uniquingKeysWith: max
    )

    var awards: [Badge: BadgeAward] = [:]
    func grant(_ badge: Badge, at date: Date, book: UUID?) {
      if awards[badge] == nil { awards[badge] = BadgeAward(badge: badge, earnedAt: date, userBookId: book) }
    }

    // PAL reconstituée au fil de l'historique : livre → instant de son entrée.
    var pile: [ItemKey: Date] = [:]
    var releasedByMonth: [MonthKey: Set<ItemKey>] = [:]
    /// Dernier instant où chaque mois est passé au vert.
    var turnedGreenAt: [MonthKey: Date] = [:]

    for (index, entry) in timeline.enumerated() {
      let event = entry.event, date = entry.date
      let key = ItemKey(event)
      let enteredAt = pile[key]
      if event.isPALEntry { pile[key] = date }
      if event.isPALExit { pile[key] = nil }

      guard date >= startedAt, date <= now, !neutralized.contains(index) else { continue }
      let month = MonthKey(date, calendar: calendar)

      if event.isPALEntry {
        state.places.entries += 1
        state.months[month, default: MonthTally()].entries += 1
      }

      if event.isPALExit {
        state.places.exits += 1
        let wasGreen = state.months[month]?.isGreen == true
        state.months[month, default: MonthTally()].exits += 1
        if !wasGreen, state.months[month]?.isGreen == true { turnedGreenAt[month] = date }

        grant(.firstExit, at: date, book: event.userBookId)
        if state.places.exits >= tenOutCount { grant(.tenOut, at: date, book: event.userBookId) }

        if let enteredAt, let limit = calendar.date(byAdding: .year, value: archaeologistYears, to: enteredAt),
           date > limit {
          grant(.archaeologist, at: date, book: event.userBookId)
        }

        // Le plus ancien de la PAL à cet instant : aucun livre restant n'y est entré avant lui.
        if event.toStatus == .reading || event.toStatus == .read, let enteredAt,
           !pile.values.contains(where: { $0 < enteredAt }) {
          grant(.bottomOfPile, at: date, book: event.userBookId)
        }

        if event.toStatus == .released {
          releasedByMonth[month, default: []].insert(key)
          if releasedByMonth[month, default: []].count >= bigCleanupCount {
            grant(.bigCleanup, at: date, book: event.userBookId)
          }
        }
      }

      // Finir un livre : tout passage à `read`, y compris l'ajout d'un livre comme lu (règle du contrat).
      if event.toStatus == .read, event.fromStatus != .read, (pages[event.bookId] ?? 0) > brickPages {
        grant(.brick, at: date, book: event.userBookId)
      }

      if event.toStatus == .reading, let id = event.userBookId,
         picks.contains(where: { pick in
           let limit = calendar.date(byAdding: .day, value: pickWindowDays, to: pick.suggestedAt) ?? .distantFuture
           return pick.userBookId == id && pick.suggestedAt <= date && date <= limit
         }) {
        grant(.pickAccepted, at: date, book: id)
      }
    }

    let currentMonth = MonthKey(now, calendar: calendar)
    let green = state.greenMonths
    state.streak = streak(green: green, current: currentMonth)

    // Mois au vert d'après leur bilan final (celui du mois en cours s'il est déjà au vert).
    for month in green.sorted() {
      let at = turnedGreenAt[month] ?? now
      grant(.greenMonth, at: at, book: nil)
      if green.contains(month.previous), green.contains(month.previous.previous) {
        grant(.greenStreak3, at: at, book: nil)
      }
    }
    state.releasedThisMonth = releasedByMonth[currentMonth]?.count ?? 0

    // Badges d'état : taille actuelle de la PAL face à l'objectif.
    let size = library.filter { $0.status == .toRead }.count
    if let goal {
      if let start = goal.startSize, start >= 4, size * 2 <= start { grant(.halfPile, at: now, book: nil) }
      if goal.isReached(currentSize: size) { grant(.goalReached, at: now, book: nil) }
    }

    state.awards = Badge.allCases.compactMap { awards[$0] }
    return state
  }

  typealias TimedEvent = (event: UserBookEvent, date: Date)

  /// Événements datés, du plus ancien au plus récent (à instant égal, par id).
  static func chronological(_ events: [UserBookEvent]) -> [TimedEvent] {
    var timed: [TimedEvent] = []
    for event in events {
      if let date = event.date { timed.append((event: event, date: date)) }
    }
    timed.sort { a, b in a.date == b.date ? a.event.id < b.event.id : a.date < b.date }
    return timed
  }

  /// Série courante : mois au vert consécutifs jusqu'au mois précédent, plus le mois en cours s'il est au vert.
  static func streak(green: Set<MonthKey>, current: MonthKey) -> Int {
    var month = green.contains(current) ? current : current.previous
    var count = 0
    while green.contains(month) {
      count += 1
      month = month.previous
    }
    return count
  }

  /// Indices (dans l'ordre chronologique) des événements des paires neutralisées : une entrée en PAL suivie
  /// d'une sortie du même livre en moins de 24 h ne compte ni comme entrée ni comme sortie.
  static func neutralizedIndices(_ events: [UserBookEvent], dates: [Date]) -> Set<Int> {
    var openEntry: [ItemKey: Int] = [:]
    var result: Set<Int> = []
    for (index, event) in events.enumerated() {
      let key = ItemKey(event)
      if event.isPALExit, let entry = openEntry.removeValue(forKey: key),
         dates[index].timeIntervalSince(dates[entry]) < neutralizedPairWindow {
        result.insert(entry)
        result.insert(index)
      }
      if event.isPALEntry { openEntry[key] = index }
    }
    return result
  }

  /// Un livre de la bibliothèque : sa ligne `user_books`, ou sa fiche si la ligne a été supprimée
  /// (`user_book_id` passe alors à `null` sur tous ses événements).
  struct ItemKey: Hashable {
    let id: UUID
    /// `id` est celui de la ligne `user_books` (sinon celui de la fiche `books`).
    let isUserBookRow: Bool

    init(_ event: UserBookEvent) {
      if let row = event.userBookId {
        id = row
        isUserBookRow = true
      } else {
        id = event.bookId
        isUserBookRow = false
      }
    }
  }
}

// MARK: Progression vers un badge

extension GameState {
  /// Où l'on en est d'un badge à obtenir, en une phrase, quand c'est mesurable. Rien n'est dit d'une
  /// série perdue : le jeu ne punit pas.
  func progress(toward badge: Badge, palSize: Int, goal: PALGoal?, now: Date = .now,
                calendar: Calendar = PostgresDate.localCalendar) -> String? {
    guard isStarted else { return nil }
    switch badge {
    case .tenOut:
      let count = min(places.exits, GameEngine.tenOutCount)
      return "\(count) sortie\(count > 1 ? "s" : "") sur \(GameEngine.tenOutCount)"
    case .bigCleanup:
      let count = min(releasedThisMonth, GameEngine.bigCleanupCount)
      return "\(count) libéré\(count > 1 ? "s" : "") sur \(GameEngine.bigCleanupCount) ce mois-ci"
    case .greenMonth:
      let month = months[MonthKey(now, calendar: calendar)] ?? MonthTally()
      return "Ce mois-ci : \(month.exits) sortie\(month.exits > 1 ? "s" : ""), \(month.entries) entrée\(month.entries > 1 ? "s" : "")"
    case .greenStreak3:
      return streak > 0 ? "Série en cours : \(streak) mois au vert" : nil
    case .halfPile:
      guard let start = goal?.startSize, start >= 4 else { return "Avec un objectif PAL fixé sur une pile d'au moins 4 livres" }
      let left = max(palSize - start / 2, 0)
      return "Encore \(left) livre\(left > 1 ? "s" : "") à sortir"
    case .goalReached:
      guard let goal else { return "Fixe-toi un objectif PAL dans ton profil" }
      let left = goal.remaining(currentSize: palSize)
      return "Encore \(left) livre\(left > 1 ? "s" : "") à sortir"
    case .firstExit, .bottomOfPile, .archaeologist, .brick, .pickAccepted:
      return nil
    }
  }
}
