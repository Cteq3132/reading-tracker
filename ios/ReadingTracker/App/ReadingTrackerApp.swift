import SwiftUI

@main
struct ReadingTrackerApp: App {
  @State private var auth = AuthService()
  @State private var library = LibraryService()
  @State private var search = BookSearchService()
  @State private var social = SocialService()
  @State private var pal = PALService()

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
        .environment(\.locale, Locale(identifier: "fr_FR"))
    }
  }
}

struct RootView: View {
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(SocialService.self) private var social
  @Environment(PALService.self) private var pal

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
      library.onStatusChange = { [pal] item, from, to in
        pal.record(userId: item.userId, userBookId: item.id, bookId: item.bookId, from: from, to: to)
      }
      await auth.start()
    }
    .onChange(of: auth.userId) { _, newValue in
      if newValue == nil {
        library.reset()
        social.reset()
        pal.reset()
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
  @State private var selection: AppTab = .home

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
    .task(id: auth.userId) {
      guard let userId = auth.userId else { return }
      await MainTabView.refreshAll(userId: userId, library: library, social: social, pal: pal)
    }
  }
}

extension MainTabView {
  /// Recharge la bibliothèque, les amis, puis l'historique de PAL (le mien et celui des amis suivis).
  static func refreshAll(userId: UUID, library: LibraryService, social: SocialService, pal: PALService) async {
    async let a: Void = library.load(userId: userId)
    async let b: Void = social.refresh(userId: userId)
    _ = await (a, b)
    await pal.load(userId: userId, friendIds: social.acceptedFollowingIds)
  }
}
