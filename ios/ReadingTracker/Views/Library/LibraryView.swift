import SwiftUI

struct LibraryView: View {
  @Binding var selectedTab: AppTab
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @State private var filter: ReadingStatus = .reading
  @Namespace private var zoom

  private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 16, alignment: .top)]

  var body: some View {
    @Bindable var library = library
    NavigationStack {
      ScrollView {
        let items = library.items(with: filter)
        if items.isEmpty {
          emptyState
            .padding(.top, 80)
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(items) { item in
              NavigationLink(value: item.id) {
                LibraryCard(item: item)
                  .matchedTransitionSource(id: item.id, in: zoom)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 20)
          .padding(.top, 8)
          .padding(.bottom, 24)
        }
      }
      .safeAreaBar(edge: .top) {
        Picker("Statut", selection: $filter) {
          ForEach(ReadingStatus.allCases) { status in
            Text(status.label).tag(status)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
      }
      .navigationTitle("Bibliothèque")
      .navigationDestination(for: UserBook.ID.self) { id in
        BookDetailView(userBookId: id)
          .navigationTransition(.zoom(sourceID: id, in: zoom))
      }
      .refreshable {
        if let userId = auth.userId { await library.load(userId: userId) }
      }
      .overlay {
        if !library.hasLoaded {
          ProgressView()
        }
      }
      .errorAlert($library.errorMessage)
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    if library.hasLoaded {
      ContentUnavailableView {
        Label(emptyTitle, systemImage: filter.systemImage)
      } description: {
        Text(emptyMessage)
      } actions: {
        Button("Ajouter un livre") { selectedTab = .add }
          .buttonStyle(.glassProminent)
      }
    }
  }

  private var emptyTitle: String {
    switch filter {
    case .reading: "Aucune lecture en cours"
    case .toRead: "Ta PAL est vide"
    case .read: "Aucun livre lu"
    case .abandoned: "Aucun livre abandonné"
    }
  }

  private var emptyMessage: String {
    switch filter {
    case .reading: "Commence un livre de ta PAL ou ajoutes-en un nouveau."
    case .toRead: "Cherche un titre ou scanne un code-barres pour remplir ta pile à lire."
    case .read: "Les livres terminés apparaîtront ici."
    case .abandoned: "Tant mieux."
    }
  }
}

/// Carte de la grille : couverture, titre, auteur, et progression pour les lectures en cours.
struct LibraryCard: View {
  let item: UserBook

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      BookCover(url: item.book?.coverURL, title: item.book?.title ?? "", author: item.book?.authorsLine)
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        .overlay(alignment: .topTrailing) {
          if item.isFavorite {
            Image(systemName: "heart.fill")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.white)
              .padding(5)
              .background(.red.gradient, in: .circle)
              .padding(6)
              .accessibilityLabel("Favori")
          }
        }

      // Hauteur constante (titre sur 2 lignes + auteur) pour que les barres de progression s'alignent,
      // sans espace vide entre un titre court et son auteur.
      ZStack(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: "A\nA").font(.subheadline.weight(.semibold))
          Text(verbatim: "A").font(.caption)
        }
        .hidden()
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(item.book?.title ?? "Sans titre")
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
          Text(item.book?.authorsLine ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      footer
    }
    .contentShape(.rect)
  }

  @ViewBuilder
  private var footer: some View {
    switch item.status {
    case .reading:
      VStack(alignment: .leading, spacing: 4) {
        if let progress = item.progress {
          ReadingProgressBar(progress: progress)
        }
        Text(pagesLabel)
          .font(.caption2)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    case .read:
      if let rating = item.rating {
        StarsView(rating: rating)
      }
    case .toRead, .abandoned:
      EmptyView()
    }
  }

  private var pagesLabel: String {
    let page = item.currentPage ?? 0
    if let total = item.book?.pageCount { return "p. \(page) / \(total)" }
    return page > 0 ? "p. \(page)" : "Pas commencé"
  }
}
