import SwiftUI

/// Couverture au format 2:3. Sans `cover_url` (ou si l'image ne charge pas), affiche une
/// couverture typographique colorée à partir du titre.
struct BookCover: View {
  let url: URL?
  let title: String
  var author: String? = nil
  var cornerRadius: CGFloat = 8

  var body: some View {
    Color.clear
      .aspectRatio(2.0 / 3.0, contentMode: .fit)
      .overlay {
        if let url {
          AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
              image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
              CoverPlaceholder(title: title, author: author)
            default:
              Rectangle()
                .fill(Color(.secondarySystemFill))
                .overlay {
                  Image(systemName: "book.closed")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                }
            }
          }
        } else {
          CoverPlaceholder(title: title, author: author)
        }
      }
      .clipShape(.rect(cornerRadius: cornerRadius))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius)
          .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
      }
      .accessibilityLabel(Text("Couverture de \(title)"))
  }
}

struct CoverPlaceholder: View {
  let title: String
  var author: String? = nil

  private static let palettes: [(Color, Color)] = [
    (Color(red: 0.84, green: 0.42, blue: 0.24), Color(red: 0.62, green: 0.25, blue: 0.16)),
    (Color(red: 0.25, green: 0.44, blue: 0.62), Color(red: 0.14, green: 0.27, blue: 0.43)),
    (Color(red: 0.31, green: 0.55, blue: 0.43), Color(red: 0.17, green: 0.36, blue: 0.29)),
    (Color(red: 0.55, green: 0.38, blue: 0.62), Color(red: 0.36, green: 0.22, blue: 0.44)),
    (Color(red: 0.78, green: 0.62, blue: 0.29), Color(red: 0.56, green: 0.42, blue: 0.16)),
    (Color(red: 0.44, green: 0.47, blue: 0.53), Color(red: 0.27, green: 0.29, blue: 0.34)),
  ]

  private var palette: (Color, Color) {
    // Hash stable (le `hashValue` de Swift change à chaque lancement).
    let sum = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return Self.palettes[sum % Self.palettes.count]
  }

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack {
        LinearGradient(colors: [palette.0, palette.1], startPoint: .top, endPoint: .bottom)
        VStack(spacing: width * 0.06) {
          Rectangle()
            .fill(.white.opacity(0.5))
            .frame(width: width * 0.25, height: 1)
          Text(title)
            .font(.system(size: max(width * 0.12, 9), weight: .semibold, design: .serif))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.6)
          if let author, !author.isEmpty {
            Text(author)
              .font(.system(size: max(width * 0.075, 7), weight: .regular))
              .opacity(0.85)
              .lineLimit(2)
              .multilineTextAlignment(.center)
          }
          Rectangle()
            .fill(.white.opacity(0.5))
            .frame(width: width * 0.25, height: 1)
        }
        .foregroundStyle(.white)
        .padding(width * 0.1)
      }
    }
  }
}

#Preview {
  HStack {
    BookCover(url: nil, title: "Le Mage du Kremlin", author: "Giuliano da Empoli")
    BookCover(url: nil, title: "Sapiens", author: "Yuval Noah Harari")
  }
  .frame(width: 260)
  .padding()
}
