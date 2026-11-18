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
      profile = try await fetchProfile(userId)
    } catch {
      profile = nil
    }
  }

  private func fetchProfile(_ userId: UUID) async throws -> Profile {
    try await supabase.from("profiles")
      .select()
      .eq("id", value: userId)
      .single()
      .execute()
      .value
  }

  /// Démarre le défi : la RPC `start_challenge()` pose `gamification_started_at` (idempotente), puis le profil
  /// est rechargé. Définitif : un défi démarré ne se redémarre pas.
  func startChallenge() async throws {
    guard let userId, let current = profile, !current.hasStartedChallenge else { return }
    if AppConfig.isDemo {
      profile?.gamificationStartedAt = ISO8601DateFormatter().string(from: .now)
      return
    }
    let startedAt: String = try await supabase.rpc("start_challenge").execute().value
    guard self.userId == userId else { return }
    profile?.gamificationStartedAt = startedAt
    // Relecture du profil ; en cas d'échec, la valeur renvoyée par la RPC suffit.
    if let fresh = try? await fetchProfile(userId), self.userId == userId { profile = fresh }
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

  /// Réglage « Jeu » (`gamification_enabled`), avec la même mise à jour optimiste.
  func setGamificationEnabled(_ enabled: Bool) async throws {
    guard let current = profile, current.gamificationEnabled != enabled else { return }
    profile?.gamificationEnabled = enabled
    guard !AppConfig.isDemo else { return }
    do {
      try await supabase.from("profiles")
        .update(["gamification_enabled": enabled])
        .eq("id", value: current.id)
        .execute()
    } catch {
      profile?.gamificationEnabled = current.gamificationEnabled
      throw error
    }
  }

  private func applyDemoSession() {
    profile = DemoData.me
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
