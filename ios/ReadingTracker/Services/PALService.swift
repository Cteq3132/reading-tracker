import Foundation
import Observation
import Supabase

/// Historique de la PAL (`user_book_events`) du compte et des amis suivis, avec les bilans du mois
/// calculés ici dans le fuseau local, et objectif PAL du compte (`pal_goals`, privé).
/// L'historique du compte est chargé en entier : le jeu en a besoin (ancienneté des livres dans la PAL,
/// jetons et mois au vert depuis le début du décompte). Celui des amis se limite au mois en cours.
/// La taille de la PAL vient de `LibraryService`.
@MainActor
@Observable
final class PALService {
  private(set) var events: [UserBookEvent] = []
  private(set) var friendEvents: [UserBookEvent] = []
  /// Objectif PAL du compte ; `nil` = pas d'objectif.
  private(set) var goal: PALGoal?
  private(set) var hasLoaded = false
  var errorMessage: String?

  /// Ids négatifs pour les événements ajoutés localement, en attendant le prochain chargement.
  private var nextLocalId: Int64 = -1
  /// Événements ajoutés localement pendant un chargement en cours : la réponse a pu être lue avant
  /// que le trigger les écrive, ils sont donc gardés s'ils n'y figurent pas.
  private var recordedDuringLoad: [UserBookEvent] = []
  private var isLoadingEvents = false

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

  /// Charge l'objectif et les événements du mois en cours (début du mois dans le fuseau local).
  func load(userId: UUID, friendIds: [UUID]) async {
    if AppConfig.isDemo {
      if !hasLoaded {
        events = DemoData.events
        friendEvents = DemoData.friendEvents
        goal = DemoData.goal
      }
      hasLoaded = true
      return
    }
    let since = ISO8601DateFormatter().string(from: PALLedger.monthStart(of: .now))
    isLoadingEvents = true
    recordedDuringLoad = []
    defer {
      isLoadingEvents = false
      recordedDuringLoad = []
    }
    do {
      async let mine = fetchHistory(userId: userId)
      async let friends = fetch(userIds: friendIds, since: since)
      async let ownGoal = fetchGoal(userId: userId)
      let (fetched, fetchedFriends, fetchedGoal) = try await (mine, friends, ownGoal)
      events = fetched + recordedDuringLoad.filter { !Self.contains(fetched, $0) }
      friendEvents = fetchedFriends
      goal = fetchedGoal
      errorMessage = nil
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
    hasLoaded = true
  }

  /// La réponse contient-elle déjà l'événement ajouté localement (même ligne, même passage, à 2 min près) ?
  private static func contains(_ events: [UserBookEvent], _ local: UserBookEvent) -> Bool {
    guard let date = local.date else { return false }
    return events.contains { event in
      event.bookId == local.bookId && event.fromStatus == local.fromStatus && event.toStatus == local.toStatus
        && abs((event.date ?? .distantPast).timeIntervalSince(date)) < 120
    }
  }

  private func fetchGoal(userId: UUID) async throws -> PALGoal? {
    let rows: [PALGoal] = try await supabase.from("pal_goals")
      .select()
      .eq("user_id", value: userId)
      .limit(1)
      .execute()
      .value
    return rows.first
  }

  // MARK: Objectif

  /// Fixe ou modifie l'objectif. Le trigger pose la taille de départ quand la cible change : on la
  /// prévoit localement (`currentSize`), puis la ligne renvoyée par le serveur fait foi.
  func setGoal(target: Int, deadline: String?, currentSize: Int) async throws {
    let previous = goal
    let restarts = previous?.target != target
    let optimistic = PALGoal(
      target: target, deadline: deadline,
      startSize: restarts ? currentSize : previous?.startSize,
      setAt: restarts ? ISO8601DateFormatter().string(from: .now) : previous?.setAt
    )
    goal = optimistic
    guard !AppConfig.isDemo else { return }
    do {
      let saved: PALGoal = try await supabase.from("pal_goals")
        .upsert(PALGoalUpsert(target: target, deadline: deadline), onConflict: "user_id")
        .select()
        .single()
        .execute()
        .value
      if goal == optimistic { goal = saved }
    } catch {
      if goal == optimistic { goal = previous }
      throw error
    }
  }

  /// Retire l'objectif (suppression de la ligne).
  func removeGoal(userId: UUID) async throws {
    let previous = goal
    goal = nil
    guard !AppConfig.isDemo else { return }
    do {
      try await supabase.from("pal_goals").delete().eq("user_id", value: userId).execute()
    } catch {
      if goal == nil { goal = previous }
      throw error
    }
  }

  /// Tout l'historique du compte, par pages (PostgREST plafonne le nombre de lignes par réponse).
  private func fetchHistory(userId: UUID) async throws -> [UserBookEvent] {
    let pageSize = 1000
    var all: [UserBookEvent] = []
    while true {
      let page: [UserBookEvent] = try await supabase.from("user_book_events")
        .select()
        .eq("user_id", value: userId)
        .order("occurred_at")
        .order("id")
        .range(from: all.count, to: all.count + pageSize - 1)
        .execute()
        .value
      all += page
      if page.count < pageSize { return all }
    }
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
    let event = UserBookEvent(
      id: nextLocalId, userId: userId, userBookId: userBookId, bookId: bookId,
      fromStatus: from, toStatus: to, occurredAt: ISO8601DateFormatter().string(from: .now)
    )
    nextLocalId -= 1
    events.append(event)
    if isLoadingEvents { recordedDuringLoad.append(event) }
  }

  func reset() {
    events = []
    friendEvents = []
    goal = nil
    hasLoaded = false
    errorMessage = nil
  }
}
