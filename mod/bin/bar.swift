// Native controller for the per-session mod. No model or cloud account lives here.
import Cocoa
import SwiftUI

let dir = NSHomeDirectory() + "/.cache/read-aloud/conversation"
let settingsPath = NSHomeDirectory() + "/.config/read-aloud/settings.json"
let demo = CommandLine.arguments.contains("--demo") || Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true

struct Request: Decodable, Identifiable {
    let id: String
    let kind: String
    let question: String
    let options: [String]?
    let detail: String?
    let tool: String?
    let multiSelect: Bool?
}
struct S: Identifiable, Decodable {
    let id: String, instance: String, local: String, name: String, cwd: String, phase: String, work: String
    let ts: Double, startedAt: Double
    let i: Int, n: Int
    let text: String
    let ready: Bool
    let pending: [Request]
}
struct Settings {
    var rate = 0, gap = 4
    var rewrite = true, manual = false, captions = true, follow = false, voice = false
    var wake = "okay claude"
}
func loadSettings() -> Settings {
    var s = Settings()
    if let data = FileManager.default.contents(atPath: settingsPath),
       let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        s.rate = j["rate"] as? Int ?? 0; s.gap = j["gap"] as? Int ?? 4
        s.rewrite = j["rewrite"] as? Bool ?? true; s.manual = j["manual"] as? Bool ?? false
        s.captions = j["captions"] as? Bool ?? true; s.follow = j["follow"] as? Bool ?? false
        s.voice = j["voice"] as? Bool ?? false; s.wake = j["wake"] as? String ?? "okay claude"
    }
    if demo { s.voice = false }
    return s
}
func atomicJSON(_ value: [String: Any], path: String) throws {
    let parent = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try JSONSerialization.data(withJSONObject: value)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}
func saveSettings(_ s: Settings) throws {
    var old: [String: Any] = [:]
    if let data = FileManager.default.contents(atPath: settingsPath) { old = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
    old.merge(["rate": s.rate, "gap": s.gap, "rewrite": s.rewrite, "manual": s.manual,
               "captions": s.captions, "follow": s.follow, "voice": s.voice, "wake": s.wake]) { _, new in new }
    try atomicJSON(old, path: settingsPath)
}
func openChat(_ s: S) {
    guard !demo, !s.local.isEmpty else { return }
    var parts = URLComponents(); parts.scheme = "claude"; parts.host = "code"; parts.path = "/continue"
    parts.queryItems = [URLQueryItem(name: "session", value: s.local)]
    if let url = parts.url { NSWorkspace.shared.open(url) }
}
let prefs = UserDefaults(suiteName: "read-aloud-bar") ?? .standard

final class Store: ObservableObject {
    @Published var all: [S] = []
    @Published var settings = loadSettings()
    @Published var activeID = ""
    @Published var activeInstance = ""
    @Published var heard = ""
    @Published var notice = "Choose a session, then turn on the microphone."
    @Published var delivery = ""
    @Published var aliases = prefs.dictionary(forKey: "voiceAliases") as? [String: String] ?? [:]
    var captures: [String: SpeechDestination] = [:]
    var speechIDs = Set<String>()
    var commands: [String: (String, Date)] = [:]
    var selected: S? { all.first { $0.id == activeID && $0.instance == activeInstance } }
    var speaking: S? { all.first { $0.phase == "speaking" || $0.phase == "paused" } }
    var queued: [S] { all.filter { $0.phase == "queued" } }
    func label(_ s: S) -> String { aliases[s.id] ?? s.name }
    func update(_ change: (inout Settings) -> Void) {
        change(&settings)
        guard !demo else { return }
        do { try saveSettings(settings) } catch { notice = "Couldn't save settings: \(error.localizedDescription)" }
    }
    func refresh() {
        if demo {
            if all.isEmpty { loadDemo() }
            return
        }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let now = Date().timeIntervalSince1970 * 1000
        all = files.filter { $0.hasPrefix("s-") && $0.hasSuffix(".json") }.compactMap { file in
            guard let data = fm.contents(atPath: "\(dir)/\(file)"), let session = try? JSONDecoder().decode(S.self, from: data),
                  now - session.ts < 12000, now >= session.ts - 1000 else { return nil }
            return session
        }.sorted { $0.startedAt < $1.startedAt }
        if activeID.isEmpty && all.count == 1 { select(all[0], read: false) }
        for (id, (name, time)) in Array(commands) {
            if let data = fm.contents(atPath: "\(dir)/ack-\(id).json"),
               let ack = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let status = ack["status"] as? String {
                let detail = ack["detail"] as? String ?? ""
                switch status {
                case "queued": delivery = "Queued in \(name)."
                case "started": delivery = "Message started in \(name)."; commands.removeValue(forKey: id)
                case "answered": delivery = "Response received by \(name)."; commands.removeValue(forKey: id)
                case "done": delivery = detail.isEmpty ? "Received by \(name)." : detail; commands.removeValue(forKey: id)
                default: delivery = "\(name): \(detail)"; commands.removeValue(forKey: id)
                }
            } else if Date().timeIntervalSince(time) > 32 {
                delivery = "No acknowledgement from \(name). Check the chat before repeating."
                commands.removeValue(forKey: id)
            }
        }
    }
    func send(_ verb: String, _ s: S, text: String = "", tracked: Bool = false) {
        if demo { notice = "Demo: \(verb) → \(label(s))"; return }
        let id = UUID().uuidString
        do {
            try atomicJSON(["id": id, "session": s.id, "instance": s.instance, "verb": verb,
                            "text": text, "ts": Date().timeIntervalSince1970 * 1000], path: "\(dir)/cmd-\(s.id)-\(id).json")
            if tracked { commands[id] = (label(s), Date()); delivery = "Sending to \(label(s))…" }
        } catch { notice = "Couldn't send to \(label(s)): \(error.localizedDescription)" }
    }
    func select(_ s: S, read: Bool = true) {
        do {
            if !demo { try atomicJSON(["session": s.id, "instance": s.instance], path: "\(dir)/selection.json") }
            if let current = speaking { send("stop", current) }
            activeID = s.id; activeInstance = s.instance
            notice = "Talking to \(label(s))."; heard = ""
            if settings.follow { openChat(s) }
            if read { send("read", s) }
        } catch { notice = "Couldn't select that session: \(error.localizedDescription)" }
    }
    func move(_ delta: Int) {
        guard !all.isEmpty else { notice = "No connected sessions yet. Open a Claude Code chat with the mod loaded."; return }
        let index = all.firstIndex { $0.id == activeID } ?? (delta > 0 ? -1 : 0)
        select(all[(index + delta + all.count) % all.count])
    }
    func selectNamed(_ name: String) {
        let candidates = all.map { VoiceCandidate(id: $0.id, names: [label($0), $0.name, ($0.cwd as NSString).lastPathComponent]) }
        let matches = matchingSessions(name, candidates: candidates)
        if matches.count == 1, let s = all.first(where: { $0.id == matches[0] }) { select(s) }
        else if matches.isEmpty { notice = "No session matches ‘\(name)’. Try its name or give it a voice name." }
        else { notice = "More than one session matches ‘\(name)’. Use a unique voice name." }
    }
    func rename(_ s: S) {
        let alert = NSAlert(); alert.messageText = "Voice name"
        alert.informativeText = "A short name, such as Printers, that you can say to switch here."
        let field = NSTextField(string: label(s)); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { aliases[s.id] = name; if !demo { prefs.set(aliases, forKey: "voiceAliases") } }
        }
    }
    func voice(_ event: [String: Any]) {
        let kind = event["event"] as? String ?? ""
        if kind == "error" {
            notice = event["text"] as? String ?? "Speech recognition failed"
            update { $0.voice = false }; captures.removeAll(); speechIDs.removeAll(); heard = ""
            return
        }
        if kind == "ready" { notice = "Listening on this Mac. Speak to the selected session."; return }
        guard let id = event["id"] as? String else { return }
        if kind == "begin" {
            speechIDs.insert(id)
            if let s = selected { captures[id] = SpeechDestination(session: s.id, instance: s.instance, request: s.pending.first?.id) }
            if let current = speaking, current.phase == "speaking" { send("toggle", current) }
            heard = "Listening…"; return
        }
        if kind == "cancel" { speechIDs.remove(id); captures.removeValue(forKey: id); heard = ""; return }
        guard speechIDs.contains(id) else { return }
        let text = event["text"] as? String ?? ""
        if kind == "partial" { heard = text; return }
        guard kind == "final" else { return }
        speechIDs.remove(id)
        let destination = captures.removeValue(forKey: id)
        heard = text
        switch voiceIntent(text, wake: settings.wake) {
        case .next: move(1)
        case .previous: move(-1)
        case .select(let name): selectNamed(name)
        case .cancel:
            notice = "Message discarded."; heard = ""
            if let current = speaking, current.phase == "paused" { send("toggle", current) }
        case .open: if let s = selected { openChat(s) }
        case .stopSpeech: if let s = speaking { send("stop", s) }; notice = "Speech stopped."
        case .pause: if let s = speaking, s.phase == "speaking" { send("toggle", s) }
        case .resume: if let s = speaking, s.phase == "paused" { send("toggle", s) }
        case .approve: answer("approve action", destination: destination, permission: true)
        case .deny: answer("deny action", destination: destination, permission: true)
        case .stopWork:
            guard let s = validDestination(destination) else { return }
            send("abort", s, tracked: true)
        case .dictate(let message):
            guard !message.isEmpty, let s = validDestination(destination) else { return }
            if let current = speaking { send("stop", current) }
            if let request = s.pending.first {
                if request.kind == "permission" { notice = "Say ‘approve action’ or ‘deny action’ for the displayed request." }
                else { answer(message, destination: destination, permission: false) }
            } else { send("reply", s, text: message, tracked: true) }
        }
    }
    func validDestination(_ destination: SpeechDestination?) -> S? {
        guard let d = destination, let s = selected,
              destinationIsCurrent(d, session: s.id, instance: s.instance, request: s.pending.first?.id) else {
            notice = "The session or request changed while you spoke. Select the session and repeat."
            return nil
        }
        return s
    }
    func answer(_ text: String, destination: SpeechDestination?, permission: Bool) {
        guard let s = validDestination(destination), let request = s.pending.first else { notice = "No matching request is waiting."; return }
        guard (request.kind == "permission") == permission else { notice = "That command doesn't match this request."; return }
        if demo { notice = "Demo response: \(text)"; return }
        do {
            try atomicJSON(["session": s.id, "instance": s.instance, "request": request.id, "text": text,
                            "ts": Date().timeIntervalSince1970 * 1000], path: "\(dir)/answer-\(request.id).json")
            commands[request.id] = (label(s), Date()); delivery = "Sending response to \(label(s))…"
        } catch { notice = "Couldn't send response: \(error.localizedDescription)" }
    }
    func clickAnswer(_ text: String, _ s: S) {
        guard s.id == activeID, s.instance == activeInstance else { select(s, read: false); return }
        answer(text, destination: SpeechDestination(session: s.id, instance: s.instance, request: s.pending.first?.id), permission: s.pending.first?.kind == "permission")
    }
    func loadDemo() {
        let now = Date().timeIntervalSince1970 * 1000
        for (id, name, work, ready) in [("printers", "Printers", "question", true), ("portfolio", "Portfolio", "working", false), ("home", "Home Assistant", "idle", true)] {
            let pending: [[String: Any]] = id == "printers" ? [["id": "demo-question", "kind": "question", "question": "Which calibration should we review?", "options": ["Clear to black", "Grey patches"]]] : []
            let json: [String: Any] = ["id": id, "instance": "demo", "local": "", "name": name, "cwd": "/demo/\(name)", "phase": "idle", "work": work, "ts": now, "startedAt": now + Double(all.count), "i": 0, "n": 0, "text": "", "ready": ready, "pending": pending]
            if let data = try? JSONSerialization.data(withJSONObject: json), let s = try? JSONDecoder().decode(S.self, from: data) { all.append(s) }
        }
        if let s = all.first { select(s, read: false) }
        notice = "Preview with simulated sessions. Microphone is off."
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}
struct Card: View {
    @ObservedObject var store: Store
    func state(_ s: S) -> String {
        if s.work == "permission" { return "Approval needed" }
        if s.work == "question" { return "Needs your answer" }
        if s.work == "working" { return "Working" }
        return s.ready ? "Ready for follow-up" : "Ready"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CLAUDE CONVERSATION").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
                    Text(store.selected.map { store.label($0) } ?? (store.activeID.isEmpty ? "Choose a session" : "Selected session disconnected"))
                        .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                }
                Spacer()
                Button {
                    store.update { $0.voice.toggle() }
                    (NSApp.delegate as? AppDelegate)?.applyVoice()
                } label: { Image(systemName: store.settings.voice ? "mic.fill" : "mic.slash").frame(width: 30, height: 30).background(Circle().fill(store.settings.voice ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))) }
                .buttonStyle(.plain).help(store.settings.voice ? "Stop listening" : "Start hands-free conversation")
                settingsMenu
            }
            Text(store.settings.voice ? "Listening · say “switch to Printers” or “next session”" : "Microphone off · click the microphone to start")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !store.heard.isEmpty { Text(store.heard).font(.system(size: 12)).lineLimit(3).textSelection(.enabled) }
            Divider()
            if store.all.isEmpty {
                Text("Open a Claude Code session with the mod loaded. Connected sessions will appear here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.all) { s in
                            Button { store.select(s) } label: {
                                HStack(spacing: 9) {
                                    StatusDot(color: s.work == "permission" || s.work == "question" ? .orange : s.work == "working" ? .blue : .green)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(store.label(s)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(state(s)).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if s.id == store.activeID && s.instance == store.activeInstance { Image(systemName: "waveform").foregroundStyle(.orange) }
                                }.padding(9).contentShape(Rectangle())
                                    .background(RoundedRectangle(cornerRadius: 9).fill(s.id == store.activeID ? Color.orange.opacity(0.1) : Color.clear))
                            }.buttonStyle(.plain)
                                .contextMenu { Button("Voice name…") { store.rename(s) }; Button("Open in Claude") { openChat(s) } }
                        }
                    }
                }.frame(maxHeight: 205)
            }
            if let s = store.selected, let request = s.pending.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.kind == "permission" ? "APPROVAL · THIS ACTION ONLY" : "YOUR ANSWER").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.orange)
                    Text(request.question).font(.system(size: 12, weight: .medium))
                    if let tool = request.tool { Text(tool).font(.system(size: 11, weight: .semibold)) }
                    if let detail = request.detail {
                        ScrollView { Text(detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    }
                    if request.kind == "permission" {
                        HStack { Button("Approve once") { store.clickAnswer("approve action", s) }; Button("Deny") { store.clickAnswer("deny action", s) } }.controlSize(.small)
                        Text("Say “approve action” or “deny action”.").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        ForEach(request.options ?? [], id: \.self) { option in
                            Button(option) { store.clickAnswer(option, s) }.controlSize(.small)
                        }
                        Text(request.multiSelect == true ? "Say all your choices, or answer in your own words." : "Answer in your own words.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
            }
            if let s = store.speaking {
                HStack {
                    Text("Speaking · \(store.label(s))").font(.system(size: 10)).lineLimit(1)
                    Spacer()
                    Button(s.phase == "paused" ? "Resume" : "Pause") { store.send("toggle", s) }
                    Button("Stop") { store.send("stop", s) }
                }.controlSize(.mini)
                if store.settings.captions && !s.text.isEmpty { Text(s.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
            }
            if let s = store.selected, s.phase == "queued" { Button("Read reply") { store.send("play", s) }.controlSize(.small) }
            Text(store.notice).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !store.delivery.isEmpty { Text(store.delivery).font(.system(size: 10, weight: .medium)).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button { store.move(-1) } label: { Image(systemName: "chevron.left") }.help("Previous session")
                Button { store.move(1) } label: { Image(systemName: "chevron.right") }.help("Next session")
                Spacer()
                if let s = store.selected { Button("Open chat") { openChat(s) }; Button("Read again") { store.send("read", s) } }
            }.buttonStyle(.borderless).controlSize(.small)
        }
        .padding(15).frame(width: 350)
        .background(RoundedRectangle(cornerRadius: 17).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
    var settingsMenu: some View {
        Menu {
            Toggle("Natural spoken rewrite", isOn: Binding(get: { store.settings.rewrite }, set: { v in store.update { $0.rewrite = v } }))
            Toggle("Show speech captions", isOn: Binding(get: { store.settings.captions }, set: { v in store.update { $0.captions = v } }))
            Toggle("Open selected chat", isOn: Binding(get: { store.settings.follow }, set: { v in store.update { $0.follow = v } }))
            Toggle("Wait before reading replies", isOn: Binding(get: { store.settings.manual }, set: { v in store.update { $0.manual = v } }))
            Menu("Speaking speed") {
                ForEach([0, 140, 165, 210, 250], id: \.self) { rate in Button(rate == 0 ? "Default" : "\(rate) words/min") { store.update { $0.rate = rate } } }
            }
            Divider()
            if let s = store.selected { Button("Name this session for voice…") { store.rename(s) } }
            Button("Reset panel position") { (NSApp.delegate as? AppDelegate)?.resetPosition() }
            Button("Quit panel") { NSApp.terminate(nil) }
        } label: { Image(systemName: "ellipsis").frame(width: 22, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var panel: NSPanel?
    var hosting: NSHostingView<Card>?
    var voiceOffset: UInt64 = 0
    func applicationDidFinishLaunching(_ n: Notification) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 300), styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces]
        p.isMovableByWindowBackground = true; p.hidesOnDeactivate = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        let h = NSHostingView(rootView: Card(store: store)); p.contentView = h; hosting = h; panel = p
        resetPosition()
        if let x = prefs.object(forKey: "cardX") as? Double, let y = prefs.object(forKey: "cardY") as? Double,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: x, y: y)) }) { p.setFrameTopLeftPoint(NSPoint(x: x, y: y)) }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { _ in
            if !demo { prefs.set(p.frame.minX, forKey: "cardX"); prefs.set(p.frame.maxY, forKey: "cardY") }
        }
        store.refresh(); tick()
        if store.settings.voice { applyVoice() }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in self.tick() }
    }
    func applyVoice() {
        guard !demo else { return }
        if store.settings.voice {
            voiceOffset = (try? FileManager.default.attributesOfItem(atPath: "\(dir)/voice.log")[.size] as? UInt64) ?? 0
            let app = NSHomeDirectory() + "/.cache/read-aloud/ReadAloudListen.app"
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-g", "-a", app]
            do { try p.run() } catch { store.notice = "Couldn't start the microphone helper: \(error.localizedDescription)" }
        } else {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); p.arguments = ["-x", "read-aloud-listen"]; try? p.run()
            store.captures.removeAll(); store.speechIDs.removeAll(); store.heard = ""
        }
    }
    func tailVoice() {
        guard store.settings.voice, !demo, let h = FileHandle(forReadingAtPath: "\(dir)/voice.log") else { return }
        defer { try? h.close() }
        let size = h.seekToEndOfFile(); if size < voiceOffset { voiceOffset = 0 }
        h.seek(toFileOffset: voiceOffset)
        let data = h.readDataToEndOfFile()
        // Consume complete JSON lines only; the listener can be between writes.
        guard let newline = data.lastIndex(of: 10) else { return }
        let complete = data.prefix(through: newline); voiceOffset += UInt64(complete.count)
        for line in complete.split(separator: 10) {
            if let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { store.voice(event) }
        }
    }
    func tick() {
        store.refresh(); tailVoice()
        guard let p = panel, let h = hosting else { return }
        let size = h.fittingSize
        if abs(p.frame.height - size.height) > 1 {
            let top = p.frame.maxY; p.setContentSize(size); p.setFrameTopLeftPoint(NSPoint(x: p.frame.minX, y: top))
        }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(p.frame) }) { resetPosition() }
        p.orderFrontRegardless()
    }
    func resetPosition() {
        guard let p = panel, let sc = NSScreen.main else { return }
        p.setFrameTopLeftPoint(NSPoint(x: sc.visibleFrame.maxX - p.frame.width - 20, y: sc.visibleFrame.maxY - 20))
    }
    func applicationWillTerminate(_ n: Notification) {
        if store.settings.voice { store.update { $0.voice = false }; applyVoice() }
    }
}
@main struct ConversationPanel {
    static func main() {
        #if TESTING
        panelSelfTests()
        #else
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate; app.run()
        #endif
    }
}
