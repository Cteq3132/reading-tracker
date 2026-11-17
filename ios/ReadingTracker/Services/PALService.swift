import Foundation
import Observation
import Supabase

/// Historique de la PAL (`user_book_events`) du compte et des amis suivis : bilans du mois,
/// calculés ici dans le fuseau local. La taille de la PAL vient de `LibraryService`.
@MainActor
@Observable
final class PALService {
  private(set) var events: [UserBookEvent] = []
  private(set) var friendEvents: [UserBookEvent] = []
  private(set) var hasLoaded = false
  var errorMessage: String?

  /// Ids négatifs pour les événements ajoutés localement, en attendant le prochain chargement.
  private var nextLocalId: Int64 = -1

  /// Entrées, sorties et solde de ma PAL ce mois-ci.
  func monthBalance(now: Date = .now) -> PALBalance {
    PALLedger.balance(of: events, inMonthOf: now)
  }

  /// Bilan du mois de chaque ami suivi qui a au moins un mouvement de PAL.
  func friendBalances(now: Date = .now) -> [UUID: PALBalance] {
    Dictionary(grouping: friendEvents, by: \.userId)
      .mapValues { PALLedger.balance(of: $0, inMonthOf: now) }
      .filter { !$0.value.isEmpty }
  }

  /// Charge les événements du mois en cours (début du mois dans le fuseau local).
  func load(userId: UUID, friendIds: [UUID]) async {
    if AppConfig.isDemo {
      if !hasLoaded {
        events = DemoData.events
        friendEvents = DemoData.friendEvents
      }
      hasLoaded = true
      return
    }
    let since = ISO8601DateFormatter().string(from: PALLedger.monthStart(of: .now))
    do {
      async let mine = fetch(userIds: [userId], since: since)
      async let friends = fetch(userIds: friendIds, since: since)
      (events, friendEvents) = try await (mine, friends)
      errorMessage = nil
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
    hasLoaded = true
  }

  private func fetch(userIds: [UUID], since: String) async throws -> [UserBookEvent] {
    guard !userIds.isEmpty else { return [] }
    // Filtre explicite : la RLS laisse aussi lire l'historique des profils publics.
    return try await supabase.from("user_book_events")
      .select()
      .in("user_id", values: userIds.map(\.uuidString))
      .gte("occurred_at", value: since)
      .order("occurred_at")
      .limit(2000)
      .execute()
      .value
  }

  /// Ajoute localement l'événement que le trigger vient d'écrire côté serveur, pour que le bilan
  /// change sans recharger. Il est remplacé par la vraie ligne au prochain chargement.
  func record(userId: UUID, userBookId: UUID?, bookId: UUID, from: ReadingStatus?, to: ReadingStatus?) {
    guard from != to else { return }
    events.append(UserBookEvent(
      id: nextLocalId, userId: userId, userBookId: userBookId, bookId: bookId,
      fromStatus: from, toStatus: to, occurredAt: ISO8601DateFormatter().string(from: .now)
    ))
    nextLocalId -= 1
  }

  func reset() {
    events = []
    friendEvents = []
    hasLoaded = false
    errorMessage = nil
  }
}
