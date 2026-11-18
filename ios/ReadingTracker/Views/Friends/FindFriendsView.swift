import SwiftUI

/// Recherche de comptes par nom d'utilisateur, suivre / ne plus suivre.
struct FindFriendsView: View {
  @Environment(AuthService.self) private var auth
  @Environment(SocialService.self) private var social
  @Environment(\.dismiss) private var dismiss

  @State private var query = ""
  @State private var results: [Profile] = []
  @State private var isSearching = false
  @State private var busy: Set<UUID> = []
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      List {
        if query.isEmpty {
          if !social.followingProfiles.isEmpty {
            Section("Abonnements") {
              ForEach(social.followingProfiles) { profile in
                row(profile)
              }
            }
          }
        } else {
          ForEach(results) { profile in
            row(profile)
          }
        }
      }
      .overlay {
        if !query.isEmpty && results.isEmpty && !isSearching {
          ContentUnavailableView.search(text: query)
        } else if query.isEmpty && social.followingProfiles.isEmpty {
          ContentUnavailableView(
            "Cherche un ami",
            systemImage: "magnifyingglass",
            description: Text("Tape son nom d'utilisateur pour le trouver.")
          )
        }
      }
      .navigationTitle("Trouver des amis")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(
        text: $query,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Nom d'utilisateur"
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .task(id: query) { await runSearch() }
      .navigationDestination(for: Profile.self) { profile in
        FriendProfileView(profile: profile)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Fermer", systemImage: "xmark") { dismiss() }
        }
      }
      .errorAlert($errorMessage)
    }
  }

  private func row(_ profile: Profile) -> some View {
    HStack(spacing: 12) {
      NavigationLink(value: profile) {
        identity(profile)
      }
      followButton(profile)
    }
    .padding(.vertical, 2)
  }

  private func identity(_ profile: Profile) -> some View {
    HStack(spacing: 12) {
      AvatarView(name: profile.name, url: profile.avatarUrl, size: 40)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          Text(profile.name)
            .font(.subheadline.weight(.semibold))
          if profile.isPrivate {
            Image(systemName: "lock.fill")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Compte privé")
          }
        }
        Text("@\(profile.username)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
    }
  }

  @ViewBuilder
  private func followButton(_ profile: Profile) -> some View {
    let status = social.outgoing[profile.id]
    let isBusy = busy.contains(profile.id)
    switch status {
    case .none:
      Button {
        Task { await toggle(profile, follow: true) }
      } label: {
        Text("Suivre").frame(minWidth: 72)
      }
      .buttonStyle(.glassProminent)
      .disabled(isBusy)
    case .some(let status):
      Menu {
        Button(status == .pending ? "Annuler la demande" : "Ne plus suivre", role: .destructive) {
          Task { await toggle(profile, follow: false) }
        }
      } label: {
        Text(status == .pending ? "Demandé" : "Abonné").frame(minWidth: 72)
      }
      .buttonStyle(.glass)
      .disabled(isBusy)
    }
  }

  private func runSearch() async {
    guard let userId = auth.userId, !query.isEmpty else {
      results = []
      return
    }
    try? await Task.sleep(for: .milliseconds(250))
    guard !Task.isCancelled else { return }
    isSearching = true
    defer { isSearching = false }
    do {
      results = try await social.searchProfiles(query, excluding: userId)
    } catch is CancellationError {
    } catch {
      if !Task.isCancelled { errorMessage = ErrorMessage.from(error) }
    }
  }

  private func toggle(_ profile: Profile, follow: Bool) async {
    guard let userId = auth.userId else { return }
    busy.insert(profile.id)
    defer { busy.remove(profile.id) }
    do {
      if follow {
        try await social.follow(profile, userId: userId)
      } else {
        try await social.unfollow(profile.id, userId: userId)
      }
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }
}
