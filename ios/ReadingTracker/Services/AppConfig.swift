import Foundation
import Supabase

enum AppConfig {
  /// URL du projet, construite depuis `SUPABASE_HOST` (Config/Supabase.xcconfig → Info.plist).
  static let supabaseURL: URL = {
    let host = Bundle.main.object(forInfoDictionaryKey: "SupabaseHost") as? String ?? ""
    guard !host.isEmpty, let url = URL(string: "https://\(host)") else {
      fatalError("SupabaseHost manquant : vérifier Config/Supabase.xcconfig")
    }
    return url
  }()

  /// Clé publishable : prévue pour le client, ses droits sont bornés par la RLS.
  static let supabaseKey: String = {
    let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String ?? ""
    guard !key.isEmpty else { fatalError("SupabasePublishableKey manquant : vérifier Config/Supabase.xcconfig") }
    return key
  }()

  /// Mode démo (Debug uniquement) : `-demo` en argument de lancement affiche des données
  /// d'exemple sans réseau. `-demo-signed-out` démarre sur l'écran de connexion.
  static let isDemo: Bool = {
    #if DEBUG
    let args = ProcessInfo.processInfo.arguments
    return args.contains("-demo") || args.contains("-demo-signed-out")
    #else
    return false
    #endif
  }()

  /// Variante de la démo pour l'Accueil : `-demo-reading one` (une seule lecture en cours)
  /// ou `-demo-reading none` (aucune). Par défaut, plusieurs lectures en cours.
  static let demoReading: String = {
    #if DEBUG
    return UserDefaults.standard.string(forKey: "demo-reading") ?? "many"
    #else
    return "many"
    #endif
  }()

  static let demoStartsSignedOut: Bool = {
    #if DEBUG
    return ProcessInfo.processInfo.arguments.contains("-demo-signed-out")
    #else
    return false
    #endif
  }()
}

let supabase = SupabaseClient(
  supabaseURL: AppConfig.supabaseURL,
  supabaseKey: AppConfig.supabaseKey,
  options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
)

/// Traduit les erreurs courantes en message lisible.
enum ErrorMessage {
  static func from(_ error: Error) -> String {
    let raw = String(describing: error).lowercased()
    if raw.contains("invalid login credentials") { return "Email ou mot de passe incorrect." }
    if raw.contains("user already registered") { return "Un compte existe déjà avec cet email." }
    if raw.contains("password should be at least") || raw.contains("weak_password") {
      return "Mot de passe trop court (6 caractères minimum)."
    }
    if raw.contains("profiles_username") || (raw.contains("duplicate") && raw.contains("username")) {
      return "Ce nom d'utilisateur est déjà pris."
    }
    if raw.contains("23505") { return "Déjà présent." }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .notConnectedToInternet, .networkConnectionLost: return "Pas de connexion internet."
      case .timedOut: return "Le serveur ne répond pas."
      default: break
      }
    }
    return error.localizedDescription
  }
}
