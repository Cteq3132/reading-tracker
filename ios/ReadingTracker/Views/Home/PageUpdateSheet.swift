import SwiftUI

/// Mise à jour rapide de la page actuelle, sans ouvrir la fiche.
struct PageUpdateSheet: View {
  let item: UserBook

  @Environment(LibraryService.self) private var library
  @Environment(\.dismiss) private var dismiss
  @State private var page: Int
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(item: UserBook) {
    self.item = item
    _page = State(initialValue: item.currentPage ?? 0)
  }

  private var total: Int? { item.book?.pageCount.flatMap { $0 > 0 ? $0 : nil } }

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        HStack(spacing: 14) {
          stepButton(-1, systemImage: "minus")

          VStack(spacing: 2) {
            TextField("0", value: $page, format: .number)
              .keyboardType(.numberPad)
              .multilineTextAlignment(.center)
              .font(.system(size: 44, weight: .bold, design: .rounded))
              .monospacedDigit()
              .frame(width: 140)
            Text(total.map { "sur \($0) pages" } ?? "page actuelle")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }

          stepButton(1, systemImage: "plus")
        }

        if let total {
          ReadingProgressBar(progress: min(Double(page) / Double(total), 1))
            .padding(.horizontal, 8)
        }

        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 10) {
            ForEach([10, 25, 50], id: \.self) { step in
              Button("+\(step)") { change(by: step) }
                .buttonStyle(.glass)
            }
          }
        }
      }
      .padding(.horizontal, 24)
      .padding(.top, 8)
      .frame(maxHeight: .infinity, alignment: .top)
      .navigationTitle(item.book?.title ?? "Page")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Fermer", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await save() }
          } label: {
            if isSaving { ProgressView() } else { Text("Enregistrer") }
          }
          .buttonStyle(.glassProminent)
          .disabled(isSaving || page == (item.currentPage ?? 0))
        }
      }
      .sensoryFeedback(.selection, trigger: page)
      .errorAlert($errorMessage)
    }
    .presentationDetents([.height(total == nil ? 290 : 320)])
  }

  private func stepButton(_ delta: Int, systemImage: String) -> some View {
    Button {
      change(by: delta)
    } label: {
      Image(systemName: systemImage)
        .font(.title3.weight(.semibold))
        .frame(width: 32, height: 32)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .buttonRepeatBehavior(.enabled)
  }

  private func change(by delta: Int) {
    var next = max(page + delta, 0)
    if let total { next = min(next, total) }
    page = next
  }

  private func save() async {
    isSaving = true
    defer { isSaving = false }
    var update = UserBookUpdate(item)
    update.currentPage = total.map { min(page, $0) } ?? page
    do {
      try await library.save(id: item.id, update: update)
      dismiss()
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }
}

/// Choix d'un livre de la PAL à commencer. La date de début vaut aujourd'hui par défaut et se
/// change dans la première ligne, avant de toucher « Commencer » : un seul geste dans le cas courant.
struct StartReadingSheet: View {
  @Environment(LibraryService.self) private var library
  @Environment(\.dismiss) private var dismiss
  @State private var startDate = Date.now
  @State private var startingId: UUID?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      List {
        Section {
          DatePicker("Commencé le", selection: $startDate, in: ...Date.now, displayedComponents: .date)
            .environment(\.locale, Locale(identifier: "fr_FR"))
        } footer: {
          Text("Aujourd'hui par défaut. Change la date si tu as commencé plus tôt.")
        }

        Section("Pile à lire") {
          ForEach(library.items(with: .toRead)) { item in
            Button {
              Task { await start(item) }
            } label: {
              row(item)
            }
            .disabled(startingId != nil)
          }
        }
      }
      .navigationTitle("Commencer une lecture")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Fermer", systemImage: "xmark") { dismiss() }
        }
      }
      .errorAlert($errorMessage)
    }
    .presentationDetents([.medium, .large])
  }

  private func row(_ item: UserBook) -> some View {
    HStack(spacing: 14) {
      BookCover(url: item.book?.coverURL, title: item.book?.title ?? "", author: item.book?.authorsLine, cornerRadius: 5)
        .frame(width: 44)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.book?.title ?? "Sans titre")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Color.primary)
        Text(item.book?.authorsLine ?? "")
          .font(.caption)
          .foregroundStyle(Color.secondary)
      }
      Spacer(minLength: 8)
      if startingId == item.id {
        ProgressView()
      } else {
        Text("Commencer")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(Color.accentColor)
      }
    }
  }

  private func start(_ item: UserBook) async {
    startingId = item.id
    defer { startingId = nil }
    var update = UserBookUpdate(item)
    update.setStatus(.reading, from: item, today: PostgresDate.today())
    update.startedAt = PostgresDate.day(from: startDate)
    do {
      try await library.save(id: item.id, update: update)
      dismiss()
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }
}
