import SwiftUI

struct AuthView: View {
  @Environment(AuthService.self) private var auth

  enum Mode: String, CaseIterable, Identifiable {
    case signIn = "Connexion"
    case signUp = "Inscription"
    var id: String { rawValue }
  }

  enum Field: Hashable { case email, password, username }

  @State private var mode: Mode = .signIn
  @State private var email = ""
  @State private var password = ""
  @State private var username = ""
  @State private var isWorking = false
  @State private var errorMessage: String?
  @FocusState private var focus: Field?

  private var usernameIsValid: Bool { AuthService.isValidUsername(username) }

  private var canSubmit: Bool {
    let base = email.contains("@") && password.count >= 6
    return mode == .signIn ? base : base && usernameIsValid
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 32) {
        header
          .padding(.top, 56)

        Picker("Mode", selection: $mode) {
          ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)

        GlassEffectContainer(spacing: 12) {
          VStack(spacing: 12) {
            if mode == .signUp {
              field(icon: "at", focus: .username) {
                TextField("Nom d'utilisateur", text: $username)
                  .textContentType(.username)
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
                  .onChange(of: username) { _, value in
                    let cleaned = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                    if cleaned != value { username = String(cleaned.prefix(30)) }
                  }
                  .focused($focus, equals: .username)
                  .submitLabel(.next)
                  .onSubmit { focus = .email }
              }
            }
            field(icon: "envelope", focus: .email) {
              TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .email)
                .submitLabel(.next)
                .onSubmit { focus = .password }
            }
            field(icon: "lock", focus: .password) {
              SecureField("Mot de passe", text: $password)
                .textContentType(mode == .signIn ? .password : .newPassword)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit { Task { await submit() } }
            }
          }
        }

        if mode == .signUp {
          Text(usernameHint)
            .font(.footnote)
            .foregroundStyle(!username.isEmpty && !usernameIsValid ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, -20)
        }

        Button {
          Task { await submit() }
        } label: {
          Group {
            if isWorking {
              ProgressView()
            } else {
              Text(mode == .signIn ? "Se connecter" : "Créer mon compte")
                .fontWeight(.semibold)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(!canSubmit || isWorking)
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 32)
      .animation(.snappy, value: mode)
    }
    .scrollDismissesKeyboard(.interactively)
    .contentShape(.rect)
    .onTapGesture { focus = nil }
    .background(backdrop)
    .errorAlert($errorMessage)
  }

  private var header: some View {
    VStack(spacing: 14) {
      Image(systemName: "books.vertical.fill")
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(.tint)
        .frame(width: 88, height: 88)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
      Text("reading-tracker")
        .font(.largeTitle.bold())
      Text("Ta pile à lire, tes lectures en cours\net celles de tes amis.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }

  private var usernameHint: String {
    if !username.isEmpty && !usernameIsValid {
      return "3 à 30 caractères : lettres minuscules, chiffres ou _."
    }
    return "Visible par tes amis. Lettres minuscules, chiffres ou _."
  }

  private var backdrop: some View {
    LinearGradient(
      colors: [Color.accentColor.opacity(0.22), Color(.systemBackground), Color(.systemBackground)],
      startPoint: .top, endPoint: .bottom
    )
    .ignoresSafeArea()
  }

  private func field(icon: String, focus field: Field, @ViewBuilder content: () -> some View) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      content()
    }
    .padding(.horizontal, 18)
    .frame(height: 52)
    .glassEffect(.regular.interactive(), in: .capsule)
    .contentShape(.capsule)
    .onTapGesture { focus = field }
  }

  private func submit() async {
    guard canSubmit, !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    let cleanEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
    do {
      switch mode {
      case .signIn: try await auth.signIn(email: cleanEmail, password: password)
      case .signUp: try await auth.signUp(email: cleanEmail, password: password, username: username)
      }
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }
}

#Preview {
  AuthView().environment(AuthService())
}
