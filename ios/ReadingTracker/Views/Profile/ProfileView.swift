import SwiftUI

/// Profil : statistiques, objectif PAL, badges, réglages du jeu et de la confidentialité, déconnexion.
struct ProfileView: View {
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(SocialService.self) private var social
  @Environment(PALService.self) private var pal
  @Environment(GameService.self) private var game

  @State private var confirmSignOut = false
  @State private var selectedBadge: Badge?
  @State private var showsGoal = false
  @State private var confirmRemoveGoal = false
  @State private var errorMessage: String?

  private var name: String { auth.profile?.name ?? auth.email ?? "Mon compte" }

  var body: some View {
    NavigationStack {
      List {
        Section {
          header
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())

        Section {
          stats
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())

        goalSection

        if GameService.isEnabled(auth.profile) {
          badgesSection
        }

        gameSection

        Section {
          Toggle(isOn: privacyBinding) {
            Label("Compte privé", systemImage: "lock")
          }
          .disabled(auth.profile == nil)
        } footer: {
          Text(
            auth.profile?.isPrivate == true
              ? "Les personnes qui veulent te suivre t'envoient une demande. Seuls tes abonnés voient tes lectures."
              : "Tout le monde peut te suivre et voir tes lectures."
          )
        }

        Section {
          LabeledContent("Abonnés", value: "\(social.followersCount)")
          LabeledContent("Abonnements", value: "\(social.outgoing.values.filter { $0 == .accepted }.count)")
          if let email = auth.email {
            LabeledContent("Email", value: email)
          }
        }

        Section {
          Button("Se déconnecter", role: .destructive) {
            confirmSignOut = true
          }
          .frame(maxWidth: .infinity)
          .confirmationDialog("Se déconnecter ?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) {
              Task { await auth.signOut() }
            }
          }
        }
      }
      .listSectionSpacing(20)
      .contentMargins(.top, 0, for: .scrollContent)
      .navigationTitle("Profil")
      .navigationBarTitleDisplayMode(.inline)
      .errorAlert($errorMessage)
      .sheet(isPresented: $showsGoal) {
        PALGoalSheet(currentSize: library.toReadCount, goal: pal.goal)
      }
      .sheet(item: $selectedBadge) { badge in
        badgeSheet(badge)
      }
    }
  }

  // MARK: Jeu

  private var badgesSection: some View {
    Section {
      BadgeGrid(earned: earnedDates) { selectedBadge = $0 }
        .padding(.vertical, 12)
    } header: {
      HStack {
        Text("Badges")
        Spacer()
        Text("\(game.earned.count) sur \(Badge.allCases.count)")
          .monospacedDigit()
      }
    }
  }

  private var earnedDates: [Badge: Date] {
    game.earned.mapValues { $0.earnedDate ?? .now }
  }

  private func badgeSheet(_ badge: Badge) -> some View {
    let row = game.earned[badge]
    let state = game.state(auth: auth, library: library, pal: pal)
    return BadgeDetailSheet(
      badge: badge,
      earnedAt: row.map { $0.earnedDate ?? .now },
      bookTitle: row?.userBookId.flatMap { library.item(id: $0)?.book?.title },
      progress: state?.progress(toward: badge, palSize: library.toReadCount, goal: pal.goal)
    )
  }

  private var gameSection: some View {
    Section {
      Toggle(isOn: gameBinding) {
        Label("Jeu", systemImage: "gamecontroller")
      }
      .disabled(auth.profile?.gamificationStartedAt == nil)
    } footer: {
      Text(
        auth.profile?.gamificationEnabled == false
          ? "Jetons, série, badges et célébrations sont masqués, pour toi comme pour tes amis."
          : "Jetons d'achat, série de mois au vert, badges et célébrations. Tes amis voient tes badges."
      )
    }
  }

  private var gameBinding: Binding<Bool> {
    Binding(
      get: { auth.profile?.gamificationEnabled ?? true },
      set: { newValue in
        Task {
          do {
            try await auth.setGamificationEnabled(newValue)
          } catch {
            errorMessage = ErrorMessage.from(error)
          }
        }
      }
    )
  }

  // MARK: Objectif PAL

  @ViewBuilder
  private var goalSection: some View {
    Section {
      if let goal = pal.goal {
        let size = library.toReadCount
        let left = goal.remaining(currentSize: size)
        PALGoalProgress(
          title: "\(goal.target) livre\(goal.target > 1 ? "s" : "") visé\(goal.target > 1 ? "s" : "")",
          caption: "Ta PAL compte \(size) livre\(size > 1 ? "s" : "") · \(left == 0 ? "objectif atteint" : "encore \(left) à sortir")",
          progress: goal.progress(currentSize: size),
          titleFont: .headline
        )
        .padding(.vertical, 4)

        LabeledContent("Échéance", value: PostgresDate.long(goal.deadline) ?? "Aucune")

        Button("Modifier l'objectif", systemImage: "pencil") { showsGoal = true }
        Button("Retirer l'objectif", systemImage: "trash", role: .destructive) { confirmRemoveGoal = true }
          .confirmationDialog("Retirer ton objectif PAL ?", isPresented: $confirmRemoveGoal, titleVisibility: .visible) {
            Button("Retirer l'objectif", role: .destructive) {
              Task { await removeGoal() }
            }
          }
      } else {
        Button("Se fixer un objectif", systemImage: "target") { showsGoal = true }
          .disabled(auth.profile == nil)
      }
    } header: {
      Text("Objectif PAL")
    } footer: {
      if pal.goal == nil {
        Text("Choisis la taille de PAL que tu vises, avec ou sans échéance.")
      }
    }
  }

  private func removeGoal() async {
    do {
      guard let userId = auth.userId else { return }
      try await pal.removeGoal(userId: userId)
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }

  private var header: some View {
    VStack(spacing: 10) {
      AvatarView(name: name, url: auth.profile?.avatarUrl, size: 88)
      VStack(spacing: 2) {
        Text(name)
          .font(.title2.bold())
        if let username = auth.profile?.username {
          Text("@\(username)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 4)
  }

  private var stats: some View {
    HStack(spacing: 12) {
      StatTile(value: library.readThisYear, label: "Lus en \(String(Calendar.current.component(.year, from: .now)))", systemImage: "checkmark.circle")
      StatTile(value: library.readingCount, label: "En cours", systemImage: "book")
      StatTile(value: library.toReadCount, label: "PAL", systemImage: "books.vertical")
    }
  }

  private var privacyBinding: Binding<Bool> {
    Binding(
      get: { auth.profile?.isPrivate ?? false },
      set: { newValue in
        Task {
          do {
            try await auth.setPrivate(newValue)
          } catch {
            errorMessage = ErrorMessage.from(error)
          }
        }
      }
    )
  }
}

struct StatTile: View {
  let value: Int
  let label: String
  let systemImage: String

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.subheadline)
        .foregroundStyle(.tint)
        .frame(height: 20)
      Text("\(value)")
        .font(.title.bold())
        .monospacedDigit()
        .contentTransition(.numericText())
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 14)
    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    .accessibilityElement(children: .combine)
  }
}
