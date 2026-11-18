import SwiftUI

/// Menu du choix de statut à l'ajout d'un livre (PAL, Envies, En cours, Lu), avec la taille
/// de la PAL rappelée sous le choix « PAL ». Partagé par la liste de résultats et la page de détail.
struct AddStatusMenu<MenuLabel: View>: View {
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(PALService.self) private var pal
  @Environment(GameService.self) private var game

  let existingStatus: ReadingStatus?
  /// Taille actuelle de la PAL, rappelée discrètement sous le choix « PAL ».
  let palSize: Int
  let onSelect: (ReadingStatus) -> Void
  @ViewBuilder let label: () -> MenuLabel

  var body: some View {
    Menu {
      Section(existingStatus == nil ? "Ajouter à" : "Déplacer vers") {
        ForEach(ReadingStatus.addChoices) { status in
          Button {
            onSelect(status)
          } label: {
            Image(systemName: status.systemImage)
            Text(status.singularLabel)
            Text(hint(for: status))
          }
          .disabled(status == existingStatus)
        }
      }
    } label: {
      label()
    }
  }

  /// Sous-titre du choix : précision du statut, et pour la PAL, sa taille actuelle et le solde de jetons.
  private func hint(for status: ReadingStatus) -> String {
    guard status == .toRead, existingStatus != .toRead else { return status.addHint }
    let size = "Je l'ai · ta PAL compte \(palSize) livre\(palSize > 1 ? "s" : "")"
    guard let reminder = tokenReminder else { return size }
    return "\(size) · \(reminder)"
  }

  /// Rappel du solde de jetons, si le jeu est affiché : « 2 jetons », « à découvert », ou un ajout gratuit
  /// pendant la période d'installation.
  private var tokenReminder: String? {
    guard let state = game.state(auth: auth, library: library, pal: pal) else { return nil }
    if state.isInstalling(at: .now) { return "ajout gratuit" }
    return state.tokens.shortLabel
  }
}
