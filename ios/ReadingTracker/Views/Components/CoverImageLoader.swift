import SwiftUI
import UIKit

/// Chargement des couvertures avec cache mémoire (le disque passe par `URLCache.shared`).
///
/// Remplace `AsyncImage`, qui affiche un échec quand la vue disparaît pendant le chargement
/// (défilement d'une grille, transition) : ici le téléchargement continue et le résultat
/// sert au prochain affichage.
@MainActor
final class CoverImageLoader {
  static let shared = CoverImageLoader()

  private let cache = NSCache<NSURL, UIImage>()
  private var inFlight: [URL: Task<UIImage?, Never>] = [:]

  func cached(_ url: URL) -> UIImage? {
    cache.object(forKey: url as NSURL)
  }

  func image(for url: URL) async -> UIImage? {
    if let image = cached(url) { return image }
    let task = inFlight[url] ?? Task {
      // Deux essais : les serveurs de couvertures (Open Library notamment) sont parfois lents.
      for attempt in 0..<2 {
        do {
          let (data, response) = try await URLSession.shared.data(from: url)
          if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
          return UIImage(data: data)
        } catch {
          if attempt == 1 { return nil }
        }
      }
      return nil
    }
    inFlight[url] = task
    let image = await task.value
    inFlight[url] = nil
    if let image { cache.setObject(image, forKey: url as NSURL) }
    return image
  }
}

/// Image distante d'une couverture, avec le placeholder typographique en cas d'échec.
struct RemoteCover: View {
  let url: URL
  let title: String
  let author: String?

  @State private var image: UIImage?
  @State private var failed = false

  init(url: URL, title: String, author: String?) {
    self.url = url
    self.title = title
    self.author = author
    _image = State(initialValue: CoverImageLoader.shared.cached(url))
  }

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .transition(.opacity)
      } else if failed {
        CoverPlaceholder(title: title, author: author)
      } else {
        Rectangle()
          .fill(Color(.secondarySystemFill))
          .overlay {
            Image(systemName: "book.closed")
              .font(.title3)
              .foregroundStyle(.tertiary)
          }
      }
    }
    .task(id: url) {
      guard image == nil else { return }
      let loaded = await CoverImageLoader.shared.image(for: url)
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.2)) {
        image = loaded
        failed = loaded == nil
      }
    }
  }
}
