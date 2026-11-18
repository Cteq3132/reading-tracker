import SwiftUI

/// Profil d'un autre compte : ses badges, si son jeu est affiché et que le backend les rend lisibles
/// (profil public ou suivi), et son activité récente.
struct FriendProfileView: View {
  let profile: Profile

  @Environment(AuthService.self) private var auth
  @Environment(SocialService.self) private var social
  @Environment(GameService.self) private var game

  @State private var badges: [UserBadge] = []
  @State private var badgesLoaded = false
  @State private var selectedBadge: Badge?

  /// Le jeu est affiché chez moi comme chez lui : sinon, rien du jeu n'apparaît.
  private var showsGame: Bool { GameService.isEnabled(auth.profile) && profile.gamificationEnabled }

  private var activity: [FriendActivity] { social.activity.filter { $0.userId == profile.id } }

  private var earned: [Badge: Date] {
    var result: [Badge: Date] = [:]
    for row in badges {
      if let badge = row.badge { result[badge] = row.earnedDate ?? .now }
    }
    return result
  }

  var body: some View {
    List {
      Section {
        header
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())

      if showsGame {
        Section {
          if !badgesLoaded {
            ProgressView()
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
          } else if earned.isEmpty {
            Text("Pas encore de badge.")
              .foregroundStyle(.secondary)
          } else {
            BadgeGrid(earned: earned, showsLocked: false) { selectedBadge = $0 }
              .padding(.vertical, 12)
          }
        } header: {
          HStack {
            Text("Badges")
            Spacer()
            if badgesLoaded, !earned.isEmpty {
              Text("\(earned.count) sur \(Badge.allCases.count)")
                .monospacedDigit()
            }
          }
        }
      }

      if !activity.isEmpty {
        Section("Activité récente") {
          ForEach(activity) { item in
            ActivityRow(activity: item)
          }
        }
      }
    }
    .listSectionSpacing(20)
    .contentMargins(.top, 0, for: .scrollContent)
    .navigationTitle(profile.name)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: showsGame) { await loadBadges() }
    .sheet(item: $selectedBadge) { badge in
      BadgeDetailSheet(badge: badge, earnedAt: earned[badge], owner: profile.name)
    }
  }

  private var header: some View {
    VStack(spacing: 10) {
      AvatarView(name: profile.name, url: profile.avatarUrl, size: 80)
      VStack(spacing: 2) {
        Text(profile.name)
          .font(.title2.bold())
        HStack(spacing: 4) {
          Text("@\(profile.username)")
          if profile.isPrivate {
            Image(systemName: "lock.fill")
              .font(.caption2)
              .accessibilityLabel("Compte privé")
          }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
    .padding(.bottom, 4)
  }

  /// Une erreur ou un refus de la RLS donne une liste vide : « Pas encore de badge ».
  private func loadBadges() async {
    guard showsGame, !badgesLoaded else { return }
    badges = (try? await game.badges(of: profile.id)) ?? []
    badgesLoaded = true
  }
}
