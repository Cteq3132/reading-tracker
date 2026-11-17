import SwiftUI

/// Fil d'activité des comptes suivis, et demandes d'abonnement reçues.
struct FriendsView: View {
  @Environment(AuthService.self) private var auth
  @Environment(SocialService.self) private var social
  @State private var showsFind = false

  var body: some View {
    @Bindable var social = social
    NavigationStack {
      List {
        if !social.incoming.isEmpty {
          Section("Demandes reçues") {
            ForEach(social.incoming) { request in
              RequestRow(request: request) { accepted in
                Task { await respond(to: request, accept: accepted) }
              }
            }
          }
        }

        if !social.activity.isEmpty {
          Section("Activité") {
            ForEach(social.activity) { activity in
              ActivityRow(activity: activity)
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .overlay {
        if !social.hasLoaded {
          ProgressView()
        } else if social.activity.isEmpty && social.incoming.isEmpty {
          ContentUnavailableView {
            Label("Pas encore d'activité", systemImage: "person.2")
          } description: {
            Text("Suis des amis pour voir ce qu'ils lisent.")
          } actions: {
            Button("Trouver des amis") { showsFind = true }
              .buttonStyle(.glassProminent)
          }
        }
      }
      .navigationTitle("Amis")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showsFind = true
          } label: {
            Label("Trouver des amis", systemImage: "person.badge.plus")
          }
        }
      }
      .refreshable {
        if let userId = auth.userId { await social.refresh(userId: userId) }
      }
      .sheet(isPresented: $showsFind) {
        FindFriendsView()
      }
      .errorAlert($social.errorMessage)
    }
  }

  private func respond(to request: FollowRequest, accept: Bool) async {
    do {
      if accept {
        try await social.accept(request)
      } else {
        try await social.decline(request)
      }
    } catch {
      social.errorMessage = ErrorMessage.from(error)
    }
  }
}

private struct RequestRow: View {
  let request: FollowRequest
  let onRespond: (Bool) -> Void

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(name: request.profile.name, url: request.profile.avatarUrl, size: 40)
      VStack(alignment: .leading, spacing: 1) {
        Text(request.profile.name)
          .font(.subheadline.weight(.semibold))
        Text("@\(request.profile.username)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      GlassEffectContainer(spacing: 2) {
        HStack(spacing: 8) {
          Button {
            onRespond(false)
          } label: {
            Image(systemName: "xmark")
              .frame(width: 18, height: 18)
          }
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .accessibilityLabel("Refuser")

          Button {
            onRespond(true)
          } label: {
            Text("Accepter").fixedSize()
          }
          .buttonStyle(.glassProminent)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

struct ActivityRow: View {
  let activity: FriendActivity

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(name: activity.name, url: activity.avatarUrl, size: 36)

      VStack(alignment: .leading, spacing: 4) {
        Text("\(Text(activity.name).fontWeight(.semibold)) \(activity.verb)")
          .font(.subheadline)
        Text(activity.title)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.tint)
          .lineLimit(2)
        if !activity.authors.isEmpty {
          Text(activity.authors.joined(separator: ", "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        detail
        if let time = PostgresDate.relative(activity.updatedAt) {
          Text(time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      BookCover(url: activity.coverURL, title: activity.title, author: activity.authors.first, cornerRadius: 4)
        .frame(width: 46)
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var detail: some View {
    switch activity.status {
    case .reading:
      if let page = activity.currentPage, let total = activity.pageCount, total > 0 {
        HStack(spacing: 8) {
          ReadingProgressBar(progress: min(Double(page) / Double(total), 1))
            .frame(maxWidth: 120)
          Text("p. \(page) / \(total)")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
    case .read:
      if let rating = activity.rating {
        StarsView(rating: rating)
      }
    case .toRead, .abandoned:
      EmptyView()
    }
  }
}
