import SwiftUI
import AVKit

@main
struct TeleprompterApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

@MainActor
final class PromptModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var busy = false
    @Published var progress = 0.0
    @Published var error: String?
    @Published var ready = false
    var pip: AVPictureInPictureController?
    private var movieURL: URL?

    func prepare(text: String, speed: Double, fontSize: Double) {
        guard !busy else { return }
        busy = true; ready = false; error = nil; progress = 0
        pip?.stopPictureInPicture()
        player?.pause(); player = nil
        let previous = movieURL
        movieURL = nil
        Task {
            do {
                let url = try await MovieRenderer.make(text: text, speed: speed, fontSize: fontSize) { value in
                    Task { @MainActor in self.progress = value }
                }
                if let previous { try? FileManager.default.removeItem(at: previous) }
                movieURL = url
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                player = AVPlayer(url: url)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func openPiP() {
        guard let pip, pip.isPictureInPicturePossible else {
            error = "Плавающее окно ещё не готово. Запустите предпросмотр на несколько секунд и повторите."
            return
        }
        // Inline playback establishes a valid playback session before entering PiP.
        player?.play()
        pip.startPictureInPicture()
    }
}

struct ContentView: View {
    @AppStorage("draft") private var text = ""
    @AppStorage("speed") private var speed = 35.0
    @AppStorage("fontSize") private var fontSize = 32.0
    @StateObject private var model = PromptModel()
    @FocusState private var editingText: Bool
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextEditor(text: $text)
                        .focused($editingText)
                        .frame(height: 220)
                        .padding(8)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary))
                        .disabled(model.busy)
                    Text("Скорость: \(Int(speed))")
                    Slider(value: $speed, in: 10...100, step: 1).disabled(model.busy)
                    Text("Размер текста: \(Int(fontSize))")
                    Slider(value: $fontSize, in: 20...56, step: 1).disabled(model.busy)
                    Text("Скорость задаёт движение текста. Сначала подготовьте видео, затем проверьте чтение в предпросмотре.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Подготовить текст") {
                        editingText = false
                        model.prepare(text: text, speed: speed, fontSize: fontSize)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                    if model.busy {
                        ProgressView(value: model.progress)
                        Text("Подготовка: \(Int(model.progress * 100))%").font(.footnote)
                    }
                    if let player = model.player {
                        PlayerSurface(model: model, player: player)
                            .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                        HStack {
                            Button("▶︎") { player.play() }.accessibilityLabel("Продолжить")
                            Button("Пауза") { player.pause() }
                            Button("С начала") { player.seek(to: .zero); player.pause() }
                        }.buttonStyle(.bordered)
                        Button("Открыть плавающее окно") { model.openPiP() }
                            .buttonStyle(.borderedProminent).disabled(!model.ready)
                        Text("После открытия поставьте текст на паузу, перейдите в приложение для записи и продолжите через управление PiP. Изменили текст или настройки — подготовьте его заново.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    Text("Текст сохраняется на этом устройстве. Прототип работает без отправки текста на сервер.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }.scrollDismissesKeyboard(.interactively)
            .navigationTitle("Телесуфлер")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { editingText = false }
                }
            }
        }
    }
}

final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerSurface: UIViewRepresentable {
    let model: PromptModel
    let player: AVPlayer
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
            pip?.delegate = context.coordinator
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            context.coordinator.pip = pip
            context.coordinator.observation = pip?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { _, change in
                DispatchQueue.main.async { model.ready = change.newValue ?? false }
            }
            model.pip = pip
        } else { model.error = "На устройстве недоступна Картинка в картинке." }
        return view
    }
    func updateUIView(_ view: PlayerView, context: Context) { view.playerLayer.player = player }
    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        let model: PromptModel
        var pip: AVPictureInPictureController?
        var observation: NSKeyValueObservation?
        init(model: PromptModel) { self.model = model }
        func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
            Task { @MainActor in model.error = error.localizedDescription }
        }
        func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }
    }
}

enum MovieRenderer {
    struct RenderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func make(text: String, speed: Double, fontSize: Double, progress: @escaping (Double) -> Void) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard text.count <= 20000 else { throw RenderError(message: "Для прототипа используйте не больше 20 000 символов.") }
            let width = 640, height = 360, fps: Int32 = 15
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: UIColor.white
            ]
            let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            let size = (text as NSString).boundingRect(with: CGSize(width: 592, height: CGFloat.greatestFiniteMagnitude), options: options, attributes: attributes, context: nil)
            let travel = Double(size.height) + 280
            let duration = travel / speed + 3
            guard duration <= 1200 else { throw RenderError(message: "Текст при этой скорости длиннее 20 минут. Сократите его или увеличьте скорость.") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width, AVVideoHeightKey: height
                ])
                input.expectsMediaDataInRealTime = false
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
                ])
                guard writer.canAdd(input) else { throw RenderError(message: "Не удалось настроить видео.") }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? RenderError(message: "Не удалось начать подготовку.") }
                writer.startSession(atSourceTime: .zero)
                let frames = Int(ceil(duration * Double(fps)))
                for index in 0..<frames {
                    while !input.isReadyForMoreMediaData {
                        if writer.status == .failed { throw writer.error ?? RenderError(message: "Ошибка кодирования.") }
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    let ok: Bool = autoreleasepool {
                        var buffer: CVPixelBuffer?
                        guard let pool = adaptor.pixelBufferPool,
                              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                              let buffer else { return false }
                        CVPixelBufferLockBaseAddress(buffer, [])
                        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return false }
                        context.setFillColor(UIColor.black.cgColor)
                        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                        context.translateBy(x: 0, y: CGFloat(height))
                        context.scaleBy(x: 1, y: -1)
                        UIGraphicsPushContext(context)
                        let seconds = Double(index) / Double(fps)
                        let offset = max(0, seconds - 3) * speed
                        (text as NSString).draw(with: CGRect(x: 24, y: 80 - offset, width: 592, height: Double(size.height) + 4), options: options, attributes: attributes, context: nil)
                        UIGraphicsPopContext()
                        return adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: fps))
                    }
                    guard ok else { throw writer.error ?? RenderError(message: "Не удалось создать кадр.") }
                    if index % 30 == 0 { progress(Double(index) / Double(frames)) }
                }
                input.markAsFinished()
                await writer.finishWriting()
                guard writer.status == .completed else { throw writer.error ?? RenderError(message: "Видео не подготовлено.") }
                progress(1)
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }.value
    }
}
