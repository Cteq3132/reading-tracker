import SwiftUI

/// Accueil : carte PAL (taille, bilan du mois, objectif, pioche), lectures en cours et dernières
/// activités des amis, dont leurs progrès de PAL.
struct HomeView: View {
  @Binding var selectedTab: AppTab
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(SocialService.self) private var social
  @Environment(PALService.self) private var pal

  @State private var pageUpdate: UserBook?
  @State private var showsDraw = false
  @State private var showsGoal = false

  var body: some View {
    @Bindable var pal = pal
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 32) {
          header
          palSection
          readingSection
          friendsSection
        }
        .padding(.top, 8)
        .padding(.bottom, 32)
      }
      .background(Color(.systemGroupedBackground))
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            selectedTab = .add
          } label: {
            Label("Ajouter", systemImage: "plus")
          }
        }
      }
      .navigationDestination(for: UserBook.ID.self) { id in
        BookDetailView(userBookId: id)
      }
      .refreshable {
        guard let userId = auth.userId else { return }
        await MainTabView.refreshAll(userId: userId, library: library, social: social, pal: pal)
      }
      .sheet(item: $pageUpdate) { item in
        PageUpdateSheet(item: item)
      }
      .sheet(isPresented: $showsDraw) {
        DrawSheet()
      }
      .sheet(isPresented: $showsGoal) {
        PALGoalSheet(currentSize: library.toReadCount, goal: pal.goal)
      }
      .errorAlert($pal.errorMessage)
    }
  }

  // MARK: En-tête

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR"))))
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
      Text(greeting)
        .font(.largeTitle.bold())
        .lineLimit(2)
        .minimumScaleFactor(0.8)
    }
    .padding(.horizontal, 20)
  }

  private var greeting: String {
    let hour = Calendar.current.component(.hour, from: .now)
    let hello = (5..<18).contains(hour) ? "Bonjour" : "Bonsoir"
    guard let profile = auth.profile else { return hello }
    return "\(hello) \(profile.name)"
  }

  // MARK: PAL

  @ViewBuilder
  private var palSection: some View {
    if library.hasLoaded {
      PALCard(
        size: library.toReadCount,
        balance: pal.monthBalance(),
        goal: pal.goal,
        onDraw: { showsDraw = true },
        onSetGoal: { showsGoal = true },
        onAdd: { selectedTab = .add }
      )
      .padding(.horizontal, 20)
      .animation(.snappy, value: library.toReadCount)
    }
  }

  // MARK: Lectures en cours

  @ViewBuilder
  private var readingSection: some View {
    let reading = library.currentlyReading
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader(title: "En cours", count: reading.isEmpty ? nil : reading.count)

      if !library.hasLoaded {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 160)
      } else if reading.isEmpty {
        emptyReading
          .padding(.horizontal, 20)
      } else if reading.count == 1, let item = reading.first {
        ReadingCard(item: item) { pageUpdate = item }
          .padding(.horizontal, 20)
      } else {
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 12) {
            ForEach(reading) { item in
              ReadingCard(item: item, minHeight: 200) { pageUpdate = item }
                .containerRelativeFrame(.horizontal) { width, _ in width - 56 }
            }
          }
          .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
      }
    }
  }

  private var emptyReading: some View {
    VStack(spacing: 14) {
      Image(systemName: "book")
        .font(.system(size: 34))
        .foregroundStyle(.tint)
      VStack(spacing: 4) {
        Text("Aucune lecture en cours")
          .font(.headline)
        Text(
          library.toReadCount > 0
            ? "Commence un livre de ta PAL ou ajoutes-en un nouveau."
            : "Ajoute un livre pour commencer à suivre ta lecture."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 10) {
          if library.toReadCount > 0 {
            Button("Piocher dans ma PAL") { showsDraw = true }
              .buttonStyle(.glassProminent)
          }
          Button("Ajouter un livre") { selectedTab = .add }
            .buttonStyle(.glass)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .padding(.horizontal, 16)
    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
  }

  // MARK: Amis

  private var friendsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        SectionHeader(title: "Chez les amis")
        Spacer()
        Button("Tout voir") { selectedTab = .friends }
          .font(.subheadline.weight(.medium))
          .padding(.trailing, 20)
      }

      // Trois lignes au plus, dont les progrès de PAL des amis.
      let palMoves = friendPALMoves
      let recent = Array(social.activity.prefix(3 - palMoves.count))
      Group {
        if recent.isEmpty && palMoves.isEmpty {
          HStack(spacing: 12) {
            Image(systemName: "person.2")
              .foregroundStyle(.tint)
            Text("Suis des amis pour voir ce qu'ils lisent.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Spacer(minLength: 0)
          }
          .padding(16)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(palMoves.enumerated()), id: \.element.profile.id) { index, move in
              if index > 0 {
                Divider().padding(.leading, 64)
              }
              FriendPALRow(profile: move.profile, balance: move.balance)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            ForEach(Array(recent.enumerated()), id: \.element.id) { index, activity in
              if index > 0 || !palMoves.isEmpty {
                Divider().padding(.leading, 64)
              }
              ActivityRow(activity: activity)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
          }
          .padding(.vertical, 4)
        }
      }
      .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
      .padding(.horizontal, 20)
    }
  }
}

/// Progrès de PAL d'un ami suivi sur le mois.
private struct FriendPALMove {
  let profile: Profile
  let balance: PALBalance
}

extension HomeView {
  /// Amis suivis dont la PAL a baissé ce mois-ci, la plus forte baisse d'abord (deux au plus).
  fileprivate var friendPALMoves: [FriendPALMove] {
    let profiles = Dictionary(social.followingProfiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var moves: [FriendPALMove] = []
    for (id, balance) in pal.friendBalances() where balance.net < 0 {
      if let profile = profiles[id] { moves.append(FriendPALMove(profile: profile, balance: balance)) }
    }
    moves.sort { a, b in
      a.balance.net == b.balance.net ? a.profile.name < b.profile.name : a.balance.net < b.balance.net
    }
    return Array(moves.prefix(2))
  }
}

/// Progrès de PAL d'un ami ce mois-ci : « Léa a fait baisser sa PAL · 5 sorties ce mois   −4 ».
private struct FriendPALRow: View {
  let profile: Profile
  let balance: PALBalance

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(name: profile.name, url: profile.avatarUrl, size: 36)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(Text(profile.name).fontWeight(.semibold)) a fait baisser sa PAL")
          .font(.subheadline)
        Text("\(balance.exits) sortie\(balance.exits > 1 ? "s" : "") ce mois")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(PALBalance.signed(balance.net))
        .font(.title3.bold())
        .monospacedDigit()
        .foregroundStyle(.green)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

private struct SectionHeader: View {
  let title: String
  var count: Int? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title)
        .font(.title3.bold())
      if let count {
        Text("\(count)")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .padding(.horizontal, 20)
  }
}

/// Carte d'une lecture en cours : couverture, progression et bouton de mise à jour de page.
private struct ReadingCard: View {
  let item: UserBook
  /// Hauteur commune quand plusieurs cartes défilent, pour qu'elles restent alignées.
  var minHeight: CGFloat? = nil
  let onUpdatePage: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      NavigationLink(value: item.id) {
        BookCover(url: item.book?.coverURL, title: item.book?.title ?? "", author: item.book?.authorsLine, cornerRadius: 8)
          .frame(width: 84)
          .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
      }
      .buttonStyle(.plain)

      VStack(alignment: .leading, spacing: 10) {
        NavigationLink(value: item.id) {
          VStack(alignment: .leading, spacing: 3) {
            Text(item.book?.title ?? "Sans titre")
              .font(.headline)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
            Text(item.book?.authorsLine ?? "")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)

        Spacer(minLength: 0)

        VStack(alignment: .leading, spacing: 6) {
          if let total = item.book?.pageCount, total > 0 {
            ReadingProgressBar(progress: item.progress ?? 0)
          }
          Text(progressLabel)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }

        Button(action: onUpdatePage) {
          Label("Mettre à jour", systemImage: "bookmark")
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
  }

  private var progressLabel: String {
    let page = item.currentPage ?? 0
    if let total = item.book?.pageCount, total > 0 {
      let percent = Int((Double(page) / Double(total) * 100).rounded())
      return "Page \(page) sur \(total) · \(min(percent, 100)) %"
    }
    return page > 0 ? "Page \(page)" : "Pas encore commencé"
  }
}
