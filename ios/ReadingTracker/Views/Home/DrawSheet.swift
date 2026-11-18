import SwiftUI

/// « Piocher dans ma PAL » : propose un livre de la PAL (au hasard, le plus ancien ou le plus court),
/// à commencer tout de suite ou à remplacer par un autre.
struct DrawSheet: View {
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(GameService.self) private var game
  @Environment(\.dismiss) private var dismiss

  @State private var mode: PALDrawMode = .random
  /// Ordre de passage des suggestions pour le mode choisi ; « Autre » avance d'un cran.
  @State private var order: [UUID] = []
  @State private var index = 0
  @State private var startDate = Date.now
  @State private var isStarting = false
  @State private var errorMessage: String?

  /// Suggestions encore dans la PAL, dans l'ordre du mode.
  private var suggestions: [UserBook] {
    order.compactMap { library.item(id: $0) }.filter { $0.status == .toRead }
  }

  private var current: UserBook? {
    let list = suggestions
    return list.isEmpty ? nil : list[index % list.count]
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Picker("Mode", selection: $mode) {
          ForEach(PALDrawMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        if let item = current {
          Spacer(minLength: 0)
          suggestion(item)
            .id(item.id)
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
          Spacer(minLength: 0)
          actions(item)
        } else {
          ContentUnavailableView("Ta PAL est vide", systemImage: "sparkles", description: Text("Rien à piocher pour l'instant."))
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 16)
      .frame(maxHeight: .infinity, alignment: .top)
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Piocher dans ma PAL")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Fermer", systemImage: "xmark") { dismiss() }
        }
      }
      .onAppear { if order.isEmpty { reorder() } }
      .onChange(of: mode) { withAnimation(.snappy) { reorder() } }
      .sensoryFeedback(.selection, trigger: current?.id)
      // Chaque livre proposé est mémorisé localement : le commencer sous 7 jours vaut le badge « Coup de dé ».
      .onChange(of: current?.id, initial: true) { _, id in
        if let id, let userId = auth.userId { game.recordPick(userBookId: id, userId: userId) }
      }
      .errorAlert($errorMessage)
    }
  }

  private func suggestion(_ item: UserBook) -> some View {
    VStack(spacing: 14) {
      BookCover(url: item.book?.coverURL, title: item.book?.title ?? "", author: item.book?.authorsLine, cornerRadius: 10)
        .frame(width: 170)
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
      VStack(spacing: 4) {
        Text(item.book?.title ?? "Sans titre")
          .font(.title2.bold())
          .multilineTextAlignment(.center)
          .lineLimit(2)
        Text(item.book?.authorsLine ?? "")
          .font(.headline)
          .foregroundStyle(.tint)
          .lineLimit(1)
        Text(details(item))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.top, 2)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func details(_ item: UserBook) -> String {
    let age = item.palSince.map { "Dans ta PAL \(PALAge.label(since: $0))" }
    let pages = item.book?.pageCount.map { "\($0) pages" }
    return [age, pages].compactMap { $0 }.joined(separator: " · ")
  }

  private func actions(_ item: UserBook) -> some View {
    VStack(spacing: 16) {
      DatePicker("Commencé le", selection: $startDate, in: ...Date.now, displayedComponents: .date)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))

      GlassEffectContainer(spacing: 10) {
        HStack(spacing: 12) {
          Button {
            withAnimation(.snappy) { index += 1 }
          } label: {
            Label("Autre", systemImage: "arrow.triangle.2.circlepath")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.glass)
          .disabled(suggestions.count < 2 || isStarting)

          Button {
            Task { await start(item) }
          } label: {
            Group {
              if isStarting { ProgressView() } else { Label("Commencer", systemImage: "book") }
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.glassProminent)
          .disabled(isStarting)
        }
        .controlSize(.large)
        .font(.headline)
      }
    }
  }

  private func reorder() {
    order = mode.order(library.items(with: .toRead)).map(\.id)
    index = 0
  }

  private func start(_ item: UserBook) async {
    isStarting = true
    defer { isStarting = false }
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
