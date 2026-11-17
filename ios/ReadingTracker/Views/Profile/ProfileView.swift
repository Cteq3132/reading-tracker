import SwiftUI

/// Profil : statistiques, confidentialité du compte, déconnexion.
struct ProfileView: View {
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(SocialService.self) private var social

  @State private var confirmSignOut = false
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

private struct StatTile: View {
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
