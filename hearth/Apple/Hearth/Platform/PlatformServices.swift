import AVFoundation
import BackgroundTasks
import Foundation
import HearthCore
import ImageIO
import Network
import Speech
import UIKit
import UniformTypeIdentifiers
import Vision

/// Network reachability. Drives OFFLINE labelling and "refresh on reconnect".
@MainActor
final class Connectivity: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    var onReconnect: (() -> Void)?
    var onChange: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = path.status == .satisfied
                if wasOnline != self.isOnline { self.onChange?(self.isOnline) }
                if !wasOnline && self.isOnline { self.onReconnect?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "hearth.connectivity"))
    }
}

/// iOS decides when (and whether) background refresh runs. Hearth never claims continuous
/// monitoring; the UI shows each value's last successful update.
enum BackgroundRefresh {
    static let identifier = "app.hearth.refresh"

    static func register(runtime: @escaping () -> HearthStore?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let work = Task {
                if let store = runtime() { _ = await store.live.refreshAll() }
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// A folder the household controls (NAS via Files/SMB, Syncthing folder, iCloud Drive folder,
/// external drive) used as a sync transport. Stored as a security-scoped bookmark.
enum SyncFolder {
    static let key = "hearth.syncFolderBookmark"

    static func save(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { url.stopAccessingSecurityScopedResource() }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    static var displayName: String? {
        resolve()?.lastPathComponent
    }

    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static func sync(_ store: HearthStore) throws -> SyncReport? {
        guard let url = resolve() else { return nil }
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { url.stopAccessingSecurityScopedResource() }
        return try store.sync(with: DirectorySyncTransport(folder: url.appendingPathComponent("Hearth Sync")))
    }
}

/// On-device media processing. Nothing here uses the network.
enum OnDeviceProcessing {
    static func capabilities() -> CapabilityReport {
        let speech: ProcessingCapability = {
            guard let r = SFSpeechRecognizer() else { return .processingDisabled }
            return r.supportsOnDeviceRecognition ? .onDeviceAvailable : .onDeviceDegraded
        }()
        let neural: ProcessingCapability = ProcessInfo.processInfo.isLowPowerModeEnabled ? .onDeviceDegraded : .onDeviceAvailable
        return CapabilityReport(thumbnails: .onDeviceAvailable, videoMetadata: .onDeviceAvailable, keyframes: .onDeviceAvailable,
                                speechTranscription: speech, textRecognition: .onDeviceAvailable,
                                imageClassification: neural, searchEmbeddings: neural)
    }

    /// Thumbnail + OCR (photos, scans) or keyframe thumbnail + duration (video), stored as
    /// derivatives. The original is never modified.
    static func process(_ original: MediaObject, in store: HearthStore) async {
        guard original.role == .original else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try store.media.decrypt(original, to: tmp)
            switch original.mediaKind {
            case .photo, .document:
                if let thumb = thumbnail(imageAt: tmp, maxPixel: 480) {
                    try store.media.addDerivative(of: original, role: .thumbnail, data: thumb, mimeType: "image/jpeg", producedBy: "device.imageio")
                }
                if let text = try await recognizeText(imageAt: tmp), !text.isEmpty {
                    try store.media.addDerivative(of: original, role: .ocrText, data: Data(text.utf8), mimeType: "text/plain", producedBy: "device.vision.ocr")
                }
            case .video:
                let asset = AVURLAsset(url: tmp)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 480, height: 480)
                let (cg, _) = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600))
                if let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.7) {
                    try store.media.addDerivative(of: original, role: .thumbnail, data: data, mimeType: "image/jpeg", producedBy: "device.avfoundation")
                }
                var updated = original
                updated.durationSeconds = try await asset.load(.duration).seconds
                try store.save(updated, provenance: Provenance(.system, source: "device.avfoundation"))
                if let transcript = try await transcribe(fileAt: tmp) {
                    try store.media.addDerivative(of: original, role: .transcript, data: Data(transcript.utf8), mimeType: "text/plain", producedBy: "device.speech")
                }
            case .audio:
                if let transcript = try await transcribe(fileAt: tmp) {
                    try store.media.addDerivative(of: original, role: .transcript, data: Data(transcript.utf8), mimeType: "text/plain", producedBy: "device.speech")
                }
            case .text, .web:
                break
            }
        } catch {
            // Processing is best-effort; the original is already safely stored.
        }
    }

    static func thumbnail(imageAt url: URL, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.7)
    }

    static func recognizeText(imageAt url: URL) async throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(url: url)
        try handler.perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// On-device only. If the recognizer can't run on device, we skip rather than upload.
    static func transcribe(fileAt url: URL) async throws -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error { finished = true; cont.resume(throwing: error); return }
                if let result, result.isFinal { finished = true; cont.resume(returning: result.bestTranscription.formattedString) }
            }
        }
    }

    /// Reads capture date and GPS from image metadata without modifying the file.
    static func imageMetadata(at url: URL) -> (Date?, GeoPoint?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (nil, nil) }
        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
            date = f.date(from: s)
        }
        var point: GeoPoint?
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = gps[kCGImagePropertyGPSLatitude] as? Double, var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            point = GeoPoint(latitude: lat, longitude: lon)
        }
        return (date, point)
    }

    /// Copy of an image with GPS/location metadata removed, for "Remove location" when sharing
    /// or exporting. The stored original is not touched.
    static func strippingLocation(fromImageAt url: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type, CGImageSourceGetCount(src), nil) else { return nil }
        let remove: [CFString: Any] = [kCGImagePropertyGPSDictionary: kCFNull as Any]
        for i in 0..<CGImageSourceGetCount(src) { CGImageDestinationAddImageFromSource(dest, src, i, remove as CFDictionary) }
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
