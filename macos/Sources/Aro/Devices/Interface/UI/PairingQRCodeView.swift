import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct PairingQRCodeView: View {
    let payload: String

    var body: some View {
        if let image {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(
                    "Pairing QR code. Use the six-digit code if scanning is unavailable."
                )
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pairing QR code unavailable")
        }
    }

    private var image: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(
            by: CGAffineTransform(scaleX: 10, y: 10)
        )
        let representation = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
