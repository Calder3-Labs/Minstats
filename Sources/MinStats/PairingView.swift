import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The pairing sheet: a QR the iPhone scans, plus the same payload as
/// copyable text — the Simulator has no camera, so the paste path isn't a
/// fallback, it's the one you'll use most while developing.
struct PairingView: View {
    let pairingURL: String
    let deviceName: String
    var onRotate: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Pair iPhone")
                    .font(.headline)
                Text("Scan with MinStats on your iPhone, on the same Wi-Fi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // Without this, SwiftUI compresses the text to one line and
                    // ellipsizes it rather than wrapping inside the fixed width.
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let qr = Self.qrImage(from: pairingURL) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 190, height: 190)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text(deviceName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(copied ? "Copied — clears in 1 min" : "Copy pairing link") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                // The de-facto "concealed" marker (nspasteboard.org):
                // clipboard managers that respect it won't display or
                // archive the secret.
                pasteboard.setString("", forType: .init("org.nspasteboard.ConcealedType"))
                pasteboard.setString(pairingURL, forType: .string)
                copied = true
                // The link is a bearer credential; don't let it sit on a
                // pasteboard that Universal Clipboard syncs everywhere.
                // Cleared only if it's still ours — never clobber something
                // the owner copied since.
                let count = pasteboard.changeCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    guard NSPasteboard.general.changeCount == count else { return }
                    NSPasteboard.general.clearContents()
                    copied = false
                }
            }
            .controlSize(.small)

            Divider()

            // Rotating invalidates every paired phone — the "I shared this
            // QR with the wrong person" escape hatch.
            Button("Rotate secret…", role: .destructive) {
                onRotate()
                copied = false
            }
            .controlSize(.small)
            .font(.caption)

            Text("This code grants control of this Mac. Don't share it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 260)
    }

    private static func qrImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale up before rasterizing: the generator emits ~25pt, which
        // would be a blurry mess stretched to 190.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
