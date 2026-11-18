import SwiftUI

@main
struct ReadingTrackerApp: App {
  @State private var auth = AuthService()
  @State private var library = LibraryService()
  @State private var search = BookSearchService()
  @State private var social = SocialService()
  @State private var pal = PALService()
  @State private var game = GameService()

  init() {
    // Les couvertures passent par AsyncImage (URLSession.shared) : un cache disque évite de les recharger à chaque écran.
    URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(auth)
        .environment(library)
        .environment(search)
        .environment(social)
        .environment(pal)
        .environment(game)
        .environment(\.locale, Locale(identifier: "fr_FR"))
    }
  }
}

struct RootView: View {
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(SocialService.self) private var social
  @Environment(PALService.self) private var pal
  @Environment(GameService.self) private var game

  var body: some View {
    Group {
      switch auth.phase {
      case .loading:
        ProgressView()
          .controlSize(.large)
      case .signedOut:
        AuthView()
          .transition(.opacity)
      case .signedIn:
        MainTabView()
          .transition(.opacity)
      }
    }
    .animation(.default, value: auth.phase)
    .task {
      library.onStatusChange = { [pal, game, auth, library] item, from, to in
        pal.record(userId: item.userId, userBookId: item.id, bookId: item.bookId, from: from, to: to)
        game.statusDidChange(from: from, to: to, auth: auth, library: library, pal: pal)
      }
      await auth.start()
    }
    .onChange(of: auth.userId) { _, newValue in
      if newValue == nil {
        library.reset()
        social.reset()
        pal.reset()
        game.reset()
      }
    }
  }
}

enum AppTab: Hashable {
  case home, library, friends, profile, add
}

struct MainTabView: View {
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(SocialService.self) private var social
  @Environment(PALService.self) private var pal
  @Environment(GameService.self) private var game
  @State private var selection: AppTab = AppConfig.demoQuery == nil ? .home : .add

  var body: some View {
    TabView(selection: $selection) {
      Tab("Accueil", systemImage: "house", value: .home) {
        HomeView(selectedTab: $selection)
      }
      Tab("Bibliothèque", systemImage: "books.vertical", value: .library) {
        LibraryView(selectedTab: $selection)
      }
      Tab("Amis", systemImage: "person.2", value: .friends) {
        FriendsView()
      }
      .badge(social.incoming.count)
      Tab("Profil", systemImage: "person.crop.circle", value: .profile) {
        ProfileView()
      }
      // Onglet de recherche iOS 26 : affiché à part dans la tab bar Liquid Glass.
      Tab("Ajouter", systemImage: "magnifyingglass", value: .add, role: .search) {
        AddBookView()
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    .celebrations()
    .task(id: auth.userId) {
      guard let userId = auth.userId else { return }
      await MainTabView.refreshAll(userId: userId, auth: auth, library: library, social: social, pal: pal, game: game)
      if let badge = AppConfig.demoCelebrate { game.showDemoCelebration(badge) }
    }
    // Un objectif modifié ou le jeu réactivé peuvent faire obtenir un badge.
    .onChange(of: pal.goal) { reevaluate() }
    .onChange(of: auth.profile?.gamificationEnabled) { reevaluate() }
  }

  private func reevaluate() {
    Task { await game.evaluate(auth: auth, library: library, pal: pal) }
  }
}

extension MainTabView {
  /// Recharge la bibliothèque, les amis, les badges, puis l'historique de PAL (le mien et celui des amis
  /// suivis), et attribue les badges obtenus depuis le dernier calcul.
  static func refreshAll(
    userId: UUID, auth: AuthService, library: LibraryService, social: SocialService, pal: PALService, game: GameService
  ) async {
    async let a: Void = library.load(userId: userId)
    async let b: Void = social.refresh(userId: userId)
    async let c: Void = game.loadBadges(userId: userId)
    _ = await (a, b, c)
    await pal.load(userId: userId, friendIds: social.acceptedFollowingIds)
    await game.evaluate(auth: auth, library: library, pal: pal)
  }
}
