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

  func setPrivate(_ isPrivate: Bool) async throws {
    guard var updated = profile else { return }
    updated.isPrivate = isPrivate
    if !AppConfig.isDemo {
      try await supabase.from("profiles")
        .update(["is_private": isPrivate])
        .eq("id", value: updated.id)
        .execute()
    }
    profile = updated
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
