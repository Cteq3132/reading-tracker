import SwiftUI

/// Carte en tête de l'Accueil : taille de la PAL, bilan du mois, jeu (jetons et série), objectif et pioche.
struct PALCard: View {
  let size: Int
  let balance: PALBalance
  let goal: PALGoal?
  /// État du jeu ; `nil` quand le jeu est masqué.
  var game: GameState? = nil
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
        HStack(alignment: .firstTextBaseline) {
          Label("Ma PAL", systemImage: "books.vertical")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          if let game, game.streak > 0 {
            StreakLabel(streak: game.streak)
          }
        }
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

      if let game {
        TokenLine(state: game)
      }

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
      if let game {
        TokenLine(state: game)
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

/// Série de mois au vert, discrète, en haut à droite de la carte PAL : « 🔥 3 mois au vert ».
struct StreakLabel: View {
  let streak: Int

  var body: some View {
    Text("🔥 \(streak) mois au vert")
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .monospacedDigit()
      .lineLimit(1)
      .accessibilityLabel("Série : \(streak) mois au vert")
  }
}

/// Solde de jetons d'achat de la carte PAL. Toucher la ligne explique les règles.
private struct TokenLine: View {
  let state: GameState
  @State private var showsRules = false

  var body: some View {
    Button { showsRules = true } label: {
      HStack(spacing: 10) {
        Image(systemName: state.tokens.isOverdrawn ? "creditcard" : "bag.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(state.tokens.isOverdrawn ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 1) {
          Text(state.tokens.label)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
          if state.isInstalling(at: .now) {
            Text("Ajouts gratuits jusqu'au \(installationEnd)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 4)
        Image(systemName: "info.circle")
          .font(.footnote)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityHint("Explique les jetons")
    .popover(isPresented: $showsRules) {
      TokenRules(installationEnd: state.isInstalling(at: .now) ? installationEnd : nil)
        .presentationCompactAdaptation(.popover)
    }
  }

  private var installationEnd: String {
    state.installationEndsAt.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR")))
  }
}

/// Règles des jetons, en quelques lignes.
private struct TokenRules: View {
  let installationEnd: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Jetons d'achat")
        .font(.headline)
      rule("arrow.down.right", "Chaque livre qui sort de ta PAL rapporte ½ jeton.")
      rule("arrow.up.right", "Chaque livre qui y entre en coûte 1.")
      if let installationEnd {
        rule("gift", "Jusqu'au \(installationEnd), tes ajouts sont gratuits : saisis ta PAL tranquillement.")
      }
      rule("hand.thumbsup", "À découvert, rien n'est bloqué : c'est juste un rappel.")
    }
    .padding(18)
    .frame(width: 300, alignment: .leading)
  }

  private func rule(_ symbol: String, _ text: String) -> some View {
    Label {
      Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: symbol)
        .foregroundStyle(.tint)
        .frame(width: 24)
    }
  }
}
