import SwiftUI
import AVKit

@main
struct TeleprompterApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

@MainActor
final class PromptModel: NSObject, ObservableObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    @Published var ready = false
    @Published var configured = false
    @Published var playing = false
    @Published var error: String?
    @Published var status = "Режим прямых кадров · версия 0.4"
    let displayLayer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var observation: NSKeyValueObservation?
    private var stateObservations: [NSKeyValueObservation] = []
    @Published var diagnosticLog = ""
    @Published var activateAudioSession = false

    private func record(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        var lines = diagnosticLog.components(separatedBy: "\n").filter { !$0.isEmpty }
        lines.append("\(timestamp) · \(message)")
        diagnosticLog = lines.suffix(80).joined(separator: "\n")
    }

    private var timer: Timer?
    private var interruptionObserver: NSObjectProtocol?
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private var prompt = ""
    private var fontSize = 32.0
    private var speed = 35.0
    private var textHeight = 0.0
    private var elapsed = 0.0
    private var lastTick = CACurrentMediaTime()
    private var frameNumber: Int64 = 0
    private var frameErrorReported = false
    private var firstFrameReported = false

    private func frameError(_ message: String) {
        guard !frameErrorReported else { return }
        frameErrorReported = true
        error = message
        record(message)
    }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
        }
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.requiresLinearPlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            pip = controller
            observation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, value in
                DispatchQueue.main.async { self?.ready = value.newValue ?? false }
            }
                    stateObservations = [
                controller.observe(\.isPictureInPictureSuspended, options: [.initial, .new]) { [weak self] _, value in
                    DispatchQueue.main.async { self?.record("PiP suspended=\(value.newValue ?? false)") }
                },
                controller.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] _, value in
                    DispatchQueue.main.async { self?.record("PiP active=\(value.newValue ?? false)") }
                }
            ]
        } else { error = "Картинка в картинке недоступна." }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                // Record the event without reactivating audio or fighting the recording app.
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self?.status = "Аудиосессия прервана другим приложением"
                    self?.record("Audio interruption began")
                } else {
                    self?.status = "Прерывание аудиосессии завершено"
                    self?.record("Audio interruption ended")
                }
            }
        }
    }

    func configure(text: String, speed: Double, fontSize: Double) {
        record("Apply pressed: \(text.count) characters")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Вставьте текст."; return }
        guard text.count <= 20000 else { error = "Максимум 20 000 символов."; return }
        prompt = text; self.speed = speed; self.fontSize = fontSize
        error = nil; configured = true
        frameErrorReported = false; firstFrameReported = false
        displayLayer.flushAndRemoveImage()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } catch { self.error = error.localizedDescription; record("Audio category: \(error.localizedDescription)") }
        textHeight = Double((text as NSString).boundingRect(with: CGSize(width: 592, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil).height)
        reset()
        status = "Прямые кадры готовы · версия 0.4"
        startTimer()
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: UIColor.white]
    }

    func setPlaying(_ value: Bool) {
        if value && elapsed >= duration { elapsed = 0 }
        playing = value
        lastTick = CACurrentMediaTime()
        pip?.invalidatePlaybackState()
    }

    func reset() {
        elapsed = 0
        setPlaying(false)
        drawFrame()
    }

    private var duration: Double { (textHeight + 280) / speed + 3 }

    func openPiP() {
        guard let pip, pip.isPictureInPicturePossible else { error = "PiP пока не готово. Подождите секунду и повторите."; return }
        do {
            // PiP requires a playback category; no audio player or microphone is used.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            if activateAudioSession {
                try AVAudioSession.sharedInstance().setActive(true)
                record("Start PiP: playback session activated")
            } else {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                record("Start PiP: playback session NOT activated")
            }
        } catch { self.error = error.localizedDescription; return }
        setPlaying(true)
        pip.startPictureInPicture()
    }

    private func startTimer() {
        timer?.invalidate()
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let delta = now - lastTick
        if delta > 1 { record("Rendering gap: \(Int(delta)) seconds") }
        lastTick = now
        if playing {
            // Avoid skipping paragraphs if the OS suspends rendering.
            elapsed += min(delta, 0.25)
            if elapsed >= duration { elapsed = duration; setPlaying(false) }
        }
        drawFrame()
    }

    private func drawFrame() {
        guard configured else { return }
        autoreleasepool {
            if pool == nil {
                let settings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: 640,
                    kCVPixelBufferHeightKey as String: 360,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
                ]
                let result = CVPixelBufferPoolCreate(nil, nil, settings as CFDictionary, &pool)
                if result != kCVReturnSuccess { frameError("Не удалось создать буфер кадров: \(result)") }
            }
            var optionalBuffer: CVPixelBuffer?
            guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess, let buffer = optionalBuffer else { frameError("Не удалось выделить кадр."); return }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, []); frameError("Не удалось создать графический контекст."); return
            }
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            context.translateBy(x: 0, y: 360); context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            (prompt as NSString).draw(with: CGRect(x: 24, y: 80 - max(0, elapsed - 3) * speed, width: 592, height: textHeight + 4),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
            UIGraphicsPopContext()
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if format == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) }
            guard let format else { frameError("Не удалось создать формат кадра."); return }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 20),
                presentationTimeStamp: displayLayer.controlTimebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
            frameNumber += 1
            var sample: CMSampleBuffer?
            let result = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
            guard result == noErr, let sample else { frameError("Не удалось создать видеокадр: \(result)"); return }
            // Immediate presentation avoids relying on a media player's playback clock.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if displayLayer.status == .failed {
                let message = displayLayer.error?.localizedDescription ?? "Ошибка слоя отображения"
                frameError(message)
                displayLayer.flush()
            }
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sample)
                if !firstFrameReported {
                    firstFrameReported = true
                    record("First frame enqueued, layer status=\(displayLayer.status.rawValue)")
                }
            }
        }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) { record("PiP requested playing=\(playing)"); setPlaying(playing) }
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { !playing }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        elapsed = min(duration, max(0, elapsed + skipInterval.seconds))
        drawFrame(); completionHandler()
    }
    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool { true }
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) { status = "PiP запущено · прямые кадры"; record("PiP did start") }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        record("PiP did stop"); setPlaying(false); status = "PiP остановлено системой или пользователем"
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { self.error = error.localizedDescription }
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }

    deinit {
        timer?.invalidate()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
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
                    Text("Версия 0.4 · диагностика кадров").font(.caption).foregroundStyle(.secondary)
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    TextEditor(text: $text).focused($editingText)
                        .frame(height: 220).padding(8)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary))
                    VStack(alignment: .leading) {
                        Text("Скорость: \(Int(speed))")
                        Slider(value: $speed, in: 10...100, step: 1)
                        Text("Размер текста: \(Int(fontSize))")
                        Slider(value: $fontSize, in: 20...56, step: 1)
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { editingText = false })
                    Button("Применить текст и настройки") {
                        editingText = false
                        model.configure(text: text, speed: speed, fontSize: fontSize)
                    }.buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    PromptSurface(model: model).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture { editingText = false }
                    if model.configured {
                        HStack {
                            Button(model.playing ? "Пауза" : "Продолжить") { editingText = false; model.setPlaying(!model.playing) }
                            Button("С начала") { editingText = false; model.reset() }
                        }.buttonStyle(.bordered)
                        Button("Открыть плавающее окно") { editingText = false; model.openPiP() }
                            .buttonStyle(.borderedProminent)
                        Text(model.ready ? "PiP готово" : "PiP пока недоступно").font(.caption)
                    }
                    Toggle("Активировать аудиосессию (режим сравнения)", isOn: $model.activateAudioSession)
                        .font(.footnote)
                    Text("Диагностическая версия 0.4. Сначала проверьте с выключенным переключателем. Для смены режима закройте PiP.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("Журнал диагностики") {
                        Text(model.diagnosticLog).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Скопировать журнал") { UIPasteboard.general.string = model.diagnosticLog }
                    }
                    Text("Без подготовки видео. Проверяем работу прямых кадров во время записи. Если текст или настройки изменены, нажмите «Применить».")
                        .font(.footnote).foregroundStyle(.secondary)
                        .onTapGesture { editingText = false }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }.padding()
            }
            .scrollDismissesKeyboard(.interactively)
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

final class PromptView: UIView {
    var promptLayer: AVSampleBufferDisplayLayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        promptLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct PromptSurface: UIViewRepresentable {
    let model: PromptModel
    func makeUIView(context: Context) -> PromptView {
        let view = PromptView()
        view.backgroundColor = .black
        view.promptLayer = model.displayLayer
        view.layer.addSublayer(model.displayLayer)
        return view
    }
    func updateUIView(_ view: PromptView, context: Context) {}
}
