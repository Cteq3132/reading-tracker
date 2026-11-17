import SwiftUI

/// Filtres de la bibliothèque. Le dernier regroupe les livres sortis sans être finis.
enum LibraryFilter: String, CaseIterable, Identifiable {
  case reading, toRead, wishlist, read, closed

  var id: String { rawValue }

  /// Libellé du segment. « Abandonnés et libérés » ne tient pas dans cinq segments : le dernier
  /// s'appelle « Libérés » et sa grille sépare les deux statuts en sections.
  var label: String {
    switch self {
    case .reading: "En cours"
    case .toRead: "PAL"
    case .wishlist: "Envies"
    case .read: "Lus"
    case .closed: "Libérés"
    }
  }

  var statuses: [ReadingStatus] {
    switch self {
    case .reading: [.reading]
    case .toRead: [.toRead]
    case .wishlist: [.wishlist]
    case .read: [.read]
    case .closed: [.released, .abandoned]
    }
  }

  var systemImage: String {
    switch self {
    case .closed: ReadingStatus.released.systemImage
    default: statuses[0].systemImage
    }
  }
}

struct LibraryView: View {
  @Binding var selectedTab: AppTab
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @State private var filter: LibraryFilter = .reading
  @AppStorage("pal-order") private var palOrder: PALOrder = .oldest
  @State private var releasing: UserBook?
  @State private var actionError: String?
  @Namespace private var zoom

  private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 16, alignment: .top)]

  var body: some View {
    @Bindable var library = library
    NavigationStack {
      ScrollView {
        if filter.statuses.allSatisfy({ library.items(with: $0).isEmpty }) {
          emptyState
            .padding(.top, 80)
        } else {
          content
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
      }
      .safeAreaBar(edge: .top) {
        Picker("Filtre", selection: $filter) {
          ForEach(LibraryFilter.allCases) { filter in
            Text(filter.label).tag(filter)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
      }
      .navigationTitle("Bibliothèque")
      .toolbar {
        if filter == .toRead {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Picker("Trier par", selection: $palOrder) {
                Label("Ancienneté", systemImage: "clock").tag(PALOrder.oldest)
                Label("Nombre de pages", systemImage: "book.pages").tag(PALOrder.shortest)
              }
            } label: {
              Label("Trier", systemImage: "arrow.up.arrow.down")
            }
          }
        }
      }
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
      // Une alerte plutôt qu'un menu de confirmation : en iOS 26, ce dernier s'affiche en bulle
      // ancrée au centre de la grille, qui semblerait désigner un autre livre.
      .alert(
        "Libérer « \(releasing?.book?.title ?? "ce livre") » ?",
        isPresented: Binding(get: { releasing != nil }, set: { if !$0 { releasing = nil } }),
        presenting: releasing
      ) { item in
        Button("Annuler", role: .cancel) {}
        Button("Libérer") { Task { await change(item, to: .released) } }
      } message: { _ in
        Text("Il sort de ta PAL sans avoir été lu : donné, vendu ou plus envie. Tu le retrouveras dans Libérés.")
      }
      .errorAlert($library.errorMessage)
      .errorAlert($actionError)
    }
  }

  // MARK: Grilles

  @ViewBuilder
  private var content: some View {
    switch filter {
    case .toRead:
      let items = palOrder.sorted(library.items(with: .toRead))
      VStack(alignment: .leading, spacing: 12) {
        Text("\(items.count) livre\(items.count > 1 ? "s" : ""), \(palOrder == .oldest ? "les plus anciens" : "les plus courts") d'abord")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        grid(items)
      }
    case .closed:
      VStack(alignment: .leading, spacing: 28) {
        ForEach(filter.statuses, id: \.self) { status in
          // Le dernier sorti d'abord.
          let items = library.items(with: status).sorted { (PostgresDate.parse($0.statusChangedAt) ?? .distantPast) > (PostgresDate.parse($1.statusChangedAt) ?? .distantPast) }
          if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Text(status.label)
                .font(.title3.bold())
              grid(items)
            }
          }
        }
      }
    default:
      grid(library.items(with: filter.statuses[0]))
    }
  }

  private func grid(_ items: [UserBook]) -> some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
      ForEach(items) { item in
        VStack(alignment: .leading, spacing: 10) {
          NavigationLink(value: item.id) {
            LibraryCard(item: item)
              .matchedTransitionSource(id: item.id, in: zoom)
          }
          .buttonStyle(.plain)

          if item.status == .wishlist {
            Button {
              Task { await change(item, to: .toRead) }
            } label: {
              Label("Je l'ai", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
          }
        }
        .contextMenu { menu(for: item) }
      }
    }
  }

  @ViewBuilder
  private func menu(for item: UserBook) -> some View {
    switch item.status {
    case .toRead:
      Button("Commencer", systemImage: ReadingStatus.reading.systemImage) {
        Task { await change(item, to: .reading) }
      }
      Button("Libérer…", systemImage: ReadingStatus.released.systemImage) { releasing = item }
    case .wishlist:
      Button("Je l'ai", systemImage: "checkmark") { Task { await change(item, to: .toRead) } }
    default:
      EmptyView()
    }
  }

  /// Change le statut depuis la grille, avec les dates que proposerait la fiche (début aujourd'hui).
  private func change(_ item: UserBook, to status: ReadingStatus) async {
    var update = UserBookUpdate(item)
    update.setStatus(status, from: item, today: PostgresDate.today())
    do {
      try await library.save(id: item.id, update: update)
    } catch {
      actionError = ErrorMessage.from(error)
    }
  }

  // MARK: État vide

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
    case .wishlist: "Aucune envie pour l'instant"
    case .read: "Aucun livre lu"
    case .closed: "Aucun livre libéré ni abandonné"
    }
  }

  private var emptyMessage: String {
    switch filter {
    case .reading: "Commence un livre de ta PAL ou ajoutes-en un nouveau."
    case .toRead: "Ajoute ici les livres que tu possèdes sans les avoir encore lus."
    case .wishlist: "Note les livres qui te tentent, sans les acheter tout de suite."
    case .read: "Les livres terminés apparaîtront ici."
    case .closed: "Les livres donnés, vendus ou abandonnés apparaîtront ici."
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
    case .toRead:
      VStack(alignment: .leading, spacing: 2) {
        if let since = item.palSince {
          Text(PALAge.label(since: since))
            .fontWeight(.medium)
        }
        if let pages = item.book?.pageCount {
          Text("\(pages) pages")
        }
      }
      .lineLimit(1)
      .minimumScaleFactor(0.85)
      .font(.caption2)
      .monospacedDigit()
      .foregroundStyle(.secondary)
    case .wishlist, .abandoned, .released:
      EmptyView()
    }
  }

  private var pagesLabel: String {
    let page = item.currentPage ?? 0
    if let total = item.book?.pageCount { return "p. \(page) / \(total)" }
    return page > 0 ? "p. \(page)" : "Pas commencé"
  }
}
