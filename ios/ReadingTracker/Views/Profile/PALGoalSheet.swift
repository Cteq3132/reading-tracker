import SwiftUI

/// Fixer ou modifier l'objectif PAL : taille visée et échéance facultative.
struct PALGoalSheet: View {
  let currentSize: Int
  let goal: PALGoal?

  @Environment(AuthService.self) private var auth
  @Environment(\.dismiss) private var dismiss
  @State private var target: Int
  @State private var hasDeadline: Bool
  @State private var deadline: Date
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(currentSize: Int, goal: PALGoal?) {
    self.currentSize = currentSize
    self.goal = goal
    _target = State(initialValue: goal?.target ?? max(currentSize - 5, 0))
    let saved = goal?.deadline.flatMap { PostgresDate.date(fromDay: $0) }
    _hasDeadline = State(initialValue: goal == nil || saved != nil)
    _deadline = State(initialValue: saved ?? Self.endOfYear)
  }

  /// 31 décembre de l'année en cours, ou de la suivante passé la mi-décembre.
  private static var endOfYear: Date {
    let calendar = PostgresDate.localCalendar
    let now = Date.now
    var year = calendar.component(.year, from: now)
    if calendar.component(.month, from: now) == 12, calendar.component(.day, from: now) > 15 { year += 1 }
    return PostgresDate.date(fromDay: "\(year)-12-31") ?? now
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Stepper(value: $target, in: 0...999) {
            LabeledContent("Taille visée") {
              Text("\(target) livre\(target > 1 ? "s" : "")")
                .monospacedDigit()
                .contentTransition(.numericText())
            }
          }
        } footer: {
          Text(sizeHint)
        }

        Section {
          Toggle("Échéance", isOn: $hasDeadline.animation())
          if hasDeadline {
            DatePicker("D'ici le", selection: $deadline, in: Date.now..., displayedComponents: .date)
          }
        } footer: {
          Text("Facultative. Sans échéance, l'objectif reste ouvert.")
        }
      }
      .navigationTitle(goal == nil ? "Objectif PAL" : "Modifier l'objectif")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Fermer", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await save() }
          } label: {
            if isSaving { ProgressView() } else { Text("Enregistrer") }
          }
          .buttonStyle(.glassProminent)
          .disabled(isSaving)
        }
      }
      .sensoryFeedback(.selection, trigger: target)
      .errorAlert($errorMessage)
    }
    .presentationDetents([.medium])
  }

  private var sizeHint: String {
    let now = "Ta PAL compte \(currentSize) livre\(currentSize > 1 ? "s" : "") aujourd'hui."
    let gap = currentSize - target
    if gap <= 0 { return "\(now) Tu es déjà à cette taille." }
    return "\(now) Il te reste \(gap) livre\(gap > 1 ? "s" : "") à sortir."
  }

  private func save() async {
    isSaving = true
    defer { isSaving = false }
    do {
      try await auth.setPALGoal(
        target: target,
        deadline: hasDeadline ? PostgresDate.day(from: deadline) : nil,
        currentSize: currentSize
      )
      dismiss()
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }
}
