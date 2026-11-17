import SwiftUI

/// Page de détail d'un résultat de recherche, ouverte par un zoom depuis sa couverture : grande
/// couverture sur fond flouté, métadonnées, résumé, et ajout avec le choix du statut. Si le livre
/// est déjà dans la bibliothèque, affiche son statut et un lien vers sa fiche à la place.
struct CandidateDetailView: View {
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(BookSearchService.self) private var search

  /// Le candidat, complété au besoin par une recherche par ISBN à l'ouverture.
  @State private var candidate: BookCandidate
  @State private var completion: Task<Void, Never>?
  @State private var isCompleting = false
  @State private var isAdding = false
  /// Ajouté depuis cette page (pour dire « Ajouté à l'instant » plutôt que « Déjà dans… »).
  @State private var addedHere = false
  @State private var errorMessage: String?
  @State private var showsNavigationTitle = false

  init(candidate: BookCandidate) {
    _candidate = State(initialValue: candidate)
  }

  private var existing: UserBook? { library.existing(for: candidate) }

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        header
        primaryAction
        if !facts.isEmpty { FactsStrip(facts: facts) }
        summary
        information
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 32)
    }
    .background(alignment: .top) { backdrop }
    .onScrollGeometryChange(for: Bool.self) { geometry in
      geometry.contentOffset.y + geometry.contentInsets.top > 300
    } action: { _, isPastHeader in
      showsNavigationTitle = isPastHeader
    }
    .navigationTitle(showsNavigationTitle ? candidate.title : "")
    .navigationBarTitleDisplayMode(.inline)
    .errorAlert($errorMessage)
    .sensoryFeedback(.success, trigger: existing?.status) { old, new in old == nil && new != nil }
    .onAppear(perform: completeIfNeeded)
  }

  // MARK: En-tête

  private var header: some View {
    VStack(spacing: 18) {
      BookCover(url: candidate.coverURL, title: candidate.title, author: candidate.authorsLine, cornerRadius: 10)
        .frame(width: 180)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

      VStack(spacing: 6) {
        Text(candidate.title)
          .font(.title2.bold())
        if let subtitle = candidate.subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if !candidate.authors.isEmpty {
          Text(candidate.authorsLine)
            .font(.headline)
            .foregroundStyle(.tint)
        }
      }
      .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 12)
  }

  /// Fond flouté tiré de la couverture, qui se fond dans l'arrière-plan sous l'en-tête.
  private var backdrop: some View {
    Group {
      if let url = candidate.coverURL {
        RemoteCover(url: url, title: candidate.title, author: candidate.authorsLine)
      } else {
        CoverPlaceholder(title: candidate.title, author: candidate.authorsLine)
      }
    }
    .frame(height: 460)
    .frame(maxWidth: .infinity)
    .clipped()
    .blur(radius: 60, opaque: true)
    .opacity(0.55)
    .mask {
      LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
    }
    .ignoresSafeArea(edges: .top)
    .accessibilityHidden(true)
  }

  // MARK: Action principale

  @ViewBuilder
  private var primaryAction: some View {
    Group {
      if let existing {
        ExistingStatusCard(item: existing, addedHere: addedHere)
      } else {
        AddStatusMenu(existingStatus: nil, palSize: library.toReadCount) { status in
          Task { await add(status) }
        } label: {
          HStack(spacing: 8) {
            if isAdding {
              ProgressView()
            } else {
              Image(systemName: "plus")
            }
            Text("Ajouter")
          }
          .font(.headline)
          .frame(maxWidth: 220)
          .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(isAdding)
      }
    }
    .animation(.snappy, value: existing?.status)
  }

  private func add(_ status: ReadingStatus) async {
    guard let userId = auth.userId else { return }
    isAdding = true
    defer { isAdding = false }
    do {
      // Le candidat complété : `upsert_book` enregistre alors le résumé et les autres champs trouvés.
      try await library.add(candidate, status: status, userId: userId)
      addedHere = true
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }

  // MARK: Résumé

  @ViewBuilder
  private var summary: some View {
    if let description = candidate.description?.trimmingCharacters(in: .whitespacesAndNewlines),
       !description.isEmpty {
      DetailSection(title: "Résumé") {
        ExpandableText(text: description, collapsedLineLimit: 6)
      }
      .transition(.opacity)
    } else if isCompleting {
      DetailSection(title: "Résumé") {
        Text(String(repeating: "Résumé du livre en cours de chargement. ", count: 4))
          .font(.callout)
          .redacted(reason: .placeholder)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Chargement du résumé")
      }
    }
  }

  // MARK: Informations

  private var facts: [FactsStrip.Fact] {
    var facts: [FactsStrip.Fact] = []
    if let pages = candidate.pageCount {
      facts.append(.init(caption: "Longueur", value: "\(pages)", detail: "pages"))
    }
    if let year = candidate.year {
      facts.append(.init(caption: "Parution", value: year, detail: candidate.publisher ?? ""))
    }
    if let code = candidate.language, !code.isEmpty {
      facts.append(.init(caption: "Langue", value: code.uppercased(), detail: Self.languageName(code) ?? ""))
    }
    return facts
  }

  @ViewBuilder
  private var information: some View {
    let rows: [(String, String)] = [
      ("Éditeur", candidate.publisher),
      ("Parution", Self.formattedDate(candidate.publishedDate)),
      ("Pages", candidate.pageCount.map { "\($0)" }),
      ("Langue", candidate.language.flatMap { Self.languageName($0) ?? $0 }),
      ("ISBN-13", candidate.isbn13),
      ("ISBN-10", candidate.isbn10),
    ].compactMap { label, value in
      guard let value, !value.isEmpty else { return nil }
      return (label, value)
    }
    if !rows.isEmpty {
      DetailSection(title: "Informations") {
        VStack(spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            if index > 0 { Divider() }
            LabeledContent(row.0) {
              Text(row.1)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            }
            .font(.subheadline)
            .padding(.vertical, 11)
          }
        }
      }
    }
  }

  static func languageName(_ code: String) -> String? {
    let french = Locale(identifier: "fr_FR")
    return french.localizedString(forLanguageCode: code)?.capitalized(with: french)
  }

  /// « 1985-03-12 » → « 12 mars 1985 », « 2021-03 » → « mars 2021 », une année seule telle quelle.
  static func formattedDate(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let french = Locale(identifier: "fr_FR")
    if raw.count >= 10, let date = PostgresDate.date(fromDay: String(raw.prefix(10))) {
      return date.formatted(.dateTime.day().month(.wide).year().locale(french))
    }
    if raw.count == 7, let date = PostgresDate.date(fromDay: raw + "-01") {
      return date.formatted(.dateTime.month(.wide).year().locale(french))
    }
    return raw
  }

  // MARK: Complément par ISBN

  /// Si des champs manquent et que le candidat a un ISBN-13, une recherche par ISBN (servie par
  /// le cache du backend le plus souvent) les complète, sans bloquer l'affichage. Un seul appel par
  /// ouverture de la page : la tâche n'est pas annulée quand une autre page passe par-dessus.
  /// Un échec, une limite de débit (429) compris, laisse la page telle quelle, sans alerte.
  private func completeIfNeeded() {
    guard completion == nil, candidate.isMissingDetails, let isbn = candidate.isbn13 else { return }
    isCompleting = true
    completion = Task {
      defer { isCompleting = false }
      guard let results = try? await search.search(isbn: isbn),
            let match = results.first(where: { $0.isbn13 == isbn })
      else { return }
      withAnimation(.smooth) { candidate = candidate.completed(with: match) }
    }
  }
}

// MARK: - Composants

/// Titre de section et son contenu, alignés à gauche, comme les fiches de l'App Store.
private struct DetailSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.title3.bold())
        .accessibilityAddTraits(.isHeader)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Bandeau de chiffres clés (pages, parution, langue), séparés par des filets.
private struct FactsStrip: View {
  struct Fact: Hashable {
    let caption: String
    let value: String
    let detail: String
  }

  let facts: [Fact]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(facts.enumerated()), id: \.element) { index, fact in
        if index > 0 {
          Divider().frame(height: 40)
        }
        VStack(spacing: 4) {
          Text(fact.caption.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(fact.value)
            .font(.title3.bold())
            .monospacedDigit()
          Text(fact.detail.isEmpty ? " " : fact.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.vertical, 14)
    .glassEffect(.regular, in: .rect(cornerRadius: 22))
  }
}

/// Statut du livre déjà dans la bibliothèque, avec le lien vers sa fiche.
private struct ExistingStatusCard: View {
  let item: UserBook
  let addedHere: Bool

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: item.status.systemImage)
        .font(.title3.weight(.semibold))
        .foregroundStyle(.tint)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.phrase(item.status))
          .font(.headline)
        Text(addedHere ? "Ajouté à l'instant" : "Déjà dans ta bibliothèque")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      NavigationLink(value: item.id) {
        Text("Voir ma fiche")
          .font(.subheadline.weight(.semibold))
      }
      .buttonStyle(.glass)
    }
    .padding(.leading, 18)
    .padding(.trailing, 12)
    .padding(.vertical, 12)
    .glassEffect(.regular, in: .rect(cornerRadius: 22))
    .accessibilityElement(children: .contain)
  }

  static func phrase(_ status: ReadingStatus) -> String {
    switch status {
    case .toRead: "Dans ta PAL"
    case .wishlist: "Dans tes envies"
    case .reading: "En cours de lecture"
    case .read: "Lu"
    case .abandoned: "Abandonné"
    case .released: "Libéré"
    }
  }
}

/// Texte replié à `collapsedLineLimit` lignes, avec « Plus » / « Moins » seulement s'il dépasse.
private struct ExpandableText: View {
  let text: String
  let collapsedLineLimit: Int

  @State private var isExpanded = false
  @State private var fullHeight: CGFloat = 0
  @State private var shownHeight: CGFloat = 0

  private var isTruncated: Bool { fullHeight > shownHeight + 1 }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(isExpanded ? nil : collapsedLineLimit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
        .background(alignment: .top) {
          // Hauteur du texte entier, pour savoir s'il est coupé.
          Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
        }

      if isTruncated || isExpanded {
        Button(isExpanded ? "Moins" : "Plus") {
          withAnimation(.smooth) { isExpanded.toggle() }
        }
        .font(.callout.weight(.semibold))
        .buttonStyle(.borderless)
      }
    }
  }
}
