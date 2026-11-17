import Foundation
import Observation
import Supabase

/// Session et profil de l'utilisateur connecté.
@MainActor
@Observable
final class AuthService {
  enum Phase: Equatable {
    case loading
    case signedOut
    case signedIn
  }

  private(set) var phase: Phase = .loading
  private(set) var userId: UUID?
  private(set) var profile: Profile?
  private(set) var email: String?

  /// Écoute les changements de session. À lancer une fois, dans une `.task` de la racine.
  func start() async {
    if AppConfig.isDemo {
      if AppConfig.demoStartsSignedOut {
        phase = .signedOut
      } else {
        applyDemoSession()
      }
      return
    }

    for await (event, session) in supabase.auth.authStateChanges {
      switch event {
      case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
        if let session {
          // Une session expirée est rafraîchie par le client avant la prochaine requête.
          let changed = userId != session.user.id
          userId = session.user.id
          email = session.user.email
          if changed || profile == nil { await loadProfile() }
          phase = .signedIn
        } else {
          reset()
        }
      case .signedOut:
        reset()
      default:
        break
      }
    }
  }

  func signIn(email: String, password: String) async throws {
    if AppConfig.isDemo { applyDemoSession(); return }
    try await supabase.auth.signIn(email: email, password: password)
  }

  func signUp(email: String, password: String, username: String) async throws {
    if AppConfig.isDemo { applyDemoSession(); return }
    try await supabase.auth.signUp(
      email: email,
      password: password,
      data: ["username": .string(username), "display_name": .string(username)]
    )
  }

  func signOut() async {
    if AppConfig.isDemo { reset(); return }
    try? await supabase.auth.signOut()
    reset()
  }

  func loadProfile() async {
    guard let userId, !AppConfig.isDemo else { return }
    do {
      profile = try await supabase.from("profiles")
        .select()
        .eq("id", value: userId)
        .single()
        .execute()
        .value
    } catch {
      profile = nil
    }
  }

  /// Mise à jour optimiste : l'interface change tout de suite, et revient en arrière si le serveur refuse.
  func setPrivate(_ isPrivate: Bool) async throws {
    guard let current = profile, current.isPrivate != isPrivate else { return }
    profile?.isPrivate = isPrivate
    guard !AppConfig.isDemo else { return }
    do {
      try await supabase.from("profiles")
        .update(["is_private": isPrivate])
        .eq("id", value: current.id)
        .execute()
    } catch {
      profile?.isPrivate = current.isPrivate
      throw error
    }
  }

  /// Fixe, modifie ou retire (`target == nil`) l'objectif PAL. Le trigger du backend pose la taille
  /// de départ quand la cible change : on la prévoit localement (`currentSize`), puis on relit le profil.
  func setPALGoal(target: Int?, deadline: String?, currentSize: Int) async throws {
    guard let current = profile else { return }
    var updated = current
    updated.palGoalTarget = target
    updated.palGoalDeadline = target == nil ? nil : deadline
    if target != current.palGoalTarget {
      updated.palGoalStartSize = target == nil ? nil : currentSize
      updated.palGoalSetAt = target == nil ? nil : ISO8601DateFormatter().string(from: .now)
    }
    profile = updated
    guard !AppConfig.isDemo else { return }
    do {
      try await supabase.from("profiles")
        .update(PALGoalUpdate(target: updated.palGoalTarget, deadline: updated.palGoalDeadline))
        .eq("id", value: current.id)
        .execute()
      await loadProfile()
    } catch {
      profile = current
      throw error
    }
  }

  private func applyDemoSession() {
    profile = DemoData.meWithGoal
    userId = DemoData.me.id
    email = "louis@exemple.fr"
    phase = .signedIn
  }

  private func reset() {
    userId = nil
    profile = nil
    email = nil
    phase = .signedOut
  }

  /// Règle du contrat : 3 à 30 caractères `[a-z0-9_]`.
  static func isValidUsername(_ username: String) -> Bool {
    username.range(of: "^[a-z0-9_]{3,30}$", options: .regularExpression) != nil
  }
}

/// Colonnes de l'objectif PAL envoyées par l'app ; `nil` part en `null` pour retirer l'objectif.
struct PALGoalUpdate: Encodable, Sendable {
  var target: Int?
  var deadline: String?

  enum CodingKeys: String, CodingKey {
    case target = "pal_goal_target"
    case deadline = "pal_goal_deadline"
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(target, forKey: .target)
    try c.encode(deadline, forKey: .deadline)
  }
}
