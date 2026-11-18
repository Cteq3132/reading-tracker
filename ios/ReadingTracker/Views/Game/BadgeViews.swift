import SwiftUI

extension Badge {
  var color: Color {
    switch self {
    case .firstExit: .teal
    case .bottomOfPile: .indigo
    case .archaeologist: .brown
    case .bigCleanup: .mint
    case .brick: .orange
    case .greenMonth: .green
    case .greenStreak3: .red
    case .halfPile: .blue
    case .goalReached: .pink
    case .tenOut: .purple
    case .pickAccepted: .cyan
    }
  }
}

/// Médaille ronde d'un badge : en couleur s'il est obtenu, grisée sinon.
struct BadgeMedal: View {
  let badge: Badge
  let earned: Bool
  var size: CGFloat = 52

  var body: some View {
    Circle()
      .fill(earned ? AnyShapeStyle(badge.color.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)))
      .overlay {
        Image(systemName: badge.systemImage)
          .font(.system(size: size * 0.42, weight: .semibold))
          .foregroundStyle(earned ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// Case de la grille des badges : médaille, nom, et date d'obtention ou règle du badge à obtenir.
struct BadgeTile: View {
  let badge: Badge
  /// `nil` = à obtenir.
  let earnedAt: Date?

  var body: some View {
    VStack(spacing: 6) {
      BadgeMedal(badge: badge, earned: earnedAt != nil)
        .padding(.bottom, 2)
      Text(badge.name)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(earnedAt == nil ? .secondary : .primary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Text(subtitle)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(3, reservesSpace: earnedAt == nil)
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(badge.name), \(earnedAt == nil ? "à obtenir : \(badge.rule)" : subtitle)")
    .accessibilityAddTraits(.isButton)
  }

  private var subtitle: String {
    guard let earnedAt else { return badge.rule }
    return "Obtenu le \(earnedAt.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))"
  }
}

/// Grille des badges. `earned` donne la date d'obtention de chaque badge obtenu ; avec `showsLocked`,
/// les badges à obtenir suivent, grisés avec leur règle.
struct BadgeGrid: View {
  let earned: [Badge: Date]
  var showsLocked = true
  let onSelect: (Badge) -> Void

  private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 12, alignment: .top)]

  private var badges: [Badge] {
    let obtained = Badge.allCases.filter { earned[$0] != nil }
    return showsLocked ? obtained + Badge.allCases.filter { earned[$0] == nil } : obtained
  }

  var body: some View {
    LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
      ForEach(badges) { badge in
        Button { onSelect(badge) } label: {
          BadgeTile(badge: badge, earnedAt: earned[badge])
        }
        .buttonStyle(.plain)
      }
    }
  }
}

/// Fiche d'un badge : médaille, règle, date d'obtention et livre déclencheur, ou progression.
struct BadgeDetailSheet: View {
  let badge: Badge
  let earnedAt: Date?
  /// Titre du livre qui a déclenché le badge, s'il est connu.
  var bookTitle: String? = nil
  /// Où l'on en est, pour un badge à obtenir.
  var progress: String? = nil
  /// Nom de l'ami à qui appartient le badge (`nil` pour le mien).
  var owner: String? = nil

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        BadgeMedal(badge: badge, earned: earnedAt != nil, size: 104)
          .padding(.top, 8)
        VStack(spacing: 6) {
          Text(badge.name)
            .font(.title2.bold())
          Text(status)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(earnedAt == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(badge.color))
        }
        VStack(spacing: 10) {
          Text(badge.rule)
            .font(.body)
            .multilineTextAlignment(.center)
          if let detail {
            Text(detail)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
        }
        .padding(.horizontal, 8)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 24)
      .frame(maxWidth: .infinity)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Fermer", systemImage: "xmark") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium])
  }

  private var status: String {
    guard let earnedAt else { return "À obtenir" }
    let day = earnedAt.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR")))
    return owner == nil ? "Obtenu le \(day)" : "Obtenu par \(owner!) le \(day)"
  }

  private var detail: String? {
    if earnedAt != nil { return bookTitle.map { "Grâce à « \($0) »" } }
    return progress
  }
}

/// Carte d'un nouveau badge, affichée par-dessus l'app au moment où il est obtenu.
struct BadgeCelebrationCard: View {
  let badge: Badge
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      BadgeMedal(badge: badge, earned: true, size: 96)
      VStack(spacing: 6) {
        Text("Nouveau badge")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(badge.color)
        Text(badge.name)
          .font(.title.bold())
        Text(badge.rule)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      Button(action: onDismiss) {
        Text("Continuer")
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)
    }
    .padding(28)
    .frame(maxWidth: 320)
    // Fond plein, comme les cartes de l'Accueil : le verre laissait passer les couleurs de l'écran sous le texte.
    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 32))
    .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
  }
}
