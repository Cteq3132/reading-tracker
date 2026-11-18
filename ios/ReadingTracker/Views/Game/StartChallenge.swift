import SwiftUI

/// Textes du démarrage du défi, partagés par l'Accueil et le Profil.
enum ChallengeText {
  static let title = "Démarrer le défi"
  /// Ce que le démarrage change : la PAL du moment devient le point de départ.
  static let explanation =
    "Ta PAL actuelle devient le point de départ : à partir de là, chaque entrée et chaque sortie comptent."

  static func confirmation(palSize: Int) -> String {
    let pile = palSize == 0
      ? "Ta PAL vide devient le point de départ."
      : "Ta PAL de \(palSize) livre\(palSize > 1 ? "s" : "") devient le point de départ."
    return "\(pile) Deux sorties libèrent une place, chaque entrée en occupe une. Le défi ne se remet pas à zéro."
  }
}

/// Bouton « Démarrer le défi », avec une confirmation légère puisque le démarrage est définitif. Appelle la RPC
/// `start_challenge()`, puis l'app recharge le profil.
struct StartChallengeButton: View {
  enum Style {
    /// Bouton en verre, sur la carte PAL de l'Accueil.
    case card
    /// Ligne de liste, dans le Profil.
    case row
  }

  var style: Style = .card

  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library

  @State private var confirmStart = false
  @State private var isStarting = false
  @State private var errorMessage: String?

  var body: some View {
    button
      .disabled(isStarting || auth.profile == nil)
      .confirmationDialog("Démarrer le défi ?", isPresented: $confirmStart, titleVisibility: .visible) {
        Button(ChallengeText.title) {
          Task { await start() }
        }
        Button("Plus tard", role: .cancel) {}
      } message: {
        Text(ChallengeText.confirmation(palSize: library.toReadCount))
      }
      .errorAlert($errorMessage)
  }

  @ViewBuilder
  private var button: some View {
    switch style {
    case .card:
      Button { confirmStart = true } label: {
        Label(ChallengeText.title, systemImage: "flag.checkered")
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.glass)
    case .row:
      Button(ChallengeText.title, systemImage: "flag.checkered") { confirmStart = true }
    }
  }

  private func start() async {
    isStarting = true
    defer { isStarting = false }
    do {
      try await auth.startChallenge()
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }
}
