import SwiftUI

/// Confettis légers qui tombent du haut de l'écran pendant un peu plus de deux secondes à chaque
/// changement de `trigger`. Rien n'est dessiné quand « Réduire les animations » est activé.
struct ConfettiView: View {
  let trigger: Int

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var start: Date?
  @State private var pieces: [Piece] = []

  private static let duration: TimeInterval = 2.4
  private static let gravity: Double = 520

  var body: some View {
    TimelineView(.animation(paused: start == nil)) { context in
      Canvas { canvas, size in
        guard let start else { return }
        let t = context.date.timeIntervalSince(start)
        guard t < Self.duration else { return }
        let fade = min(max((Self.duration - t) / 0.6, 0), 1)
        for piece in pieces {
          let x = piece.x * size.width + piece.drift * t + sin(t * piece.wobble) * 12
          let y = -24 + piece.speed * t + 0.5 * Self.gravity * t * t
          guard y < size.height + 24 else { continue }
          var layer = canvas
          layer.translateBy(x: x, y: y)
          layer.rotate(by: .radians(piece.spin * t))
          // Le battement de la largeur donne l'impression d'un papier qui tourne sur lui-même.
          layer.scaleBy(x: cos(t * piece.flip), y: 1)
          let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
          layer.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(piece.color.opacity(fade)))
        }
      }
    }
    .allowsHitTesting(false)
    .ignoresSafeArea()
    .accessibilityHidden(true)
    .onChange(of: trigger) {
      guard !reduceMotion else { return }
      pieces = (0..<60).map { _ in Piece.random() }
      let started = Date.now
      start = started
      Task {
        try? await Task.sleep(for: .seconds(Self.duration))
        if start == started { start = nil }
      }
    }
  }

  private struct Piece {
    var x: Double
    var drift: Double
    var speed: Double
    var spin: Double
    var flip: Double
    var wobble: Double
    var width: Double
    var height: Double
    var color: Color

    static let palette: [Color] = [.pink, .orange, .yellow, .green, .teal, .blue, .purple]

    static func random() -> Piece {
      Piece(
        x: .random(in: 0...1), drift: .random(in: -40...40), speed: .random(in: 40...220),
        spin: .random(in: -6...6), flip: .random(in: 4...10), wobble: .random(in: 2...5),
        width: .random(in: 6...9), height: .random(in: 9...13), color: palette.randomElement()!
      )
    }
  }
}

/// Célébrations du jeu par-dessus l'app : confettis, retour haptique et carte d'un nouveau badge.
struct CelebrationLayer: ViewModifier {
  @Environment(GameService.self) private var game
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .overlay {
        if let badge = game.celebratedBadge {
          ZStack {
            Color.black.opacity(0.25)
              .ignoresSafeArea()
              .onTapGesture { game.dismissBadge() }
              .accessibilityHidden(true)
            BadgeCelebrationCard(badge: badge) { game.dismissBadge() }
              .padding(.horizontal, 32)
          }
          .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
        }
      }
      .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.3), value: game.celebratedBadge)
      .overlay { ConfettiView(trigger: game.confettiBursts) }
      .sensoryFeedback(.success, trigger: game.confettiBursts)
  }
}

extension View {
  func celebrations() -> some View { modifier(CelebrationLayer()) }
}
