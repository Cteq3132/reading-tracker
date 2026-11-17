import Foundation
import Testing
@testable import ReadingTracker

/// Bilans de la PAL (entrées, sorties, solde du mois dans le fuseau local), objectif, ancienneté et ordres.
struct PALTests {
  private func calendar(_ identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
  }

  private func instant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  private func event(_ from: ReadingStatus?, _ to: ReadingStatus?, at iso: String = "2026-11-10T10:00:00Z") -> UserBookEvent {
    UserBookEvent(
      id: Int64.random(in: 1...1_000_000), userId: UUID(), userBookId: UUID(), bookId: UUID(),
      fromStatus: from, toStatus: to, occurredAt: iso
    )
  }

  private let paris = "Europe/Paris"
  private let midNovember = "2026-11-17T12:00:00Z"

  // MARK: Entrées et sorties

  @Test("Ajouter un livre à la PAL ou recevoir une envie compte comme une entrée")
  func entries() {
    #expect(event(nil, .toRead).isPALEntry)
    #expect(event(.wishlist, .toRead).isPALEntry)
    #expect(event(.released, .toRead).isPALEntry)
    #expect(!event(nil, .wishlist).isPALEntry)
    #expect(!event(nil, .reading).isPALEntry)
  }

  @Test("Quitter to_read compte comme une sortie, quel que soit le statut d'arrivée", arguments: [
    ReadingStatus.reading, .read, .abandoned, .released, .wishlist,
  ])
  func exitFromToRead(to status: ReadingStatus) {
    let e = event(.toRead, status)
    #expect(e.isPALExit)
    #expect(!e.isPALEntry)
  }

  @Test("Supprimer une ligne to_read est une sortie ; supprimer une autre ligne ne compte pas")
  func deletion() {
    #expect(event(.toRead, nil).isPALExit)
    #expect(!event(.wishlist, nil).isPALExit)
    #expect(!event(.reading, nil).isPALExit)
  }

  @Test("Les changements hors PAL ne comptent ni en entrée ni en sortie")
  func outsidePAL() {
    for e in [event(.reading, .read), event(.wishlist, .released), event(.read, .reading)] {
      #expect(!e.isPALEntry && !e.isPALExit)
    }
  }

  @Test("Bilan du mois : entrées, sorties, suppression et solde")
  func monthBalance() {
    let events = [
      event(nil, .toRead, at: "2026-11-03T10:00:00Z"),
      event(.wishlist, .toRead, at: "2026-11-09T10:00:00Z"),
      event(.toRead, .reading, at: "2026-11-05T10:00:00Z"),
      event(.toRead, .released, at: "2026-11-06T10:00:00Z"),
      event(.toRead, nil, at: "2026-11-07T10:00:00Z"),
      event(.reading, .read, at: "2026-11-08T10:00:00Z"),
      // Mois précédent : ignoré.
      event(.toRead, .reading, at: "2026-10-20T10:00:00Z"),
    ]
    let balance = PALLedger.balance(of: events, inMonthOf: instant(midNovember), calendar: calendar(paris))
    #expect(balance == PALBalance(entries: 2, exits: 3))
    #expect(balance.net == -1)
    #expect(balance.compactLabel == "+2 · \u{2212}3 · \u{2212}1")
  }

  @Test("Frontière de mois dans le fuseau local : 0 h 30 le 1er novembre à Paris compte en novembre")
  func monthBoundaryParis() {
    // 31 octobre 23 h 30 UTC = 1er novembre 0 h 30 à Paris (UTC+1).
    let events = [event(.toRead, .released, at: "2026-10-31T23:30:00Z")]
    let november = PALLedger.balance(of: events, inMonthOf: instant(midNovember), calendar: calendar(paris))
    let october = PALLedger.balance(of: events, inMonthOf: instant("2026-10-15T12:00:00Z"), calendar: calendar(paris))
    #expect(november.exits == 1)
    #expect(october.exits == 0)
    // En UTC, le même instant reste en octobre.
    #expect(PALLedger.balance(of: events, inMonthOf: instant(midNovember), calendar: calendar("UTC")).exits == 0)
  }

  @Test("Frontière de mois en retard sur l'UTC : 1er décembre 2 h UTC est encore novembre à Los Angeles")
  func monthBoundaryLosAngeles() {
    let events = [event(nil, .toRead, at: "2026-12-01T02:00:00Z")]
    let la = calendar("America/Los_Angeles")
    #expect(PALLedger.balance(of: events, inMonthOf: instant(midNovember), calendar: la).entries == 1)
    #expect(PALLedger.balance(of: events, inMonthOf: instant("2026-12-15T12:00:00Z"), calendar: la).entries == 0)
  }

  @Test("Le premier instant du mois suivant n'est pas compté dans le mois")
  func monthEndExcluded() {
    // 1er décembre 0 h à Paris = 30 novembre 23 h UTC.
    let events = [event(.toRead, .reading, at: "2026-11-30T23:00:00Z")]
    #expect(PALLedger.balance(of: events, inMonthOf: instant(midNovember), calendar: calendar(paris)).exits == 0)
  }

  @Test("Libellé du solde : signe moins typographique, zéro sans signe")
  func signedLabel() {
    #expect(PALBalance.signed(3) == "+3")
    #expect(PALBalance.signed(-3) == "\u{2212}3")
    #expect(PALBalance.signed(0) == "0")
    #expect(PALBalance(entries: 2, exits: 2).compactLabel == "+2 · \u{2212}2 · 0")
  }

  @Test("Un événement lu depuis Postgres (microsecondes, +00:00) est décodé et daté")
  func decodeEvent() throws {
    let json = """
    {"id": 42, "user_id": "00000000-0000-0000-0000-000000000001", "user_book_id": null,
     "book_id": "00000000-0000-0000-0000-000000000002", "from_status": "to_read", "to_status": null,
     "occurred_at": "2026-11-17T10:00:00.123456+00:00"}
    """
    let e = try JSONDecoder().decode(UserBookEvent.self, from: Data(json.utf8))
    #expect(e.fromStatus == .toRead && e.toStatus == nil && e.userBookId == nil)
    #expect(e.isPALExit)
    #expect(e.date != nil)
  }

  // MARK: Objectif

  @Test("Progression de l'objectif : (départ − actuel) / (départ − cible), bornée")
  func goalProgress() {
    let goal = PALGoal(target: 8, deadline: "2026-12-31", startSize: 14)
    #expect(goal.progress(currentSize: 11) == 0.5)
    #expect(goal.progress(currentSize: 14) == 0)
    #expect(goal.progress(currentSize: 16) == 0)
    #expect(goal.progress(currentSize: 8) == 1)
    #expect(goal.progress(currentSize: 3) == 1)
    #expect(goal.remaining(currentSize: 11) == 3)
    #expect(goal.remaining(currentSize: 5) == 0)
  }

  @Test("Objectif sans taille de départ, ou déjà atteint au départ : pas de division par zéro")
  func goalEdgeCases() {
    #expect(PALGoal(target: 8, startSize: nil).progress(currentSize: 10) == 0)
    #expect(PALGoal(target: 8, startSize: 8).progress(currentSize: 9) == 0)
    #expect(PALGoal(target: 8, startSize: 8).progress(currentSize: 8) == 1)
  }

  @Test("L'objectif se lit depuis une ligne de pal_goals")
  func decodeGoal() throws {
    let json = """
    {"user_id": "00000000-0000-0000-0000-000000000001", "target": 8, "deadline": "2026-12-31",
     "start_size": 14, "set_at": "2026-10-01T08:00:00.123456+00:00"}
    """
    let goal = try JSONDecoder().decode(PALGoal.self, from: Data(json.utf8))
    #expect(goal == PALGoal(target: 8, deadline: "2026-12-31", startSize: 14, setAt: "2026-10-01T08:00:00.123456+00:00"))
    let open = try JSONDecoder().decode(PALGoal.self, from: Data(#"{"target": 5, "deadline": null, "start_size": null}"#.utf8))
    #expect(open.deadline == nil && open.startSize == nil)
  }

  @Test("L'upsert de l'objectif n'envoie que la cible et l'échéance, null compris")
  func goalUpsertEncoding() throws {
    let data = try JSONEncoder().encode(PALGoalUpsert(target: 8, deadline: nil))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json.keys.sorted() == ["deadline", "target"])
    #expect(json["target"] as? Int == 8)
    #expect(json["deadline"] is NSNull)
  }

  // MARK: Ancienneté

  @Test("Ancienneté dans la PAL", arguments: [
    ("2026-11-17T08:00:00Z", "depuis aujourd'hui"),
    ("2026-11-16T08:00:00Z", "depuis hier"),
    ("2026-11-12T08:00:00Z", "depuis 5 jours"),
    ("2026-11-08T08:00:00Z", "depuis 1 semaine"),
    ("2026-10-27T08:00:00Z", "depuis 3 semaines"),
    ("2026-09-10T08:00:00Z", "depuis 2 mois"),
    ("2025-10-01T08:00:00Z", "depuis 1 an"),
    ("2024-11-01T08:00:00Z", "depuis 2 ans"),
  ])
  func ageLabel(since: String, expected: String) {
    #expect(PALAge.label(since: instant(since), now: instant(midNovember), calendar: calendar(paris)) == expected)
  }

  // MARK: Ordres de la PAL et pioche

  private func palBook(_ title: String, pages: Int?, since: String) -> UserBook {
    let book = Book(
      id: UUID(), isbn13: nil, isbn10: nil, title: title, subtitle: nil, authors: [], publisher: nil,
      publishedDate: nil, pageCount: pages, description: nil, language: nil, coverUrl: nil, source: "manual", sourceId: nil
    )
    return UserBook(userId: UUID(), book: book, status: .toRead, statusChangedAt: since)
  }

  @Test("Tri par ancienneté puis par nombre de pages (sans nombre de pages à la fin)")
  func orders() {
    let items = [
      palBook("Récent", pages: 300, since: "2026-11-01T10:00:00Z"),
      palBook("Ancien", pages: 900, since: "2022-01-01T10:00:00Z"),
      palBook("Sans pages", pages: nil, since: "2024-01-01T10:00:00Z"),
      palBook("Court", pages: 120, since: "2025-06-01T10:00:00Z"),
    ]
    #expect(PALOrder.oldest.sorted(items).map { $0.book!.title } == ["Ancien", "Sans pages", "Court", "Récent"])
    #expect(PALOrder.shortest.sorted(items).map { $0.book!.title } == ["Court", "Récent", "Ancien", "Sans pages"])
    #expect(PALDrawMode.oldest.order(items).first?.book?.title == "Ancien")
    #expect(PALDrawMode.shortest.order(items).first?.book?.title == "Court")
    #expect(PALDrawMode.random.order(items, shuffle: { $0.reversed() }).first?.book?.title == "Court")
  }

  @Test("L'ancienneté ne vaut que pour un livre de la PAL")
  func palSinceOnlyForToRead() {
    var item = palBook("Livre", pages: 100, since: "2026-01-01T10:00:00Z")
    #expect(item.palSince != nil)
    item.status = .wishlist
    #expect(item.palSince == nil)
  }

  // MARK: Nouveaux statuts

  @Test("Commencer une envie ou un livre libéré propose aujourd'hui")
  func startFromWishlistOrReleased() {
    for status in [ReadingStatus.wishlist, .released] {
      var saved = palBook("Livre", pages: 100, since: "2026-01-01T10:00:00Z")
      saved.status = status
      saved.startedAt = "2025-01-10"
      var update = UserBookUpdate(saved)
      update.setStatus(.reading, from: saved, today: "2026-11-17")
      #expect(update.startedAt == "2026-11-17")
    }
  }

  @Test("Libérer un livre ou le mettre dans les envies masque ses dates")
  func releasedHidesDates() {
    var update = UserBookUpdate(palBook("Livre", pages: 100, since: "2026-01-01T10:00:00Z"))
    for status in [ReadingStatus.released, .wishlist, .toRead] {
      update.status = status
      #expect(!update.showsStartDate && !update.showsFinishDate)
    }
  }

  @Test("Changer de statut localement remet l'ancienneté à zéro ; une autre modification la garde")
  func applyingResetsStatusChangedAt() {
    let item = palBook("Livre", pages: 100, since: "2024-01-01T10:00:00Z")
    var update = UserBookUpdate(item)
    update.rating = 4
    #expect(item.applying(update, today: "2026-11-17").statusChangedAt == item.statusChangedAt)
    update.status = .released
    #expect(item.applying(update, today: "2026-11-17").statusChangedAt != item.statusChangedAt)
  }
}
