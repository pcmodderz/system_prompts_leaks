import AVFoundation
import HearthCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

struct CaptureTab: View {
    var body: some View { NavigationStack { CaptureView(attachTo: nil) } }
}

/// Camera-first capture: one tap to shoot, store encrypted immediately, attach afterwards
/// (or never — unfiled captures are still safe and searchable).
struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var location = LocationProvider()
    let attachTo: String?

    enum Mode: Identifiable { case photo, video, scan, audio; var id: Self { self } }
    @State private var mode: Mode?
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var justCaptured: [MediaObject] = []
    @State private var recordLocation = false

    var body: some View {
        List {
            Section {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        bigButton("Photo", "camera.fill") { mode = .photo }
                        bigButton("Video", "video.fill") { mode = .video }
                    }
                    GridRow {
                        bigButton("Scan", "doc.viewfinder") { mode = .scan }
                        bigButton("Audio note", "mic.fill") { mode = .audio }
                    }
                }
                .padding(.vertical, 6)
                PhotosPicker(selection: $libraryItems, maxSelectionCount: 50, matching: .any(of: [.images, .videos, .screenshots]),
                             photoLibrary: .shared()) {
                    Label("Import from Photos", systemImage: "photo.on.rectangle")
                }
                Toggle("Record where it was captured", isOn: $recordLocation)
            } footer: {
                Text("Captures are encrypted and stored on this device. Nothing is uploaded.")
            }
            if !justCaptured.isEmpty {
                Section("Just captured") {
                    ForEach(justCaptured, id: \.id) { m in
                        AttachRow(media: m, preselected: attachTo)
                    }
                }
            }
        }
        .navigationTitle("Capture")
        .fullScreenCover(item: $mode) { mode in
            switch mode {
            case .photo: CameraPicker(video: false) { handleCamera($0) }.ignoresSafeArea()
            case .video: CameraPicker(video: true) { handleCamera($0) }.ignoresSafeArea()
            case .scan: DocumentScanner { handleScan($0) }.ignoresSafeArea()
            case .audio: AudioRecorderView { handleAudio($0) }
            }
        }
        .onChange(of: libraryItems) { _, items in
            Task { await importFromLibrary(items); libraryItems = [] }
        }
    }

    func bigButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) { Image(systemName: icon).font(.largeTitle); Text(title).font(.headline) }
                .frame(maxWidth: .infinity, minHeight: 96)
        }
        .buttonStyle(.borderedProminent)
    }

    func currentLocation() async -> GeoPoint? { recordLocation ? await location.current() : nil }

    func handleCamera(_ result: CameraPicker.Result?) {
        mode = nil
        guard let result else { return }
        Task {
            let loc = await currentLocation()
            switch result {
            case .photo(let data):
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).heic")
                try? data.write(to: url)
                add(url, .photo, "image/heic", Date(), loc, .capture)
            case .video(let url):
                add(url, .video, "video/quicktime", Date(), loc, .capture)
            }
        }
    }

    func handleScan(_ pdf: URL?) {
        mode = nil
        guard let pdf else { return }
        add(pdf, .document, "application/pdf", Date(), nil, .capture)
    }

    func handleAudio(_ url: URL?) {
        mode = nil
        guard let url else { return }
        add(url, .audio, "audio/mp4", Date(), nil, .capture)
    }

    func add(_ url: URL, _ kind: MediaKind, _ mime: String, _ date: Date?, _ loc: GeoPoint?, _ method: Provenance.Method) {
        if let m = model.importMedia(file: url, kind: kind, mimeType: mime, capturedAt: date, location: loc,
                                     attachTo: attachTo, provenance: Provenance(method)) {
            justCaptured.insert(m, at: 0)
        }
        if method == .capture { try? FileManager.default.removeItem(at: url) }
    }

    /// Copies the chosen items. The Photos library item itself is never modified.
    func importFromLibrary(_ items: [PhotosPickerItem]) async {
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let file = try? await item.loadTransferable(type: PickedFile.self) else { continue }
            var date: Date?
            var loc: GeoPoint?
            if let id = item.itemIdentifier,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                date = asset.creationDate
                if let l = asset.location { loc = GeoPoint(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude) }
            }
            if !isVideo, date == nil {
                (date, loc) = OnDeviceProcessing.imageMetadata(at: file.url)
            }
            let type = UTType(filenameExtension: file.url.pathExtension)
            add(file.url, isVideo ? .video : .photo, type?.preferredMIMEType ?? (isVideo ? "video/quicktime" : "image/jpeg"),
                date, recordLocation ? loc : nil, .photoLibraryImport)
            try? FileManager.default.removeItem(at: file.url)
        }
    }
}

/// Loads a picked asset as a file copy, preserving the original encoding (HEIC/ProRAW/MOV).
struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedFile(url: dest)
        }
    }
}

struct AttachRow: View {
    @EnvironmentObject var model: AppModel
    let media: MediaObject
    let preselected: String?
    @State private var target = ""
    @State private var attached = false

    var body: some View {
        HStack {
            MediaThumbnail(media: media).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
            if attached || preselected != nil {
                Label("Filed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Picker("Belongs to", selection: $target) {
                    Text("Choose…").tag("")
                    ForEach(model.entities, id: \.id) { Text($0.name).tag($0.id) }
                }
                .onChange(of: target) { _, id in
                    guard !id.isEmpty else { return }
                    model.attach(media.id, to: id); attached = true
                }
            }
        }
    }
}

// MARK: - UIKit bridges

struct CameraPicker: UIViewControllerRepresentable {
    enum Result { case photo(Data), video(URL) }
    let video: Bool
    let completion: (Result?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        c.mediaTypes = [video ? UTType.movie.identifier : UTType.image.identifier]
        if c.sourceType == .camera {
            c.cameraCaptureMode = video ? .video : .photo
            if video { c.videoQuality = .typeHigh; c.videoMaximumDuration = 30 * 60 }
        }
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Result?) -> Void
        init(_ c: @escaping (Result?) -> Void) { completion = c }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                try? FileManager.default.moveItem(at: url, to: dest)
                completion(.video(dest))
            } else if let image = info[.originalImage] as? UIImage, let data = image.heicData() ?? image.jpegData(compressionQuality: 0.95) {
                completion(.photo(data))
            } else {
                completion(nil)
            }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
    }
}

/// VisionKit document camera → multi-page PDF (OCR runs afterwards as a derivative).
struct DocumentScanner: UIViewControllerRepresentable {
    let completion: (URL?) -> Void
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let c = VNDocumentCameraViewController(); c.delegate = context.coordinator; return c
    }
    func updateUIViewController(_ c: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (URL?) -> Void
        init(_ c: @escaping (URL?) -> Void) { completion = c }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Scan-\(Date().formatted(.iso8601)).pdf".replacingOccurrences(of: ":", with: "-"))
            let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
            let renderer = UIGraphicsPDFRenderer(bounds: bounds)
            try? renderer.writePDF(to: url) { ctx in
                for i in 0..<scan.pageCount {
                    ctx.beginPage()
                    let img = scan.imageOfPage(at: i)
                    let scale = min(bounds.width / img.size.width, bounds.height / img.size.height)
                    let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                    img.draw(in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
                }
            }
            completion(url)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { completion(nil) }
    }
}

struct AudioRecorderView: View {
    let completion: (URL?) -> Void
    @State private var recorder: AVAudioRecorder?
    @State private var url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
    @State private var started: Date?
    @State private var recording = false

    var body: some View {
        VStack(spacing: 32) {
            Text("Audio note").font(.title.bold())
            if let started {
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    Text(Duration.seconds(ctx.date.timeIntervalSince(started)).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 56, weight: .light, design: .rounded).monospacedDigit())
                }
            }
            Button {
                if recording { recorder?.stop(); recording = false; completion(url) } else { start() }
            } label: {
                Image(systemName: recording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 88)).foregroundStyle(.red)
            }
            Button("Cancel") { recorder?.stop(); try? FileManager.default.removeItem(at: url); completion(nil) }
        }
        .onAppear(perform: start)
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default)
        try? session.setActive(true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recording = recorder?.record() ?? false
        started = Date()
    }
}
