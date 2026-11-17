import SwiftUI

/// Avatar rond : image si `avatar_url`, sinon initiales sur fond teinté.
struct AvatarView: View {
  let name: String
  var url: String? = nil
  var size: CGFloat = 40

  private var initials: String {
    let parts = name.split(whereSeparator: { $0 == " " || $0 == "_" }).prefix(2)
    let letters = parts.compactMap(\.first).map { String($0).uppercased() }
    return letters.isEmpty ? "?" : letters.joined()
  }

  var body: some View {
    Group {
      if let url, let parsed = URL(string: url) {
        AsyncImage(url: parsed) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          fallback
        }
      } else {
        fallback
      }
    }
    .frame(width: size, height: size)
    .clipShape(.circle)
    .accessibilityHidden(true)
  }

  private var fallback: some View {
    Circle()
      .fill(Color.accentColor.gradient)
      .overlay {
        Text(initials)
          .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
          .foregroundStyle(.white)
      }
  }
}

/// Étoiles de 1 à 5, en lecture seule.
struct StarsView: View {
  let rating: Int
  var size: CGFloat = 11

  var body: some View {
    HStack(spacing: 1) {
      ForEach(1...5, id: \.self) { index in
        Image(systemName: index <= rating ? "star.fill" : "star")
          .font(.system(size: size))
          .foregroundStyle(index <= rating ? Color.orange : Color.secondary.opacity(0.4))
      }
    }
    .accessibilityElement()
    .accessibilityLabel(Text("\(rating) sur 5"))
  }
}

/// Note modifiable : toucher une étoile la sélectionne, toucher la même l'efface.
struct StarRatingPicker: View {
  @Binding var rating: Int?

  var body: some View {
    HStack(spacing: 6) {
      ForEach(1...5, id: \.self) { index in
        Button {
          rating = rating == index ? nil : index
        } label: {
          Image(systemName: index <= (rating ?? 0) ? "star.fill" : "star")
            .font(.title2)
            .foregroundStyle(index <= (rating ?? 0) ? Color.orange : Color.secondary.opacity(0.5))
            .frame(width: 36, height: 36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(index) étoile\(index > 1 ? "s" : "")"))
      }
    }
    .sensoryFeedback(.selection, trigger: rating)
  }
}

/// Barre de progression fine, utilisée sous les couvertures « en cours ».
struct ReadingProgressBar: View {
  let progress: Double

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule()
          .fill(Color.accentColor)
          .frame(width: max(proxy.size.width * progress, 4))
      }
    }
    .frame(height: 4)
    .accessibilityElement()
    .accessibilityLabel(Text("Progression \(Int(progress * 100)) %"))
  }
}

extension View {
  /// Alerte d'erreur liée à un message optionnel.
  func errorAlert(_ message: Binding<String?>) -> some View {
    alert(
      "Erreur",
      isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } }),
      actions: { Button("OK", role: .cancel) {} },
      message: { Text(message.wrappedValue ?? "") }
    )
  }
}
