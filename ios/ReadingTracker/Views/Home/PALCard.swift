import SwiftUI

/// Carte en tête de l'Accueil : taille de la PAL, bilan du mois, objectif et pioche.
struct PALCard: View {
  let size: Int
  let balance: PALBalance
  let goal: PALGoal?
  let onDraw: () -> Void
  let onSetGoal: () -> Void
  let onAdd: () -> Void

  var body: some View {
    Group {
      if size == 0 {
        empty
      } else {
        filled
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
  }

  // MARK: PAL non vide

  private var filled: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Label("Ma PAL", systemImage: "books.vertical")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("\(size)")
            .font(.system(size: 52, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
          Text(size > 1 ? "livres à lire" : "livre à lire")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        balanceLine
      }
      .accessibilityElement(children: .combine)

      if let goal {
        PALGoalProgress(
          title: PALGoalText.title(goal),
          caption: PALGoalText.remaining(goal, currentSize: size),
          progress: goal.progress(currentSize: size)
        )
      } else {
        Button(action: onSetGoal) {
          Label("Se fixer un objectif", systemImage: "target")
            .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.borderless)
      }

      Button(action: onDraw) {
        Label("Piocher dans ma PAL", systemImage: "dice")
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)
    }
  }

  /// « +2 · −5 · −3 ce mois » : entrées, sorties, solde. En vert quand la PAL baisse.
  @ViewBuilder
  private var balanceLine: some View {
    if balance.isEmpty {
      Text("Aucun mouvement ce mois")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else {
      HStack(spacing: 5) {
        Image(systemName: balance.net < 0 ? "arrow.down.right" : balance.net > 0 ? "arrow.up.right" : "equal")
          .font(.footnote.weight(.bold))
        Text("\(balance.compactLabel) ce mois")
          .monospacedDigit()
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(balance.net < 0 ? Color.green : Color.secondary)
      .accessibilityLabel("Ce mois : \(balance.accessibilityLabel)")
    }
  }

  // MARK: PAL vide

  private var empty: some View {
    VStack(spacing: 14) {
      Image(systemName: "sparkles")
        .font(.system(size: 34))
        .foregroundStyle(.tint)
      VStack(spacing: 4) {
        Text("Ta PAL est vide")
          .font(.headline)
        Text(
          balance.exits > 0
            ? "Tu as sorti \(balance.exits) livre\(balance.exits > 1 ? "s" : "") de ta pile ce mois\u{2011}ci. Bravo !"
            : "Ajoute les livres que tu possèdes sans les avoir lus : Unshelf t'aide à les sortir de la pile."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }
      Button("Ajouter un livre", action: onAdd)
        .buttonStyle(.glassProminent)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 4)
  }
}

/// Progression de l'objectif PAL : titre, pourcentage, barre et légende. Partagée par l'Accueil et le Profil.
struct PALGoalProgress: View {
  let title: String
  let caption: String
  let progress: Double
  var titleFont: Font = .subheadline.weight(.medium)

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(titleFont)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Spacer(minLength: 8)
        Text("\(Int((progress * 100).rounded())) %")
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(.tint)
      }
      ReadingProgressBar(progress: progress)
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Textes de l'objectif PAL, partagés par l'Accueil et le Profil.
enum PALGoalText {
  /// « Objectif : 8 livres d'ici le 31 déc. » ou « Objectif : 8 livres ».
  static func title(_ goal: PALGoal) -> String {
    let books = "\(goal.target) livre\(goal.target > 1 ? "s" : "")"
    guard let deadline = goal.deadline.flatMap({ PostgresDate.date(fromDay: $0) }) else { return "Objectif : \(books)" }
    let day = deadline.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
    return "Objectif : \(books) d'ici le \(day)"
  }

  static func remaining(_ goal: PALGoal, currentSize: Int) -> String {
    let left = goal.remaining(currentSize: currentSize)
    if left == 0 { return "Objectif atteint, bravo !" }
    return "Encore \(left) livre\(left > 1 ? "s" : "") à sortir de ta PAL"
  }
}
