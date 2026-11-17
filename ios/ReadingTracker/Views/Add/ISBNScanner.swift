import SwiftUI
import VisionKit

/// Feuille de scan : caméra VisionKit, ou explication si l'appareil ne la permet pas (simulateur).
struct ISBNScannerSheet: View {
  let onISBN: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  private var isAvailable: Bool {
    DataScannerViewController.isSupported && DataScannerViewController.isAvailable
  }

  var body: some View {
    NavigationStack {
      Group {
        if isAvailable {
          ISBNScannerView(onISBN: onISBN)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
              Text("Vise le code-barres au dos du livre")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 24)
            }
        } else {
          ContentUnavailableView(
            "Scan indisponible",
            systemImage: "camera.badge.ellipsis",
            description: Text(
              DataScannerViewController.isSupported
                ? "Autorise l'accès à la caméra dans Réglages pour scanner un code-barres."
                : "Cet appareil ne permet pas le scan. Saisis l'ISBN dans la recherche."
            )
          )
        }
      }
      .navigationTitle("Scanner un ISBN")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Fermer", systemImage: "xmark") { dismiss() }
        }
      }
    }
  }
}

/// `DataScannerViewController` limité aux codes EAN-13 / ISBN.
struct ISBNScannerView: UIViewControllerRepresentable {
  let onISBN: (String) -> Void

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let controller = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.ean13])],
      qualityLevel: .balanced,
      recognizesMultipleItems: false,
      isHighFrameRateTrackingEnabled: false,
      isHighlightingEnabled: true
    )
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
    if !controller.isScanning {
      try? controller.startScanning()
    }
  }

  static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
    controller.stopScanning()
  }

  func makeCoordinator() -> Coordinator { Coordinator(onISBN: onISBN) }

  @MainActor
  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let onISBN: (String) -> Void
    private var didFinish = false

    init(onISBN: @escaping (String) -> Void) {
      self.onISBN = onISBN
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
      for item in addedItems {
        guard case .barcode(let barcode) = item,
              let payload = barcode.payloadStringValue,
              let isbn = BookSearchService.normalizedISBN(payload),
              !didFinish
        else { continue }
        didFinish = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dataScanner.stopScanning()
        onISBN(isbn)
        return
      }
    }
  }
}
