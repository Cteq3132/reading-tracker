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
  /// Compte dont les badges sont chargés : une réponse arrivée après une déconnexion est ignorée.
  private var badgesOwner: UUID?
  /// Badges en cours d'insertion, pour ne pas les envoyer deux fois.
  private var inserting: Set<Badge> = []
  private var lastCelebration: Date = .distantPast
  /// Dernier état calculé et ce qui l'a produit : les vues le lisent à chaque rendu, l'historique peut être long.
  @ObservationIgnored private var cachedState: (key: Int, state: GameState)?

  /// Un badge obtenu il y a plus longtemps que cela est enregistré sans carte (par exemple en réactivant le jeu).
  private static let celebrationWindow: TimeInterval = 24 * 3600

  // MARK: État du jeu

  /// Le jeu est affiché : réglage « Jeu » activé. Le défi peut ne pas être démarré.
  static func isEnabled(_ profile: Profile?) -> Bool {
    profile?.gamificationEnabled == true
  }

  /// État du jeu du compte, ou `nil` quand le jeu est masqué. Tant que le défi n'est pas démarré, l'état est
  /// vide (`isStarted` faux) : rien ne compte. Recalculé seulement quand l'historique, la bibliothèque,
  /// l'objectif, le profil, les suggestions de la pioche ou l'heure changent.
  func state(auth: AuthService, library: LibraryService, pal: PALService) -> GameState? {
    guard Self.isEnabled(auth.profile) else { return nil }
    guard let startedAt = auth.profile?.gamificationStartDate else { return GameState() }
    let now = Date.now
    var hasher = Hasher()
    hasher.combine(startedAt)
    hasher.combine(pal.events)
    hasher.combine(library.items.map { [$0.id.hashValue, $0.status.hashValue, $0.book?.pageCount ?? -1] })
    hasher.combine(pal.goal?.target)
    hasher.combine(pal.goal?.startSize)
    hasher.combine(picks.map { [$0.userBookId.hashValue, $0.suggestedAt.hashValue] })
    // Le mois en cours dépend de l'heure : une précision à la minute suffit.
    hasher.combine(Int(now.timeIntervalSince1970 / 60))
    let key = hasher.finalize()
    if let cachedState, cachedState.key == key { return cachedState.state }
    let state = GameEngine.compute(
      events: pal.events, library: library.items, goal: pal.goal, startedAt: startedAt, picks: picks, now: now
    )
    cachedState = (key, state)
    return state
  }

  /// Calcule le jeu et enregistre les badges nouvellement obtenus (après un changement de statut, au lancement).
  func evaluate(auth: AuthService, library: LibraryService, pal: PALService) async {
    guard let userId = auth.userId, library.hasLoaded, pal.hasLoaded,
          let state = state(auth: auth, library: library, pal: pal) else { return }
    await award(state, userId: userId, library: library.items)
  }

  /// Après un changement de statut (la bibliothèque a déjà changé) : célébrer un livre fini ou libéré et
  /// l'objectif atteint, puis attribuer les badges que ce changement fait obtenir. Rien si le jeu est masqué.
  func statusDidChange(from: ReadingStatus?, to: ReadingStatus?, auth: AuthService, library: LibraryService, pal: PALService) {
    guard Self.isEnabled(auth.profile) else { return }
    var celebrates = to == .read || to == .released
    if let goal = pal.goal {
      let size = library.toReadCount
      let before = size + (from == .toRead ? 1 : 0) - (to == .toRead ? 1 : 0)
      if !goal.isReached(currentSize: before), goal.isReached(currentSize: size) { celebrates = true }
    }
    if celebrates { celebrate() }
    Task { await evaluate(auth: auth, library: library, pal: pal) }
  }

  // MARK: Badges

  func loadBadges(userId: UUID) async {
    loadPicks(userId: userId)
    badgesOwner = userId
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
      guard badgesOwner == userId else { return }
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
  /// datés de l'événement qui les a fait obtenir, et célèbre ceux des dernières 24 h. Le livre déclencheur
  /// n'est envoyé que s'il est encore dans la bibliothèque (sinon la clé étrangère refuserait la ligne).
  func award(_ state: GameState, userId: UUID, library: [UserBook]) async {
    guard hasLoadedBadges, badgesOwner == userId else { return }
    let rowIds = Set(library.map(\.id))
    let new = state.awards.filter { earned[$0.badge] == nil && !inserting.contains($0.badge) }
    guard !new.isEmpty else { return }

    let formatter = ISO8601DateFormatter()
    let rows = new.map { award in
      UserBadgeInsert(
        userId: userId, badgeId: award.badge.rawValue, earnedAt: formatter.string(from: award.earnedAt),
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

    // Déconnecté pendant l'envoi : ces badges ne concernent plus la session affichée.
    guard badgesOwner == userId else { return }
    for row in rows {
      guard let badge = Badge(rawValue: row.badgeId) else { continue }
      earned[badge] = UserBadge(userId: userId, badgeId: row.badgeId, earnedAt: row.earnedAt, userBookId: row.userBookId)
    }
    let recent = Date.now.addingTimeInterval(-Self.celebrationWindow)
    enqueue(new.filter { $0.earnedAt >= recent }.map(\.badge))
  }

  private static func byBadge(_ rows: [UserBadge]) -> [Badge: UserBadge] {
    var result: [Badge: UserBadge] = [:]
    for row in rows {
      if let badge = row.badge { result[badge] = row }
    }
    return result
  }

  // MARK: Célébrations

  /// Confettis légers et retour haptique, une fois pour plusieurs raisons simultanées (livre fini et badge).
  func celebrate() {
    guard Date.now.timeIntervalSince(lastCelebration) > 1.5 else { return }
    lastCelebration = .now
    confettiBursts += 1
  }

  private func enqueue(_ badges: [Badge]) {
    guard !badges.isEmpty else { return }
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
    badgesOwner = nil
    cachedState = nil
    earned = [:]
    hasLoadedBadges = false
    celebratedBadge = nil
    pendingBadges = []
    picks = []
    picksOwner = nil
    inserting = []
  }
}
