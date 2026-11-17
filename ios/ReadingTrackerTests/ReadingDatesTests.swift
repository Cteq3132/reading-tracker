import Foundation
import Testing
@testable import ReadingTracker

/// Conversion des dates de lecture (colonnes `date` de Postgres) et règles de la fiche.
struct ReadingDatesTests {
  private func calendar(_ identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
  }

  private func instant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  @Test("Une lecture commencée à 23 h à Paris reste datée du jour même")
  func lateEveningInParis() {
    // 23 h 30 à Paris (UTC+1) le 17 novembre = 22 h 30 UTC.
    #expect(PostgresDate.day(from: instant("2026-11-17T22:30:00Z"), calendar: calendar("Europe/Paris")) == "2026-11-17")
  }

  @Test("Juste après minuit à Paris, c'est déjà le lendemain, même si l'UTC est encore la veille")
  func justAfterMidnightInParis() {
    // 0 h 30 à Paris le 18 novembre = 23 h 30 UTC le 17.
    #expect(PostgresDate.day(from: instant("2026-11-17T23:30:00Z"), calendar: calendar("Europe/Paris")) == "2026-11-18")
  }

  @Test("Fuseau en retard sur l'UTC : 23 h à Los Angeles reste le jour local")
  func lateEveningInLosAngeles() {
    // 23 h à Los Angeles (UTC−8) le 17 novembre = 7 h UTC le 18.
    #expect(PostgresDate.day(from: instant("2026-11-18T07:00:00Z"), calendar: calendar("America/Los_Angeles")) == "2026-11-17")
  }

  @Test("Un jour relu donne le même jour, dans tous les fuseaux", arguments: [
    "Europe/Paris", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago", "America/Sao_Paulo",
  ])
  func roundTrip(zone: String) throws {
    let cal = calendar(zone)
    for day in ["2026-01-01", "2026-03-29", "2026-10-25", "2026-11-17", "2024-02-29"] {
      let date = try #require(PostgresDate.date(fromDay: day, calendar: cal))
      #expect(PostgresDate.day(from: date, calendar: cal) == day)
    }
  }

  @Test("Le calendrier par défaut est grégorien, quel que soit le calendrier choisi dans Réglages")
  func defaultCalendarIsGregorian() {
    #expect(PostgresDate.localCalendar.identifier == .gregorian)
    #expect(PostgresDate.localCalendar.timeZone == .current)
    var buddhist = Calendar(identifier: .buddhist)
    buddhist.timeZone = TimeZone(identifier: "Europe/Paris")!
    // Ce qu'aurait envoyé Calendar.current sur un iPhone réglé en calendrier bouddhiste.
    #expect(PostgresDate.day(from: instant("2026-11-17T10:00:00Z"), calendar: buddhist) == "2569-11-17")
    #expect(PostgresDate.day(from: instant("2026-11-17T10:00:00Z"), calendar: calendar("Europe/Paris")) == "2026-11-17")
  }

  @Test("Un jour invalide est refusé")
  func invalidDay() {
    #expect(PostgresDate.date(fromDay: "2026-02-30") == nil)
    #expect(PostgresDate.date(fromDay: "2026-13-01") == nil)
    #expect(PostgresDate.date(fromDay: "2026-00-10") == nil)
    #expect(PostgresDate.date(fromDay: "17/11/2026") == nil)
    #expect(PostgresDate.date(fromDay: "") == nil)
  }

  @Test("L'affichage long d'un jour ne glisse pas d'un jour")
  func longDisplayUsesLocalDay() {
    #expect(PostgresDate.long("2026-11-17") == "17 novembre 2026")
  }

  // MARK: Règles de la fiche

  private func userBook(_ status: ReadingStatus, started: String? = nil, finished: String? = nil) -> UserBook {
    let book = Book(
      id: UUID(), isbn13: nil, isbn10: nil, title: "Livre", subtitle: nil, authors: ["Auteur"], publisher: nil,
      publishedDate: nil, pageCount: 200, description: nil, language: nil, coverUrl: nil, source: "manual", sourceId: nil
    )
    return UserBook(userId: UUID(), book: book, status: status, startedAt: started, finishedAt: finished)
  }

  @Test("Commencer un livre de la PAL propose aujourd'hui, même avec une ancienne date")
  func startFromToRead() {
    let saved = userBook(.toRead, started: "2025-01-10")
    var update = UserBookUpdate(saved)
    update.setStatus(.reading, from: saved, today: "2026-11-17")
    #expect(update.startedAt == "2026-11-17")
  }

  @Test("Relire un livre déjà lu le date d'aujourd'hui, et le finir aussi")
  func rereadBook() {
    let saved = userBook(.read, started: "2025-03-01", finished: "2025-03-20")
    var update = UserBookUpdate(saved)
    update.setStatus(.reading, from: saved, today: "2026-11-17")
    #expect(update.startedAt == "2026-11-17")
    #expect(update.finishedAt == "2025-03-20")

    let reading = userBook(.reading, started: "2026-11-01", finished: "2025-03-20")
    var finish = UserBookUpdate(reading)
    finish.setStatus(.read, from: reading, today: "2026-11-17")
    #expect(finish.startedAt == "2026-11-01")
    #expect(finish.finishedAt == "2026-11-17")
  }

  @Test("Reprendre un livre abandonné garde sa date de début")
  func resumeAbandoned() {
    let saved = userBook(.abandoned, started: "2026-10-01")
    var update = UserBookUpdate(saved)
    update.setStatus(.reading, from: saved, today: "2026-11-17")
    #expect(update.startedAt == "2026-10-01")
  }

  @Test("Terminer un livre propose aujourd'hui comme date de fin, et revenir en arrière rend les dates")
  func finishThenUndo() {
    let saved = userBook(.reading, started: "2026-11-01")
    var update = UserBookUpdate(saved)
    update.setStatus(.read, from: saved, today: "2026-11-17")
    #expect(update.finishedAt == "2026-11-17")
    update.setStatus(.reading, from: saved, today: "2026-11-17")
    #expect(update == UserBookUpdate(saved))
  }

  @Test("Une date modifiée dans le brouillon survit au changement de statut")
  func editedStartSurvivesStatusChange() {
    let saved = userBook(.reading, started: "2026-11-08")
    var update = UserBookUpdate(saved)
    update.startedAt = "2026-11-05"
    update.setStatus(.read, from: saved, today: "2026-11-17")
    #expect(update.startedAt == "2026-11-05")
    #expect(update.finishedAt == "2026-11-17")
    update.setStatus(.toRead, from: saved, today: "2026-11-17")
    #expect(update.startedAt == "2026-11-08")
    #expect(update.finishedAt == nil)
  }

  @Test("Dates dans le futur ou fin avant début : message clair")
  func dateProblems() {
    var update = UserBookUpdate(userBook(.read, started: "2026-11-10", finished: "2026-11-12"))
    #expect(update.dateProblem(today: "2026-11-17") == nil)
    update.finishedAt = "2026-11-09"
    #expect(update.dateProblem(today: "2026-11-17") == "La date de fin ne peut pas précéder la date de début.")
    update.finishedAt = "2026-11-18"
    #expect(update.dateProblem(today: "2026-11-17") == "La date de fin ne peut pas être dans le futur.")
    update.startedAt = "2026-11-18"
    #expect(update.dateProblem(today: "2026-11-17") == "La date de début ne peut pas être dans le futur.")
  }

  @Test("Une date de fin masquée (livre en cours) n'est pas contrôlée")
  func hiddenFinishIgnored() {
    let update = UserBookUpdate(userBook(.reading, started: "2026-11-10", finished: "2026-11-01"))
    #expect(update.dateProblem(today: "2026-11-17") == nil)
  }

  @Test("Un ajout en cours envoie la date locale, un ajout à la PAL n'envoie aucune date")
  func insertSendsLocalDay() throws {
    let encoder = JSONEncoder()
    let reading = try encoder.encode(UserBookInsert(bookId: UUID(), status: .reading, today: "2026-11-17"))
    let json = try #require(JSONSerialization.jsonObject(with: reading) as? [String: Any])
    #expect(json["started_at"] as? String == "2026-11-17")
    #expect(json["finished_at"] == nil)

    let toRead = try encoder.encode(UserBookInsert(bookId: UUID(), status: .toRead, today: "2026-11-17"))
    let other = try #require(JSONSerialization.jsonObject(with: toRead) as? [String: Any])
    #expect(other["started_at"] == nil && other["finished_at"] == nil)
  }
}
