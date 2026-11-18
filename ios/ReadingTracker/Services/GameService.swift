import Foundation
import Observation
import Supabase

/// Côté app de la gamification : badges obtenus (`user_badges`), suggestions de la pioche mémorisées
/// localement, et célébrations (confettis, retour haptique, carte d'un nouveau badge).
/// Les règles sont dans `GameEngine` ; la taille de la PAL et l'historique viennent de `LibraryService`
/// et `PALService`.
@MainActor
@Observable
final class GameService {
  /// Badges obtenus par le compte, tels qu'enregistrés dans `user_badges`.
  private(set) var earned: [Badge: UserBadge] = [:]
  /// Les badges enregistrés ont été lus : sans eux, on ne sait pas lesquels sont nouveaux.
  private(set) var hasLoadedBadges = false
  /// Badge dont la carte de célébration est affichée.
  private(set) var celebratedBadge: Badge?
  /// Incrémentés à chaque célébration : déclenchent les confettis et le retour haptique.
  private(set) var confettiBursts = 0
  private(set) var picks: [PickSuggestion] = []

  private var pendingBadges: [Badge] = []
  private var picksOwner: UUID?
  /// Badges en cours d'insertion, pour ne pas les envoyer deux fois.
  private var inserting: Set<Badge> = []

  // MARK: État du jeu

  /// État du jeu du compte, ou `nil` quand le jeu est masqué (réglage « Jeu » désactivé, ou profil sans
  /// début de décompte, c'est-à-dire un backend qui ne connaît pas encore la gamification).
  func state(profile: Profile?, events: [UserBookEvent], library: [UserBook], goal: PALGoal?, now: Date = .now) -> GameState? {
    guard let profile, profile.gamificationEnabled, let startedAt = profile.gamificationStartDate else { return nil }
    return GameEngine.compute(events: events, library: library, goal: goal, startedAt: startedAt, picks: picks, now: now)
  }

  /// État du jeu à partir des services de l'app.
  func state(auth: AuthService, library: LibraryService, pal: PALService) -> GameState? {
    state(profile: auth.profile, events: pal.events, library: library.items, goal: pal.goal)
  }

  /// Calcule le jeu et enregistre les badges nouvellement obtenus (après un changement de statut, au lancement).
  func evaluate(auth: AuthService, library: LibraryService, pal: PALService) async {
    guard let userId = auth.userId, library.hasLoaded, pal.hasLoaded,
          let state = state(auth: auth, library: library, pal: pal) else { return }
    await award(state, userId: userId, library: library.items)
  }

  static func isEnabled(_ profile: Profile?) -> Bool {
    guard let profile else { return false }
    return profile.gamificationEnabled && profile.gamificationStartDate != nil
  }

  // MARK: Badges

  func loadBadges(userId: UUID) async {
    loadPicks(userId: userId)
    if AppConfig.isDemo {
      if !hasLoadedBadges { earned = Self.byBadge(DemoData.earnedBadges) }
      hasLoadedBadges = true
      return
    }
    do {
      let rows: [UserBadge] = try await supabase.from("user_badges")
        .select()
        .eq("user_id", value: userId)
        .execute()
        .value
      earned = Self.byBadge(rows)
      hasLoadedBadges = true
    } catch {
      // Sans la liste, on n'attribue rien : un badge déjà obtenu serait célébré une seconde fois.
    }
  }

  /// Badges d'un autre compte. La RLS ne les rend lisibles que si son jeu est affiché et s'il est public ou suivi.
  func badges(of userId: UUID) async throws -> [UserBadge] {
    if AppConfig.isDemo { return DemoData.friendBadges[userId] ?? [] }
    return try await supabase.from("user_badges")
      .select()
      .eq("user_id", value: userId)
      .order("earned_at", ascending: false)
      .execute()
      .value
  }

  /// Enregistre les badges que l'état du jeu attribue et qui ne le sont pas encore (`on conflict do nothing`),
  /// et les célèbre si `celebrate`. Le livre déclencheur n'est envoyé que s'il est encore dans la bibliothèque
  /// (sinon la clé étrangère refuserait la ligne).
  func award(_ state: GameState, userId: UUID, library: [UserBook], celebrate: Bool = true) async {
    guard hasLoadedBadges else { return }
    let rowIds = Set(library.map(\.id))
    let new = state.awards.filter { earned[$0.badge] == nil && !inserting.contains($0.badge) }
    guard !new.isEmpty else { return }

    let rows = new.map { award in
      UserBadgeInsert(
        userId: userId, badgeId: award.badge.rawValue,
        userBookId: award.userBookId.flatMap { rowIds.contains($0) ? $0 : nil }
      )
    }
    inserting.formUnion(new.map(\.badge))
    defer { inserting.subtract(new.map(\.badge)) }

    if !AppConfig.isDemo {
      do {
        try await supabase.from("user_badges")
          .upsert(rows, onConflict: "user_id,badge_id", returning: .minimal, ignoreDuplicates: true)
          .execute()
      } catch {
        // Réessayé au prochain changement de statut ou au prochain lancement.
        return
      }
    }

    let now = ISO8601DateFormatter().string(from: .now)
    for row in rows {
      guard let badge = Badge(rawValue: row.badgeId) else { continue }
      earned[badge] = UserBadge(userId: userId, badgeId: row.badgeId, earnedAt: now, userBookId: row.userBookId)
    }
    if celebrate { enqueue(new.map(\.badge)) }
  }

  private static func byBadge(_ rows: [UserBadge]) -> [Badge: UserBadge] {
    var result: [Badge: UserBadge] = [:]
    for row in rows {
      if let badge = row.badge { result[badge] = row }
    }
    return result
  }

  // MARK: Célébrations

  /// Confettis légers et retour haptique.
  func celebrate() {
    confettiBursts += 1
  }

  private func enqueue(_ badges: [Badge]) {
    pendingBadges.append(contentsOf: badges.filter { $0 != celebratedBadge && !pendingBadges.contains($0) })
    if celebratedBadge == nil { showNextBadge() }
  }

  /// Ferme la carte du badge et passe au suivant s'il y en a.
  func dismissBadge() {
    celebratedBadge = nil
    showNextBadge()
  }

  private func showNextBadge() {
    guard !pendingBadges.isEmpty else { return }
    celebratedBadge = pendingBadges.removeFirst()
    celebrate()
  }

  /// Affiche la carte d'un badge, pour la démo (`-demo-celebrate <badge_id>`).
  func showDemoCelebration(_ badge: Badge) {
    enqueue([badge])
  }

  // MARK: Suggestions de la pioche

  /// Mémorise localement qu'un livre a été proposé par « Piocher dans ma PAL » (badge `pick_accepted`).
  func recordPick(userBookId: UUID, userId: UUID, at date: Date = .now) {
    loadPicks(userId: userId)
    picks.removeAll { $0.userBookId == userBookId }
    picks.append(PickSuggestion(userBookId: userBookId, suggestedAt: date))
    // Au-delà de la fenêtre de 7 jours, une suggestion ne sert plus.
    let limit = date.addingTimeInterval(-Double(GameEngine.pickWindowDays + 1) * 86_400)
    picks.removeAll { $0.suggestedAt < limit }
    savePicks(userId: userId)
  }

  private static func picksKey(_ userId: UUID) -> String { "game.picks.\(userId.uuidString)" }

  private func loadPicks(userId: UUID) {
    guard picksOwner != userId else { return }
    picksOwner = userId
    // La démo repart de zéro à chaque lancement.
    guard !AppConfig.isDemo, let data = UserDefaults.standard.data(forKey: Self.picksKey(userId)) else {
      picks = []
      return
    }
    picks = (try? JSONDecoder().decode([PickSuggestion].self, from: data)) ?? []
  }

  private func savePicks(userId: UUID) {
    guard !AppConfig.isDemo, let data = try? JSONEncoder().encode(picks) else { return }
    UserDefaults.standard.set(data, forKey: Self.picksKey(userId))
  }

  func reset() {
    earned = [:]
    hasLoadedBadges = false
    celebratedBadge = nil
    pendingBadges = []
    picks = []
    picksOwner = nil
    inserting = []
  }
}
