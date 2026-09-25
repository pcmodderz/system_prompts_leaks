import CryptoKit
import HearthCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share → Hearth. Holds no household keys: each shared item is sealed to the main app's
/// inbox public key and dropped into the App Group inbox. Hearth asks what it belongs to
/// the next time it opens. Nothing is uploaded anywhere.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareStatusView(state: .working))
        addChild(host); view.addSubview(host.view); host.view.frame = view.bounds; host.didMove(toParent: self)
        Task {
            let count = await receive()
            host.rootView = ShareStatusView(state: count > 0 ? .done(count) : .failed)
            try? await Task.sleep(for: .seconds(1.2))
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    static var groupContainer: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.hearth") }

    func receive() async -> Int {
        guard let container = Self.groupContainer,
              let pubData = try? Data(contentsOf: container.appendingPathComponent("inbox-public-key")),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubData) else { return 0 }
        let inbox = container.appendingPathComponent("Household/inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let sharedText = items.compactMap { $0.attributedContentText?.string }.first
        var count = 0
        for item in items {
            for provider in item.attachments ?? [] {
                guard let (payload, meta) = await load(provider, sharedText: sharedText) else { continue }
                guard let sealed = try? InboxSealer.seal(payload, metadata: meta, to: publicKey) else { continue }
                let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).hinbox"
                let url = inbox.appendingPathComponent(name)
                if (try? sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil { count += 1 }
            }
        }
        return count
    }

    func load(_ provider: NSItemProvider, sharedText: String?) async -> (Data, InboxItemMetadata)? {
        let candidates: [(UTType, MediaKind)] = [(.movie, .video), (.image, .photo), (.pdf, .document), (.audio, .audio), (.fileURL, .document)]
        for (type, kind) in candidates where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let (data, name, mime) = await loadFile(provider, type: type) {
                return (data, InboxItemMetadata(filename: name, mimeType: mime, kind: kind, sourceApp: nil, sharedText: sharedText))
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
            return (Data(), InboxItemMetadata(filename: url.host ?? "Link", mimeType: "text/uri-list", kind: .web, sharedText: sharedText, sharedURL: url.absoluteString))
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            return (Data(), InboxItemMetadata(filename: "Text", mimeType: "text/plain", kind: .text, sharedText: text))
        }
        return nil
    }

    func loadFile(_ provider: NSItemProvider, type: UTType) async -> (Data, String, String)? {
        await withCheckedContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { cont.resume(returning: nil); return }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                cont.resume(returning: (data, provider.suggestedName.map { $0 + "." + url.pathExtension } ?? url.lastPathComponent, mime))
            }
        }
    }
}

struct ShareStatusView: View {
    enum State { case working, done(Int), failed }
    let state: State
    var body: some View {
        VStack(spacing: 12) {
            switch state {
            case .working: ProgressView("Saving to Hearth…")
            case .done(let n):
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Saved \(n) item(s). Open Hearth to choose where \(n == 1 ? "it belongs" : "they belong").")
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("Open Hearth once to set it up, then share again.")
            }
        }
        .multilineTextAlignment(.center).padding()
    }
}
