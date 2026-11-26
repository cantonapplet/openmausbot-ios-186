// A bot's browser, watched and driven from the phone.
//
// ComputerView is the watching half and says so in its own header. This is
// the other half: the same idea, but with a gesture layer behind it and a
// take/release gate in front, so the person can actually work rather than
// only supervise.
import CompanionCore
import SwiftUI
import UIKit

@MainActor
final class BrowserControlModel: ObservableObject {
    @Published var frame: BrowserFrame?
    /// `frame`, decoded once when it arrives. The view used to decode it in
    /// `body`, so every render — each Session publish, and each cursor or
    /// zoom change while dragging — made a new `UIImage` and decoded the
    /// JPEG again. Always set together with `frame`, so the image on screen
    /// and the size `drawnSize` maps touches through describe one frame.
    @Published private(set) var image: UIImage?
    @Published var status = BrowserStatus(connected: false, screencasting: false, viewportWidth: 1280, viewportHeight: 720)
    @Published var url = ""
    @Published var driving = false
    @Published var mode: GestureMode = .direct
    @Published var transform = ViewTransform.identity
    @Published var cursor = RemotePoint(x: 0.5, y: 0.5)
    @Published var failure: String?
    @Published var latchedModifiers = 0
    /// The stream is gone and nothing will restart it on its own. The screen
    /// shows Try again rather than a spinner that never resolves — the
    /// failure the first hands-on test hit after the grant was switched on.
    @Published var streamEnded = false
    @Published var changingControl = false

    private let botId: String
    private var client: BrowserLiveClient
    private var viewerId: String?
    private var stream: Task<Void, Never>?
    private var sink = BrowserLiveSink()
    private var queue: BrowserInputQueue?
    private var acknowledgements: BrowserFrameAcks?
    private var generation = 0

    init(botId: String, client: BrowserLiveClient) {
        self.botId = botId
        self.client = client
    }

    func start() {
        guard stream == nil else { return }
        streamEnded = false
        failure = nil
        // A new stream is a new viewer; nothing from the old one carries over.
        viewerId = nil
        queue = nil
        driving = false
        frame = nil
        image = nil
        status = BrowserStatus(connected: false, screencasting: false, viewportWidth: 1280, viewportHeight: 720)
        sink = BrowserLiveSink()
        generation += 1
        let current = generation
        let client = self.client
        stream = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in client.live(botId: botId) {
                    guard !Task.isCancelled, current == generation else { return }
                    await self.apply(message)
                }
                guard !Task.isCancelled, current == generation else { return }
                self.failure = self.failure ?? "The browser stream ended."
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, current == generation else { return }
                self.failure = Self.explain(error)
            }
            await acknowledgements?.stop()
            await queue?.clear()
            guard current == generation else { return }
            viewerId = nil
            self.stream = nil
            self.streamEnded = true
            self.driving = false
        }
    }

    func retry(client: BrowserLiveClient?) {
        stop()
        guard let client else {
            failure = "The active connection is no longer available."
            streamEnded = true
            return
        }
        self.client = client
        start()
    }

    func stop() {
        generation += 1
        let id = viewerId, pending = queue, acks = acknowledgements, client = client, botId = botId
        driving = false
        changingControl = false
        viewerId = nil
        queue = nil
        acknowledgements = nil
        Task {
            await acks?.stop()
            await pending?.clear()
            if let id { _ = try? await client.action(botId: botId, viewerId: id, body: ["type": "release"]) }
        }
        stream?.cancel()
        stream = nil
    }

    /// The 429 from a full viewer table is a real situation with a real
    /// answer, not a generic failure worth shrugging at.
    private static func explain(_ error: Error) -> String {
        if case let APIError.status(code, message) = error {
            if code == 429 {
                return "This browser is already open on your Mac. Close it there, then try again."
            }
            if code == 403 {
                return message ?? "Browser control is off for this device. Enable it on your computer."
            }
            return message ?? "The browser stream stopped (\(code))."
        }
        return "The browser stream stopped."
    }

    private func apply(_ message: BrowserLiveMessage) async {
        switch message {
        case let .frame(frame):
            // Decoded off the main actor. The stream waits for this before
            // reading on, so frames still land in order, and the ack below
            // still follows the frame being shown.
            let current = generation
            let image = await Self.decode(frame).map { UIImage(cgImage: $0.cgImage) }
            guard current == generation else { return }
            self.frame = frame
            self.image = image
            sink.frameWidth = frame.deviceWidth
            sink.frameHeight = frame.deviceHeight
            await acknowledgements?.enqueue(frame.seq)
        case let .status(status):
            self.status = status
            if frame == nil {
                sink.frameWidth = status.viewportWidth
                sink.frameHeight = status.viewportHeight
            }
        case let .url(url):
            self.url = url
        case .tabs:
            break
        case let .ready(id):
            viewerId = id
            makeQueue(viewerId: id)
        // The server is the authority on who is driving: a peer taking
        // control must end ours rather than leave two surfaces both
        // believing they hold it.
        case let .control(controlling, _, owned):
            driving = owned && controlling
        case .heartbeat:
            break
        case let .error(message):
            failure = message
        }
    }

    /// Full size: the frame is drawn across the whole screen, so there is
    /// nothing to downsample; the win is decoding it once, not per render.
    private nonisolated static func decode(_ frame: BrowserFrame) async -> DecodedImage? {
        let data = frame.data
        return await Task.detached(priority: .userInitiated) {
            ImageDownsampler.decode(base64: data)
        }.value
    }

    private func makeQueue(viewerId: String) {
        let client = self.client
        let botId = self.botId
        let current = generation
        queue = BrowserInputQueue(
            send: { body in try await client.send(botId: botId, viewerId: viewerId, input: body) },
            onError: { [weak self] error in
                Task { @MainActor in
                    if self?.generation == current { self?.failure = error.localizedDescription }
                }
            }
        )
        acknowledgements = BrowserFrameAcks { sequence in
            _ = try await client.action(botId: botId, viewerId: viewerId, body: ["type": "ack", "seq": sequence])
        }
    }

    func takeControl() async {
        guard let viewerId, !changingControl, stream != nil, !streamEnded else { return }
        changingControl = true
        let current = generation, client = client
        defer { if current == generation { changingControl = false } }
        do {
            _ = try await client.action(botId: botId, viewerId: viewerId, body: ["type": "take"])
            guard current == generation, self.viewerId == viewerId, !Task.isCancelled else {
                _ = try? await client.action(botId: botId, viewerId: viewerId, body: ["type": "release"])
                return
            }
            failure = nil
        } catch {
            if current == generation { failure = Self.explain(error) }
        }
    }

    func releaseControl() async {
        driving = false
        latchedModifiers = 0
        guard let viewerId, let queue else { return }
        changingControl = true
        let current = generation, client = client
        defer { if current == generation { changingControl = false } }
        // Let go of what the remote is holding before handing it back; stale
        // travel is not worth waiting for.
        await queue.drain()
        _ = try? await client.action(botId: botId, viewerId: viewerId, body: ["type": "release"])
    }

    /// Everything the gesture core produced, converted and queued.
    func send(_ intents: [GestureIntent]) {
        guard driving, let queue else { return }
        var sink = self.sink
        let bodies = intents.flatMap { sink.bodies(for: $0) }
        self.sink = sink
        guard !bodies.isEmpty else { return }
        Task { for body in bodies { await queue.enqueue(body) } }
    }

    /// Releases everything held. Called when the view leaves or the app goes
    /// to the background — a key left down outlives the session otherwise.
    func flushHeldInput() {
        guard let queue else { return }
        Task { await queue.drain() }
    }

    func typed(_ text: String) {
        send([.text(text)])
    }

    /// A named key with whatever modifiers are latched, which the bar then
    /// clears: latching is for the next key, not for every key after it.
    func pressKey(_ name: String) {
        send([.key(name: name, modifiers: latchedModifiers)])
        latchedModifiers = 0
    }

    func toggleModifier(_ bit: Int) {
        latchedModifiers ^= bit
    }

    func navigate(_ raw: String) async {
        guard let viewerId else { return }
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        if !candidate.contains("://") { candidate = "https://\(candidate)" }
        _ = try? await client.action(botId: botId, viewerId: viewerId, body: ["type": "navigate", "url": candidate])
    }

    func command(_ type: String) async {
        guard let viewerId else { return }
        _ = try? await client.action(botId: botId, viewerId: viewerId, body: ["type": type])
    }
}

struct BrowserControlView: View {
    let bot: Bot
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: BrowserControlModel
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @FocusState private var keyboardFocused: Bool
    @State private var typedBuffer = ""
    @State private var surface: BrowserTouchSurface.Coordinator?
    @State private var modifiersCanScrollLeft = false
    @State private var modifiersCanScrollRight = false

    init(bot: Bot, client: BrowserLiveClient) {
        self.bot = bot
        _model = StateObject(wrappedValue: BrowserControlModel(botId: bot.id, client: client))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                chrome
                screen
                if model.driving {
                    modifierBar
                    drivingBar
                }
            }
        }
        .navigationTitle(bot.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.start() }
        .onDisappear {
            releaseHeldInput()
            model.stop()
        }
        .onValueChange(of: scenePhase) { phase in
            // Backgrounding mid-drag must not leave a button down on the
            // remote with nothing left to lift it.
            if phase != .active {
                releaseHeldInput()
                model.stop()
            } else { model.retry(client: session.browserLiveClient()) }
        }
        .alert("Browser", isPresented: Binding(
            get: { model.failure != nil },
            set: { if !$0 { model.failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }

    /// The core is the only thing that knows a button is held, so the
    /// releases have to come from it before the queue is drained.
    private func releaseHeldInput() {
        // flush() emits its releases through the same onIntents path every
        // other gesture takes, so they land in the queue before it drains.
        surface?.flush()
        model.flushHeldInput()
    }

    private var chrome: some View {
        HStack(spacing: 8) {
            chromeButton("chevron.left", label: "Back in browser", disabled: !model.driving) {
                Task { await model.command("back") }
            }
            chromeButton("arrow.clockwise", label: "Reload browser", disabled: !model.driving) {
                Task { await model.command("reload") }
            }

            HStack(spacing: 7) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                TextField("Address", text: $address)
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .disabled(!model.driving)
                    .onSubmit { Task { await model.navigate(address) } }
                    // The page's own navigation must not overwrite what someone
                    // is halfway through typing.
                    .onValueChange(of: model.url) { url in if !addressFocused { address = url } }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .glassCapsule(interactive: false)

            Picker("", selection: $model.mode) {
                Image(systemName: "hand.tap").tag(GestureMode.direct)
                Image(systemName: "rectangle.and.hand.point.up.left").tag(GestureMode.trackpad)
            }
            .pickerStyle(.segmented)
            .frame(width: 88)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .chromeBar()
    }

    private func chromeButton(
        _ systemImage: String, label: LocalizedStringKey, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var screen: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = model.image {
                    // Measured against the drawn frame, not the view. The
                    // gesture core maps coordinates through the same aspect
                    // fit, and on a letterboxed frame the two differ enough
                    // that a zoomed tap lands nowhere near the pixel touched.
                    let drawn = drawnSize(in: proxy.size, frame: model.frame)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(model.transform.scale, anchor: .topLeading)
                        .offset(
                            x: -model.transform.offsetX * drawn.width * model.transform.scale,
                            y: -model.transform.offsetY * drawn.height * model.transform.scale
                        )
                        .clipped()
                        .accessibilityLabel("\(bot.name)'s browser")
                } else {
                    waiting
                }

                BrowserTouchSurface(
                    mode: $model.mode,
                    driving: model.driving,
                    frameWidth: model.frame?.deviceWidth ?? model.status.viewportWidth,
                    frameHeight: model.frame?.deviceHeight ?? model.status.viewportHeight,
                    onIntents: { model.send($0) },
                    onViewState: { transform, cursor in
                        model.transform = transform
                        model.cursor = cursor
                    },
                    onReady: { surface = $0 }
                )

                // Drawn locally at frame rate so it never waits for the
                // network — the whole reason trackpad mode feels usable.
                if model.mode == .trackpad, model.driving {
                    cursorReticle(in: proxy.size)
                }

                // A hidden field is how the soft keyboard reaches us. Typed
                // text goes out as `char`, which the server turns into
                // insertText — no virtual keycode table anywhere.
                TextField("", text: $typedBuffer)
                    .focused($keyboardFocused)
                    .opacity(0.01)
                    .frame(width: 1, height: 1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onValueChange(of: typedBuffer) { value in
                        guard !value.isEmpty else { return }
                        model.typed(value)
                        typedBuffer = ""
                    }

                if !model.driving {
                    VStack {
                        Spacer()
                        controlBar
                    }
                }
            }
        }
    }

    /// The aspect-fit size the frame occupies, matching `ViewportMapping`.
    private func drawnSize(in view: CGSize, frame: BrowserFrame?) -> CGSize {
        let frameWidth = frame?.deviceWidth ?? model.status.viewportWidth
        let frameHeight = frame?.deviceHeight ?? model.status.viewportHeight
        guard view.width > 0, view.height > 0, frameWidth > 0, frameHeight > 0 else { return view }
        let fit = min(view.width / frameWidth, view.height / frameHeight)
        return CGSize(width: frameWidth * fit, height: frameHeight * fit)
    }

    private func cursorReticle(in size: CGSize) -> some View {
        let drawn = drawnSize(in: size, frame: model.frame)
        let x = (size.width - drawn.width) / 2
            + (model.cursor.x - model.transform.offsetX) * model.transform.scale * drawn.width
        let y = (size.height - drawn.height) / 2
            + (model.cursor.y - model.transform.offsetY) * model.transform.scale * drawn.height
        return Circle()
            .strokeBorder(Color.white, lineWidth: 2)
            .background(Circle().fill(Color.black.opacity(0.35)))
            .frame(width: 22, height: 22)
            .position(x: x, y: y)
            .allowsHitTesting(false)
    }

    private var controlBar: some View {
        Group {
            if model.streamEnded {
                chromeAction("Try again", systemImage: "arrow.clockwise") {
                    model.retry(client: session.browserLiveClient())
                }
            } else {
                // The one high-contrast action: black on white.
                Button {
                    Task { await model.takeControl() }
                } label: {
                    Label("Take control", systemImage: "hand.point.up.left")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!model.status.connected || model.changingControl)
                .opacity(model.status.connected && !model.changingControl ? 1 : 0.45)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
    }

    /// Keyboard and Hand back sit under the modifier keys, split across the
    /// width the way a bottom action bar would be.
    private var drivingBar: some View {
        HStack(spacing: 10) {
            Button {
                keyboardFocused.toggle()
            } label: {
                Label("Keyboard", systemImage: "keyboard")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .glassCapsule()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keyboard")

            Button {
                releaseHeldInput()
                Task { await model.releaseControl() }
            } label: {
                Label("Hand back", systemImage: "hand.raised")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hand back")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func chromeAction(
        _ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .glassCapsule()
        }
        .buttonStyle(.plain)
    }

    /// Without this bar there is no Cmd-L, no Escape and no Tab between
    /// fields — and therefore no real work.
    private var modifierBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                modifier("ctrl", bit: 2)
                modifier("alt", bit: 1)
                modifier("cmd", bit: 4)
                modifier("shift", bit: 8)
                key("esc", "Escape")
                key("tab", "Tab")
                key("↑", "ArrowUp")
                key("↓", "ArrowDown")
                key("←", "ArrowLeft")
                key("→", "ArrowRight")
                key("⏎", "Enter")
                key("⌫", "Backspace")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .modifier(ModifierScrollEdges(
            canScrollLeft: $modifiersCanScrollLeft,
            canScrollRight: $modifiersCanScrollRight
        ))
        .mask(modifierEdgeMask)
    }

    /// Fade the key row only where it continues past the edge.
    private var modifierEdgeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: modifiersCanScrollLeft ? [.clear, .black] : [.black, .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 22)

            Rectangle().fill(.black)

            LinearGradient(
                colors: modifiersCanScrollRight ? [.black, .clear] : [.black, .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 22)
        }
    }

    private func modifier(_ label: String, bit: Int) -> some View {
        let latched = model.latchedModifiers & bit != 0
        return Button(label) { model.toggleModifier(bit) }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(latched ? Color.black : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(latched ? Color.white : Color.clear, in: Capsule())
            .glassCapsule(interactive: false)
    }

    private func key(_ label: String, _ name: String) -> some View {
        Button(label) { model.pressKey(name) }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .glassCapsule(interactive: false)
    }

    private var waiting: some View {
        VStack(spacing: 10) {
            Image(systemName: model.streamEnded ? "exclamationmark.triangle" : "display")
                .font(.system(size: 26))
                .foregroundStyle(Color.white.opacity(0.7))
            Text(model.streamEnded ? (model.failure ?? "The browser stream ended.")
                 : model.status.connected ? "Waiting for a frame…" : "Connecting to the browser…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .multilineTextAlignment(.center)
            if !model.streamEnded {
                ProgressView().tint(.white).controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 300)
        .glassSheet(cornerRadius: 22)
    }
}


private struct ScrollEdges: Equatable {
    var left: Bool
    var right: Bool
}

private struct ModifierScrollEdges: ViewModifier {
    @Binding var canScrollLeft: Bool
    @Binding var canScrollRight: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                let offset = geometry.contentOffset.x
                let visible = geometry.containerSize.width
                let total = geometry.contentSize.width
                return ScrollEdges(
                    left: offset > 0.5,
                    right: offset + visible < total - 0.5
                )
            } action: { _, edges in
                canScrollLeft = edges.left
                canScrollRight = edges.right
            }
        } else {
            content
        }
    }
}
