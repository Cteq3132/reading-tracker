import SwiftUI

/// Menu du choix de statut à l'ajout d'un livre (PAL, Envies, En cours, Lu), avec la taille
/// de la PAL rappelée sous le choix « PAL ». Partagé par la liste de résultats et la page de détail.
struct AddStatusMenu<MenuLabel: View>: View {
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

  /// Sous-titre du choix : précision du statut, et pour la PAL, sa taille actuelle.
  private func hint(for status: ReadingStatus) -> String {
    guard status == .toRead, existingStatus != .toRead else { return status.addHint }
    return "Je l'ai · ta PAL compte \(palSize) livre\(palSize > 1 ? "s" : "")"
  }
}
