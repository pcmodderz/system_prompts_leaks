import AVKit
import HearthCore
import SwiftUI

struct FreshnessBadge: View {
    let freshness: Freshness
    let lastSuccess: Date?

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2.weight(.semibold))
            if let lastSuccess {
                Text(lastSuccess, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), updated \(lastSuccess.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "never")")
    }

    var label: String { freshness.rawValue.uppercased() }
    var color: Color {
        switch freshness {
        case .live, .fresh: .green
        case .stale: .orange
        case .offline: .gray
        case .unavailable, .disabled: .red
        }
    }
}

struct LiveReadingRow: View {
    let reading: LiveReading
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Self.title(reading.observation?.metric ?? reading.source.name)).font(.subheadline)
                Spacer()
                Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
            }
            HStack {
                Text(reading.source.name).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                FreshnessBadge(freshness: reading.freshness, lastSuccess: reading.lastSuccess)
            }
        }
    }

    var value: String {
        guard let o = reading.observation else { return "—" }
        switch o.value {
        case .number(let n): return "\(n.formatted(.number.precision(.fractionLength(0...1)))) \(o.unit ?? "")"
        case .string(let s): return s
        default: return "—"
        }
    }

    static func title(_ metric: String) -> String {
        ["temperature_2m": "Temperature", "apparent_temperature": "Feels like", "relative_humidity_2m": "Humidity",
         "precipitation": "Precipitation", "weather_code": "Conditions code", "wind_speed_10m": "Wind", "wind_gusts_10m": "Gusts"][metric] ?? metric
    }
}

/// Shows its content only while the vault is unlocked; otherwise offers Face ID.
struct VaultGate<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        if model.vaultUnlocked {
            content()
        } else {
            ContentUnavailableView {
                Label("Protected", systemImage: "lock.shield")
            } description: {
                Text("\(model.lockedCount) protected record(s). Financial, identity, insurance, security and network records need Face ID, Touch ID or your passcode.")
            } actions: {
                Button("Unlock") { Task { await model.unlockVault() } }.buttonStyle(.borderedProminent)
            }
        }
    }
}

struct MediaThumbnail: View {
    @EnvironmentObject var model: AppModel
    let media: MediaObject
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            }
            if media.mediaKind == .video {
                Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white).shadow(radius: 3)
            }
        }
        .clipped()
        .task(id: media.id) { image = await load() }
    }

    var icon: String {
        switch media.mediaKind {
        case .photo: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .document: "doc.text"
        case .text: "text.alignleft"
        case .web: "link"
        }
    }

    func load() async -> UIImage? {
        guard let store = model.store else { return nil }
        return await Task.detached(priority: .utility) {
            if let thumb = try? store.media.derivatives(of: media).first(where: { $0.role == .thumbnail }),
               let data = try? store.media.data(for: thumb) { return UIImage(data: data) }
            if media.mediaKind == .photo, media.byteCount < 25_000_000, let data = try? store.media.data(for: media) {
                return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 300, height: 300))
            }
            return nil
        }.value
    }
}

/// Full-screen viewer. Video is decrypted to a protected cache file (deleted on dismiss and
/// on backgrounding) so AVPlayer can stream it; the encrypted original is untouched.
struct MediaViewer: View {
    @EnvironmentObject var model: AppModel
    let media: MediaObject
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var playbackFile: URL?
    @State private var text: String?
    @State private var derivatives: [MediaObject] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if let player {
                    VideoPlayer(player: player).frame(minHeight: 280)
                } else if let text {
                    Text(text).textSelection(.enabled)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView()
                }
            }
            Section("Details") {
                LabeledContent("Kind", value: media.mediaKind.rawValue.capitalized)
                if let d = media.capturedAt { LabeledContent("Captured", value: d.formatted()) }
                LabeledContent("Imported", value: media.importedAt.formatted())
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: media.byteCount, countStyle: .file))
                if let f = media.originalFilename { LabeledContent("File", value: f) }
                if media.location != nil { LabeledContent("Location", value: "Recorded (private)") }
                LabeledContent("SHA-256", value: String(media.sha256.prefix(16)) + "…").font(.caption.monospaced())
            }
            if !derivatives.isEmpty {
                Section("Derived (original never modified)") {
                    ForEach(derivatives, id: \.id) { d in
                        HStack {
                            Text(d.role.rawValue); Spacer()
                            Text(d.producedBy ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                try? model.store?.media.deleteDerivative(d); load()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(media.caption ?? media.originalFilename ?? "Media")
        .task { load() }
        .onDisappear {
            player?.pause()
            if let playbackFile { try? FileManager.default.removeItem(at: playbackFile) }
        }
    }

    func load() {
        guard let store = model.store else { return }
        derivatives = (try? store.media.derivatives(of: media)) ?? []
        guard store.media.hasLocalBlob(media) else {
            error = "This item is stored on another household device. It will appear here after sync."
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                switch media.mediaKind {
                case .photo, .document where media.mimeType.hasPrefix("image/"):
                    let img = UIImage(data: try store.media.data(for: media))
                    await MainActor.run { image = img }
                case .video, .audio:
                    try FileManager.default.createDirectory(at: AppPaths.playbackCache, withIntermediateDirectories: true)
                    let ext = media.originalFilename.map { ($0 as NSString).pathExtension } ?? (media.mediaKind == .video ? "mov" : "m4a")
                    let url = AppPaths.playbackCache.appendingPathComponent("\(media.id).\(ext)")
                    if !FileManager.default.fileExists(atPath: url.path) { try store.media.decrypt(media, to: url) }
                    await MainActor.run { playbackFile = url; player = AVPlayer(url: url) }
                case .text, .web:
                    let s = String(decoding: try store.media.data(for: media), as: UTF8.self)
                    await MainActor.run { text = s }
                default:
                    let ocr = try store.media.derivatives(of: media).first { $0.role == .ocrText }
                    let s = try ocr.map { String(decoding: try store.media.data(for: $0), as: UTF8.self) } ?? "Document stored securely."
                    await MainActor.run { text = s }
                }
            } catch {
                await MainActor.run { self.error = "Couldn't open: \(error.localizedDescription)" }
            }
        }
    }
}
