import Foundation
import Testing
@testable import ReadingTracker

/// Moteur de la gamification : défi démarré ou non, places dans la PAL, paires neutralisées, mois au vert,
/// série et badges, dans le fuseau local (règles de « Gamification » dans `docs/CONTRAT.md`).
struct GameTests {
  private static let paris: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
  }()

  /// Démarrage du défi : le 1er juin 2026 à 10 h UTC.
  private let start = "2026-06-01T10:00:00Z"
  private let now = "2026-11-18T12:00:00Z"

  private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

  /// Un livre de la bibliothèque, pour suivre ses passages d'un statut à l'autre.
  private struct Item {
    let row = UUID()
    let book = UUID()
  }

  private func event(_ from: ReadingStatus?, _ to: ReadingStatus?, at iso: String, deleted: Bool = false) -> UserBookEvent {
    event(Item(), from, to, at: iso, deleted: deleted)
  }

  private func event(
    _ item: Item, _ from: ReadingStatus?, _ to: ReadingStatus?, at iso: String, deleted: Bool = false
  ) -> UserBookEvent {
    UserBookEvent(
      id: Int64.random(in: 1...Int64.max), userId: UUID(), userBookId: deleted ? nil : item.row, bookId: item.book,
      fromStatus: from, toStatus: to, occurredAt: iso
    )
  }

  private func libraryItem(_ item: Item, status: ReadingStatus, pages: Int? = nil) -> UserBook {
    let book = Book(id: item.book, isbn13: nil, isbn10: nil, title: "Livre", subtitle: nil, authors: [], publisher: nil,
                    publishedDate: nil, pageCount: pages, description: nil, language: nil, coverUrl: nil,
                    source: "manual", sourceId: nil)
    return UserBook(id: item.row, userId: UUID(), book: book, status: status)
  }

  private func pile(_ count: Int) -> [UserBook] {
    (0..<count).map { _ in libraryItem(Item(), status: .toRead) }
  }

  private func compute(
    _ events: [UserBookEvent], library: [UserBook] = [], goal: PALGoal? = nil, picks: [PickSuggestion] = [],
    start: String? = nil, now: String? = nil
  ) -> GameState {
    GameEngine.compute(
      events: events, library: library, goal: goal, startedAt: instant(start ?? self.start), picks: picks,
      now: instant(now ?? self.now), calendar: Self.paris
    )
  }

  private func badges(_ state: GameState) -> Set<Badge> { Set(state.awards.map(\.badge)) }

  // MARK: Places dans la PAL

  @Test("Deux sorties libèrent une place, une entrée en occupe une, pour tous les statuts de sortie")
  func places() {
    let events = [
      event(nil, .toRead, at: "2026-07-01T10:00:00Z"),
      event(.toRead, .reading, at: "2026-07-02T10:00:00Z"),
      event(.toRead, .read, at: "2026-07-03T10:00:00Z"),
      event(.toRead, .abandoned, at: "2026-07-04T10:00:00Z"),
      event(.toRead, .released, at: "2026-07-05T10:00:00Z"),
      event(.toRead, nil, at: "2026-07-06T10:00:00Z", deleted: true),
      event(.wishlist, .toRead, at: "2026-07-07T10:00:00Z"),
      // Hors PAL : ni entrée ni sortie.
      event(.reading, .read, at: "2026-07-08T10:00:00Z"),
      event(nil, .wishlist, at: "2026-07-09T10:00:00Z"),
    ]
    let state = compute(events)
    #expect(state.isStarted)
    #expect(state.places == PALPlaces(exits: 5, entries: 2))
    // ⌊5 ÷ 2⌋ − 2 = 0.
    #expect(state.places.free == 0)
    #expect(state.places.isOneExitAway)
  }

  @Test("Sorties paires : chaque paire libère une place, sans mention de la prochaine")
  func evenExits() {
    let events = (1...4).map { day in event(.toRead, .released, at: "2026-07-0\(day)T10:00:00Z") }
    let places = compute(events).places
    #expect(places.free == 2)
    #expect(!places.isOneExitAway)
    #expect(places.label == "2 places libres")
    #expect(places.nextPlaceHint == nil)
    #expect(places.addReminder == "Il te reste 2 places")
  }

  @Test("Sorties impaires : arrondi à l'inférieur, et encore 1 sortie pour la prochaine place")
  func oddExits() {
    let events = (1...5).map { day in event(.toRead, .released, at: "2026-07-0\(day)T10:00:00Z") }
    let places = compute(events).places
    #expect(places.free == 2)
    #expect(places.isOneExitAway)
    #expect(places.label == "2 places libres")
    #expect(places.nextPlaceHint == "encore 1 sortie pour la prochaine place")
  }

  @Test("Solde négatif : PAL en débord, sans rien bloquer")
  func overflow() {
    let events = (1...4).map { day in event(nil, .toRead, at: "2026-07-0\(day)T10:00:00Z") }
      + [event(.toRead, .released, at: "2026-07-10T10:00:00Z"), event(.toRead, .read, at: "2026-07-11T10:00:00Z"),
         event(.toRead, .reading, at: "2026-07-12T10:00:00Z")]
    let places = compute(events).places
    // ⌊3 ÷ 2⌋ − 4 = −3.
    #expect(places.free == -3)
    #expect(places.isOverflowing)
    #expect(places.label == "PAL en débord de 3")
    #expect(places.nextPlaceHint == "encore 1 sortie pour la prochaine place")
    #expect(places.addReminder == "Ta PAL déborde déjà de 3")
  }

  @Test("Textes des places : nombres entiers, singulier et pluriel", arguments: [
    (0, 0, "Aucune place libre", "Aucune place libre"),
    (1, 0, "Aucune place libre", "Aucune place libre"),
    (2, 0, "1 place libre", "Il te reste 1 place"),
    (3, 0, "1 place libre", "Il te reste 1 place"),
    (4, 0, "2 places libres", "Il te reste 2 places"),
    (2, 1, "Aucune place libre", "Aucune place libre"),
    (1, 1, "PAL en débord de 1", "Ta PAL déborde déjà de 1"),
    (0, 3, "PAL en débord de 3", "Ta PAL déborde déjà de 3"),
  ])
  func placeLabels(exits: Int, entries: Int, label: String, reminder: String) {
    let places = PALPlaces(exits: exits, entries: entries)
    #expect(places.label == label)
    #expect(places.addReminder == reminder)
    #expect(places.nextPlaceHint == (exits % 2 == 1 ? "encore 1 sortie pour la prochaine place" : nil))
  }

  @Test("Aucune demi-valeur : ni « ½ », ni « jeton », ni virgule dans les textes", arguments: Array(0...9))
  func noHalves(exits: Int) {
    for entries in 0...4 {
      let places = PALPlaces(exits: exits, entries: entries)
      for text in [places.label, places.addReminder, places.nextPlaceHint ?? ""] {
        #expect(!text.contains("½"))
        #expect(!text.lowercased().contains("jeton"))
        #expect(!text.contains(","))
        #expect(!text.contains("."))
      }
    }
  }

  @Test("Les événements antérieurs au démarrage du défi ne comptent pas")
  func beforeStart() {
    let events = [
      event(nil, .toRead, at: "2026-05-01T10:00:00Z"),
      event(.toRead, .released, at: "2026-05-31T10:00:00Z"),
      event(.toRead, .reading, at: "2026-06-01T09:59:59Z"),
    ]
    let state = compute(events)
    #expect(state.places == PALPlaces())
    #expect(state.awards.isEmpty)
  }

  @Test("Plus de période d'installation : une entrée juste après le démarrage occupe une place")
  func noInstallationPeriod() {
    let state = compute([event(nil, .toRead, at: "2026-06-01T10:00:01Z")], now: "2026-06-02T10:00:00Z")
    #expect(state.places.free == -1)
    #expect(state.months[MonthKey(year: 2026, month: 6)] == MonthTally(entries: 1, exits: 0))
  }

  // MARK: Défi non démarré

  @Test("Défi non démarré : ni places, ni mois au vert, ni série, ni badges")
  func notStarted() {
    let book = Item()
    let events = [
      event(book, nil, .toRead, at: "2020-01-01T10:00:00Z"),
      event(book, .toRead, .reading, at: "2026-11-02T10:00:00Z"),
    ] + (1...9).map { day in event(.toRead, .released, at: "2026-11-0\(day)T12:00:00Z") }
    let library = [libraryItem(book, status: .read, pages: 900)] + pile(1)
    let state = GameEngine.compute(
      events: events, library: library, goal: PALGoal(target: 2, startSize: 10), startedAt: nil,
      now: instant(now), calendar: Self.paris
    )
    #expect(!state.isStarted)
    #expect(state == GameState())
    #expect(state.places.free == 0)
    #expect(state.months.isEmpty)
    #expect(state.streak == 0)
    #expect(state.awards.isEmpty)
    #expect(state.progress(toward: .tenOut, palSize: 1, goal: nil) == nil)
  }

  // MARK: Paires neutralisées

  @Test("Paire à 23 h : l'entrée et la sortie ne comptent pas")
  func pairWithin24Hours() {
    let book = Item()
    let events = [
      event(book, nil, .toRead, at: "2026-07-01T10:00:00Z"),
      event(book, .toRead, .released, at: "2026-07-02T09:00:00Z"),
    ]
    let state = compute(events)
    #expect(state.places == PALPlaces())
    #expect(state.months.isEmpty)
    #expect(state.awards.isEmpty)
  }

  @Test("Paire à 25 h : l'entrée et la sortie comptent")
  func pairAfter24Hours() {
    let book = Item()
    let events = [
      event(book, nil, .toRead, at: "2026-07-01T10:00:00Z"),
      event(book, .toRead, .released, at: "2026-07-02T11:00:00Z"),
    ]
    let state = compute(events)
    #expect(state.places == PALPlaces(exits: 1, entries: 1))
    #expect(state.places.free == -1)
    #expect(badges(state).contains(.firstExit))
  }

  @Test("Paire à 24 h pile : « moins de 24 h » n'est plus vrai, elle compte")
  func pairAtExactly24Hours() {
    let book = Item()
    let state = compute([
      event(book, nil, .toRead, at: "2026-07-01T10:00:00Z"),
      event(book, .toRead, .reading, at: "2026-07-02T10:00:00Z"),
    ])
    #expect(state.places.exits == 1)
  }

  @Test("Ligne supprimée : la paire se reconnaît au book_id, user_book_id étant passé à null")
  func pairOnDeletedRow() {
    let book = Item()
    let other = Item()
    let state = compute([
      event(book, nil, .toRead, at: "2026-07-01T10:00:00Z", deleted: true),
      event(book, .toRead, nil, at: "2026-07-01T12:00:00Z", deleted: true),
      // Un autre livre supprimé ne fait pas paire avec celui-ci.
      event(other, .toRead, nil, at: "2026-07-01T13:00:00Z", deleted: true),
    ])
    #expect(state.places == PALPlaces(exits: 1, entries: 0))
  }

  @Test("Paires d'autres livres : seule la sortie du même livre neutralise l'entrée")
  func pairOtherBook() {
    let state = compute([
      event(Item(), nil, .toRead, at: "2026-07-01T10:00:00Z"),
      event(Item(), .toRead, .released, at: "2026-07-01T11:00:00Z"),
    ])
    #expect(state.places == PALPlaces(exits: 1, entries: 1))
  }

  // MARK: Mois au vert et série

  @Test("Frontière de mois dans le fuseau local : 0 h 30 le 1er novembre à Paris compte en novembre")
  func monthBoundary() {
    let events = [
      // 31 octobre 23 h 30 UTC = 1er novembre 0 h 30 à Paris.
      event(.toRead, .released, at: "2026-10-31T23:30:00Z"),
      // 31 octobre 22 h 30 UTC = 31 octobre 23 h 30 à Paris (heure d'hiver depuis le 25).
      event(nil, .toRead, at: "2026-10-31T22:30:00Z"),
    ]
    let state = compute(events)
    #expect(state.months[MonthKey(year: 2026, month: 11)] == MonthTally(entries: 0, exits: 1))
    #expect(state.months[MonthKey(year: 2026, month: 10)] == MonthTally(entries: 1, exits: 0))
    #expect(state.greenMonths == [MonthKey(year: 2026, month: 11)])
  }

  @Test("Mois au vert : plus de sorties que d'entrées ; à égalité, il ne l'est pas")
  func greenMonth() {
    let state = compute([
      event(nil, .toRead, at: "2026-08-02T10:00:00Z"),
      event(.toRead, .reading, at: "2026-08-03T10:00:00Z"),
      event(.toRead, .released, at: "2026-09-03T10:00:00Z"),
    ])
    #expect(state.greenMonths == [MonthKey(year: 2026, month: 9)])
    #expect(badges(state).contains(.greenMonth))
    #expect(state.award(.greenMonth)?.earnedAt == instant("2026-09-03T10:00:00Z"))
  }

  @Test("Série : mois au vert consécutifs jusqu'au mois précédent, plus le mois en cours s'il est au vert")
  func streak() {
    let greenAugToOct = ["2026-08-10", "2026-09-10", "2026-10-10"].map {
      event(.toRead, .released, at: "\($0)T10:00:00Z")
    }
    // Novembre pas encore au vert : la série s'arrête à octobre.
    #expect(compute(greenAugToOct).streak == 3)
    // Novembre au vert : il s'ajoute.
    #expect(compute(greenAugToOct + [event(.toRead, .read, at: "2026-11-02T10:00:00Z")]).streak == 4)
    // Une entrée qui égalise novembre ne casse pas la série des mois précédents.
    let tied = greenAugToOct + [
      event(.toRead, .read, at: "2026-11-02T10:00:00Z"), event(nil, .toRead, at: "2026-11-03T10:00:00Z"),
    ]
    #expect(compute(tied).streak == 3)
  }

  @Test("Série : un mois sans mouvement la coupe, et une série à 0 vaut 0")
  func streakBroken() {
    let events = [
      event(.toRead, .released, at: "2026-07-10T10:00:00Z"),
      event(.toRead, .released, at: "2026-08-10T10:00:00Z"),
      // Septembre : rien. Octobre au vert.
      event(.toRead, .released, at: "2026-10-10T10:00:00Z"),
    ]
    #expect(compute(events).streak == 1)
    #expect(compute(events, now: "2026-12-05T10:00:00Z").streak == 0)
    #expect(compute([]).streak == 0)
  }

  @Test("Trois à la suite : obtenu quand le troisième mois consécutif passe au vert")
  func greenStreak3() {
    let two = ["2026-08-10", "2026-09-10"].map { event(.toRead, .released, at: "\($0)T10:00:00Z") }
    #expect(!badges(compute(two)).contains(.greenStreak3))
    let three = two + [event(.toRead, .released, at: "2026-10-10T10:00:00Z")]
    let state = compute(three)
    #expect(badges(state).contains(.greenStreak3))
    #expect(state.award(.greenStreak3)?.earnedAt == instant("2026-10-10T10:00:00Z"))
    // Avec un trou au milieu, pas de badge.
    let gap = ["2026-07-10", "2026-08-10", "2026-10-10"].map { event(.toRead, .released, at: "\($0)T10:00:00Z") }
    #expect(!badges(compute(gap)).contains(.greenStreak3))
  }

  // MARK: Badges

  @Test("Premier pas : la première sortie, avec son livre")
  func firstExit() {
    let book = Item()
    let state = compute([
      event(book, .toRead, .abandoned, at: "2026-07-10T10:00:00Z"),
      event(.toRead, .released, at: "2026-07-11T10:00:00Z"),
    ])
    #expect(state.award(.firstExit) == BadgeAward(badge: .firstExit, earnedAt: instant("2026-07-10T10:00:00Z"),
                                                  userBookId: book.row))
  }

  @Test("Fond de pile : commencer le livre le plus ancien de la PAL à cet instant")
  func bottomOfPile() {
    let oldest = Item(), middle = Item(), recent = Item()
    let history = [
      event(oldest, nil, .toRead, at: "2020-01-01T10:00:00Z"),
      event(middle, nil, .toRead, at: "2023-01-01T10:00:00Z"),
      event(recent, nil, .toRead, at: "2026-07-01T10:00:00Z"),
    ]
    // Commencer le plus récent : non.
    #expect(!badges(compute(history + [event(recent, .toRead, .reading, at: "2026-07-05T10:00:00Z")]))
      .contains(.bottomOfPile))
    // Libérer le plus ancien : non (il faut le commencer ou le lire).
    let released = history + [event(oldest, .toRead, .released, at: "2026-07-05T10:00:00Z")]
    #expect(!badges(compute(released)).contains(.bottomOfPile))
    // Une fois le plus ancien libéré, celui du milieu devient le fond de la pile.
    let next = released + [event(middle, .toRead, .read, at: "2026-07-06T10:00:00Z")]
    #expect(compute(next).award(.bottomOfPile)?.userBookId == middle.row)
    // Commencer le plus ancien : oui.
    let state = compute(history + [event(oldest, .toRead, .reading, at: "2026-07-05T10:00:00Z")])
    #expect(state.award(.bottomOfPile)?.userBookId == oldest.row)
  }

  @Test("Fond de pile : le plus ancien commencé avant le début du décompte ne compte pas")
  func bottomOfPileBeforeStart() {
    let oldest = Item()
    let state = compute([
      event(oldest, nil, .toRead, at: "2020-01-01T10:00:00Z"),
      event(Item(), nil, .toRead, at: "2021-01-01T10:00:00Z"),
      event(oldest, .toRead, .reading, at: "2026-05-05T10:00:00Z"),
    ])
    #expect(!badges(state).contains(.bottomOfPile))
  }

  @Test("Archéologue : sortir un livre resté plus de 2 ans dans la PAL, pas 2 ans pile ni moins")
  func archaeologist() {
    let book = Item()
    let entry = event(book, nil, .toRead, at: "2024-07-10T10:00:00Z")
    #expect(badges(compute([entry, event(book, .toRead, .released, at: "2026-07-10T10:00:01Z")]))
      .contains(.archaeologist))
    #expect(!badges(compute([entry, event(book, .toRead, .released, at: "2026-07-10T10:00:00Z")]))
      .contains(.archaeologist))
    #expect(!badges(compute([entry, event(book, .toRead, .released, at: "2026-06-30T10:00:00Z")]))
      .contains(.archaeologist))
  }

  @Test("Archéologue : l'ancienneté repart de la dernière entrée dans la PAL")
  func archaeologistReentry() {
    let book = Item()
    let state = compute([
      event(book, nil, .toRead, at: "2023-01-10T10:00:00Z"),
      event(book, .toRead, .wishlist, at: "2026-01-10T10:00:00Z"),
      event(book, .wishlist, .toRead, at: "2026-03-10T10:00:00Z"),
      event(book, .toRead, .released, at: "2026-07-10T10:00:00Z"),
    ])
    #expect(!badges(state).contains(.archaeologist))
  }

  @Test("Grand ménage : 5 livres libérés dans le même mois civil")
  func bigCleanup() {
    let five = (1...5).map { day in event(.toRead, .released, at: "2026-09-0\(day)T10:00:00Z") }
    let state = compute(five)
    #expect(state.award(.bigCleanup)?.earnedAt == instant("2026-09-05T10:00:00Z"))
    // 4 en septembre, 1 en octobre (0 h 30 le 1er octobre à Paris) : non.
    let split = Array(five.prefix(4)) + [event(.toRead, .released, at: "2026-09-30T22:30:00Z")]
    #expect(!badges(compute(split)).contains(.bigCleanup))
    // D'autres sorties que des libérations ne comptent pas.
    let mixed = Array(five.prefix(4)) + [event(.toRead, .abandoned, at: "2026-09-06T10:00:00Z")]
    #expect(!badges(compute(mixed)).contains(.bigCleanup))
  }

  @Test("Grand ménage : le même livre libéré deux fois ne compte qu'une fois ; progression du mois en cours")
  func bigCleanupSameBook() {
    let book = Item()
    var events = (1...3).map { day in event(.toRead, .released, at: "2026-11-0\(day)T10:00:00Z") }
    events += [
      event(book, nil, .toRead, at: "2026-10-01T10:00:00Z"),
      event(book, .toRead, .released, at: "2026-11-05T10:00:00Z"),
      event(book, .released, .toRead, at: "2026-11-07T10:00:00Z"),
      event(book, .toRead, .released, at: "2026-11-09T10:00:00Z"),
    ]
    let state = compute(events)
    #expect(state.releasedThisMonth == 4)
    #expect(!badges(state).contains(.bigCleanup))
  }

  @Test("Moitié moins : PAL ≤ moitié de la taille de départ, avec une taille de départ d'au moins 4")
  func halfPile() {
    func earned(size: Int, start: Int?) -> Bool {
      let goal = PALGoal(target: 0, startSize: start)
      let state = GameEngine.compute(events: [], library: pile(size), goal: goal, startedAt: instant(self.start),
                                     now: instant(now), calendar: Self.paris)
      return state.award(.halfPile) != nil
    }
    #expect(earned(size: 5, start: 10))
    #expect(!earned(size: 6, start: 10))
    #expect(earned(size: 4, start: 9))
    #expect(!earned(size: 5, start: 9))
    #expect(earned(size: 2, start: 4))
    #expect(!earned(size: 1, start: 3))
    #expect(!earned(size: 0, start: nil))
    // Sans objectif, pas de badge.
    #expect(GameEngine.compute(events: [], library: [], goal: nil, startedAt: instant(start)).awards.isEmpty)
  }

  @Test("Objectif atteint : PAL ≤ cible")
  func goalReached() {
    let goal = PALGoal(target: 3, startSize: 10)
    func state(size: Int) -> GameState {
      GameEngine.compute(events: [], library: pile(size), goal: goal, startedAt: instant(start), calendar: Self.paris)
    }
    #expect(state(size: 3).award(.goalReached) != nil)
    #expect(state(size: 4).award(.goalReached) == nil)
  }

  @Test("Pavé : finir (passer à read) un livre de plus de 600 pages, même ajouté directement comme lu")
  func brick() {
    let big = Item(), small = Item(), added = Item()
    let library = [
      libraryItem(big, status: .read, pages: 601),
      libraryItem(small, status: .read, pages: 600),
      libraryItem(added, status: .read, pages: 900),
    ]
    #expect(compute([event(small, .reading, .read, at: "2026-07-01T10:00:00Z")], library: library).award(.brick) == nil)
    let finished = compute([event(big, .reading, .read, at: "2026-07-03T10:00:00Z")], library: library)
    #expect(finished.award(.brick)?.userBookId == big.row)
    let logged = compute([event(added, nil, .read, at: "2026-07-02T10:00:00Z")], library: library)
    #expect(logged.award(.brick)?.userBookId == added.row)
  }

  @Test("Dix de moins : la dixième sortie comptée")
  func tenOut() {
    let nine = (1...9).map { day in event(.toRead, .released, at: "2026-08-0\(day)T10:00:00Z") }
    #expect(!badges(compute(nine)).contains(.tenOut))
    let ten = nine + [event(.toRead, .reading, at: "2026-08-20T10:00:00Z")]
    #expect(compute(ten).award(.tenOut)?.earnedAt == instant("2026-08-20T10:00:00Z"))
  }

  @Test("Coup de dé : commencer dans les 7 jours un livre proposé par la pioche")
  func pickAccepted() {
    let book = Item()
    let picks = [PickSuggestion(userBookId: book.row, suggestedAt: instant("2026-07-01T10:00:00Z"))]
    let entry = event(book, nil, .toRead, at: "2026-03-01T10:00:00Z")
    let inTime = compute([entry, event(book, .toRead, .reading, at: "2026-07-08T09:00:00Z")], picks: picks)
    #expect(inTime.award(.pickAccepted)?.userBookId == book.row)
    let late = compute([entry, event(book, .toRead, .reading, at: "2026-07-08T11:00:00Z")], picks: picks)
    #expect(late.award(.pickAccepted) == nil)
    // Un autre livre commencé ne compte pas.
    let other = compute([event(Item(), .toRead, .reading, at: "2026-07-02T10:00:00Z")], picks: picks)
    #expect(other.award(.pickAccepted) == nil)
  }

  @Test("Les badges sont rendus dans l'ordre du catalogue, chacun une seule fois")
  func awardsOrder() {
    let events = (1...9).map { day in event(.toRead, .released, at: "2026-08-0\(day)T10:00:00Z") }
      + [event(.toRead, .released, at: "2026-08-10T10:00:00Z")]
    let state = compute(events)
    #expect(state.awards.map(\.badge) == [.firstExit, .bigCleanup, .greenMonth, .tenOut])
  }
}
