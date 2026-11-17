import SwiftUI

@main
struct ReadingTrackerApp: App {
  @State private var auth = AuthService()
  @State private var library = LibraryService()
  @State private var search = BookSearchService()
  @State private var social = SocialService()

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
        .environment(\.locale, Locale(identifier: "fr_FR"))
    }
  }
}

struct RootView: View {
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(SocialService.self) private var social

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
    .task { await auth.start() }
    .onChange(of: auth.userId) { _, newValue in
      if newValue == nil {
        library.reset()
        social.reset()
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
      async let a: Void = library.load(userId: userId)
      async let b: Void = social.refresh(userId: userId)
      _ = await (a, b)
    }
  }
}
