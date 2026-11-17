import SwiftUI

/// Fiche d'un livre de la bibliothèque : statut, page actuelle, note, avis, favori, suppression.
struct BookDetailView: View {
  let userBookId: UUID

  @Environment(LibraryService.self) private var library
  @Environment(\.dismiss) private var dismiss

  @State private var draft: UserBookUpdate?
  @State private var pageText = ""
  @State private var isSaving = false
  @State private var confirmDelete = false
  @State private var errorMessage: String?
  @FocusState private var focusedField: FocusField?

  enum FocusField: Hashable { case page, review }

  private var item: UserBook? { library.item(id: userBookId) }

  var body: some View {
    Group {
      if let item, let book = item.book {
        content(item: item, book: book)
      } else {
        ContentUnavailableView("Livre introuvable", systemImage: "book.closed")
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .errorAlert($errorMessage)
    .onAppear(perform: resetDraft)
  }

  private func content(item: UserBook, book: Book) -> some View {
    Form {
      Section {
        header(book: book)
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))

      if let draft = Binding($draft) {
        Section("Lecture") {
          Picker("Statut", selection: draft.status) {
            ForEach(ReadingStatus.allCases) { status in
              Label(status.singularLabel, systemImage: status.systemImage).tag(status)
            }
          }
          .pickerStyle(.menu)

          if let started = PostgresDate.long(item.startedAt) {
            LabeledContent("Commencé le", value: started)
          }
          if item.status == .read, let finished = PostgresDate.long(item.finishedAt) {
            LabeledContent("Terminé le", value: finished)
          }
        }

        if draft.wrappedValue.status == .reading || draft.wrappedValue.status == .abandoned {
          Section("Progression") {
            HStack {
              Text("Page actuelle")
              Spacer()
              TextField("0", text: $pageText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 70)
                .focused($focusedField, equals: .page)
                .onChange(of: pageText) { _, value in
                  let digits = value.filter(\.isNumber)
                  if digits != value { pageText = digits }
                  draft.wrappedValue.currentPage = Int(digits)
                }
              if let total = book.pageCount {
                Text("/ \(total)")
                  .foregroundStyle(.secondary)
                  .monospacedDigit()
              }
            }
            if let total = book.pageCount, total > 0 {
              let page = Double(draft.wrappedValue.currentPage ?? 0)
              ReadingProgressBar(progress: min(page / Double(total), 1))
                .listRowSeparator(.hidden, edges: .top)
            }
          }
        }

        Section("Ma note") {
          StarRatingPicker(rating: draft.rating)
        }

        Section("Mon avis") {
          TextField(
            "Ce que tu en as pensé…",
            text: Binding(get: { draft.wrappedValue.review ?? "" }, set: { draft.wrappedValue.review = $0 }),
            axis: .vertical
          )
          .lineLimit(4...12)
          .focused($focusedField, equals: .review)
        }

        if let description = book.description, !description.isEmpty {
          Section("Résumé") {
            Text(description)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }

        Section {
          Button("Retirer de ma bibliothèque", role: .destructive) {
            confirmDelete = true
          }
          .frame(maxWidth: .infinity)
          .confirmationDialog(
            "Retirer « \(book.title) » de ta bibliothèque ?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
          ) {
            Button("Retirer", role: .destructive) { Task { await delete() } }
          } message: {
            Text("Ta note, ton avis et ta progression seront perdus.")
          }
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          draft?.isFavorite.toggle()
        } label: {
          Image(systemName: draft?.isFavorite == true ? "heart.fill" : "heart")
            .foregroundStyle(draft?.isFavorite == true ? Color.red : Color.primary)
        }
        .accessibilityLabel(draft?.isFavorite == true ? "Retirer des favoris" : "Ajouter aux favoris")
        .sensoryFeedback(.selection, trigger: draft?.isFavorite)
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
      ToolbarItem(placement: .confirmationAction) {
        Button {
          Task { await save() }
        } label: {
          if isSaving { ProgressView() } else { Text("Enregistrer") }
        }
        .buttonStyle(.glassProminent)
        .disabled(!hasChanges || isSaving)
      }
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("OK") { focusedField = nil }
      }
    }
  }

  private func header(book: Book) -> some View {
    VStack(spacing: 14) {
      BookCover(url: book.coverURL, title: book.title, author: book.authorsLine, cornerRadius: 10)
        .frame(width: 150)
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)

      VStack(spacing: 4) {
        Text(book.title)
          .font(.title2.bold())
          .multilineTextAlignment(.center)
        if let subtitle = book.subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        Text(book.authorsLine)
          .font(.headline)
          .foregroundStyle(.tint)
          .multilineTextAlignment(.center)
        Text(metadataLine(book))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.top, 2)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
  }

  private func metadataLine(_ book: Book) -> String {
    [book.publisher, book.year, book.pageCount.map { "\($0) pages" }]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  private var hasChanges: Bool {
    guard let item, let draft else { return false }
    var normalized = draft
    if normalized.review?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { normalized.review = nil }
    return normalized != UserBookUpdate(item)
  }

  private func resetDraft() {
    guard draft == nil, let item else { return }
    draft = UserBookUpdate(item)
    pageText = item.currentPage.map(String.init) ?? ""
  }

  private func save() async {
    guard let draft else { return }
    isSaving = true
    defer { isSaving = false }
    focusedField = nil
    do {
      var update = draft
      if let total = item?.book?.pageCount, let page = update.currentPage { update.currentPage = min(page, total) }
      if update.status == .read, let total = item?.book?.pageCount { update.currentPage = total }
      let saved = try await library.save(id: userBookId, update: update)
      self.draft = UserBookUpdate(saved)
      pageText = saved.currentPage.map(String.init) ?? ""
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }

  private func delete() async {
    do {
      try await library.remove(id: userBookId)
      dismiss()
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }
}
