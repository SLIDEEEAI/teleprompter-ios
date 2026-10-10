import SwiftUI
import AVKit

@main
struct TeleprompterApp: App {
    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--preview-smoke") { PreviewSmokeView() }
            else { ContentView() }
        }
    }
}

// A hosted view uses the video-call PiP content source. No media playback,
// microphone, camera capture, audio-session activation, or private API is used.
@MainActor
final class PromptModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published var ready = false
    @Published var configured = false
    @Published var playing = false
    @Published var error: String?
    @Published var status = "Текстовое окно · версия 0.6"
    @Published var diagnosticLog = ""
    private weak var inlineView: PromptView?
    private let overlayView = PromptView()
    private var contentController: AVPictureInPictureVideoCallViewController?
    private var pip: AVPictureInPictureController?
    private var observations: [NSKeyValueObservation] = []
    private var timer: Timer?
    private var prompt = ""
    private var fontSize = 32.0
    private var speed = 35.0
    private var textHeight = 0.0
    private var elapsed = 0.0
    private var anchor = CACurrentMediaTime()
    private var lastDiagnostic = CACurrentMediaTime()

    private func record(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let lines = diagnosticLog.split(separator: "\n").map(String.init) + ["\(stamp) · \(message)"]
        diagnosticLog = lines.suffix(80).joined(separator: "\n")
    }

    func attach(_ view: PromptView) {
        guard inlineView !== view else { return }
        inlineView = view
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            error = "Картинка в картинке недоступна."; return
        }
        let controller = AVPictureInPictureVideoCallViewController()
        controller.preferredContentSize = CGSize(width: 640, height: 360)
        controller.view.backgroundColor = .black
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(overlayView)
        NSLayoutConstraint.activate([
            overlayView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
        ])
        contentController = controller
        let source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: view, contentViewController: controller)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        self.pip = pip
        observations = [
            pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, value in
                DispatchQueue.main.async { self?.ready = value.newValue ?? false }
            },
            pip.observe(\.isPictureInPictureSuspended, options: [.new]) { [weak self] _, value in
                DispatchQueue.main.async { self?.record("Hosted PiP suspended=\(value.newValue ?? false)") }
            }
        ]
        render()
    }

    func configure(text: String, speed: Double, fontSize: Double) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Вставьте текст."; return }
        guard text.count <= 20000 else { error = "Максимум 20 000 символов."; return }
        prompt = text; self.speed = speed; self.fontSize = fontSize
        textHeight = Double((text as NSString).boundingRect(with: CGSize(width: 592, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: .medium)], context: nil).height)
        configured = true; error = nil
        reset()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        status = "Текст применён · версия 0.6"
        record("Hosted text applied: \(text.count) characters; no audio session")
    }

    private var duration: Double { (textHeight + 280) / speed + 3 }
    private func advance() {
        let now = CACurrentMediaTime()
        if playing { elapsed = min(duration, elapsed + max(0, now - anchor)) }
        anchor = now
        if elapsed >= duration { playing = false }
    }
    func setPlaying(_ value: Bool) {
        advance()
        if value && elapsed >= duration { elapsed = 0 }
        playing = value; anchor = CACurrentMediaTime()
        render()
    }
    func reset() { playing = false; elapsed = 0; anchor = CACurrentMediaTime(); render() }
    func openPiP() {
        guard configured else { return }
        guard let pip, pip.isPictureInPicturePossible else { error = "PiP пока не готово. Подождите секунду и повторите."; return }
        error = nil
        setPlaying(true)
        record("Starting hosted-view PiP (video-call content source)")
        pip.startPictureInPicture()
    }
    private func tick() {
        advance(); render()
        if pip?.isPictureInPictureActive == true && CACurrentMediaTime() - lastDiagnostic >= 10 {
            lastDiagnostic = CACurrentMediaTime()
            record("Hosted PiP tick: \(Int(elapsed))s, scrolling=\(playing)")
        }
    }
    private func render() {
        let y = 80 - max(0, elapsed - 3) * speed
        inlineView?.present(text: prompt, fontSize: fontSize, y: y, height: textHeight)
        overlayView.present(text: prompt, fontSize: fontSize, y: y, height: textHeight)
    }
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) { render() }
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        status = "Текстовое PiP запущено · версия 0.6"; record("Hosted PiP did start"); render()
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        setPlaying(false); status = "Плавающее окно закрыто"; record("Hosted PiP did stop")
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        setPlaying(false); self.error = error.localizedDescription; record("Hosted PiP failed: \(error.localizedDescription)")
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
    deinit { timer?.invalidate() }
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
                    Text("Версия 0.6 · текстовое плавающее окно").font(.caption).foregroundStyle(.secondary)
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
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("Журнал диагностики") {
                        Text(model.diagnosticLog).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Скопировать журнал") { UIPasteboard.general.string = model.diagnosticLog }
                    }
                    Text("Окно содержит текст без видеоплеера. Скорость задаётся заранее. Для паузы вернитесь в приложение. После изменения текста нажмите «Применить».")
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
    private var text = ""
    private var fontSize = 32.0
    private var y = 80.0
    private var textHeight = 0.0
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; isOpaque = true; clipsToBounds = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(text: String, fontSize: Double, y: Double, height: Double) {
        self.text = text; self.fontSize = fontSize; self.y = y; textHeight = height
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / 640, bounds.height / 360)
        context.saveGState()
        context.translateBy(x: (bounds.width - 640 * scale) / 2, y: (bounds.height - 360 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        (text as NSString).draw(with: CGRect(x: 24, y: y, width: 592, height: textHeight + 4), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: UIColor.white], context: nil)
        context.restoreGState()
    }
}
struct PromptSurface: UIViewRepresentable {
    let model: PromptModel
    func makeUIView(context: Context) -> PromptView {
        let view = PromptView(frame: .zero)
        model.attach(view)
        return view
    }
    func updateUIView(_ view: PromptView, context: Context) {}
}
struct PreviewSmokeView: View {
    @StateObject private var model = PromptModel()
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PromptSurface(model: model).frame(width: 320, height: 180)
        }.onAppear {
            model.configure(text: "Проверка текста\nPREVIEW TEST 503", speed: 35, fontSize: 46)
        }
    }
}
