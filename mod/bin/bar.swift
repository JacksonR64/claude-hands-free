// Native controller for the per-session mod. No model or cloud account lives here.
import Cocoa
import Darwin
import SwiftUI

let dir = NSHomeDirectory() + "/.cache/read-aloud/conversation"
let voiceDir = dir + (demo ? "-demo" : "")
let settingsPath = NSHomeDirectory() + "/.config/read-aloud/settings.json"
let demo = CommandLine.arguments.contains("--demo") || [".preview", ".demo"].contains { Bundle.main.bundleIdentifier?.hasSuffix($0) == true }

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
    var reading = true, rewrite = true, manual = false, captions = true, follow = false, voice = false
    var wake = "okay claude"
    var dictation = "apple"   // or "handy"
    var sendDelay = 5.0
    var pauseMedia = true    // pause music or video on this Mac while the app talks or takes a message, then carry on
    var watchWindow = true   // read new replies straight from the Claude desktop window (free; needs the Sender's Accessibility permission)
    var threadInbox = "~/.cache/read-aloud/threads/inbox"   // project threads drop their messages here (see Threads.swift)
}
func loadSettings() -> Settings {
    var s = Settings()
    if let data = FileManager.default.contents(atPath: settingsPath),
       let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        s.rate = j["rate"] as? Int ?? 0; s.gap = j["gap"] as? Int ?? 4
        s.reading = j["reading"] as? Bool ?? true; s.rewrite = j["rewrite"] as? Bool ?? true; s.manual = j["manual"] as? Bool ?? false
        s.captions = j["captions"] as? Bool ?? true; s.follow = j["follow"] as? Bool ?? false
        s.voice = j["voice"] as? Bool ?? false; s.wake = j["wake"] as? String ?? "okay claude"
        s.dictation = j["dictation"] as? String ?? "apple"; s.sendDelay = j["sendDelay"] as? Double ?? 5
        s.watchWindow = j["watchWindow"] as? Bool ?? true
        s.pauseMedia = j["pauseMedia"] as? Bool ?? true
        if let inbox = j["threadInbox"] as? String, !inbox.isEmpty { s.threadInbox = inbox }
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
    old.merge(["rate": s.rate, "gap": s.gap, "reading": s.reading, "rewrite": s.rewrite, "manual": s.manual,
               "captions": s.captions, "follow": s.follow, "voice": s.voice, "wake": s.wake, "dictation": s.dictation, "pauseMedia": s.pauseMedia]) { _, new in new }
    try atomicJSON(old, path: settingsPath)
}
func openChat(_ s: S) {
    guard !demo, !s.local.isEmpty else { return }
    var parts = URLComponents(); parts.scheme = "claude"; parts.host = "code"; parts.path = "/continue"
    parts.queryItems = [URLQueryItem(name: "session", value: s.local)]
    if let url = parts.url { NSWorkspace.shared.open(url) }
}
let prefs = UserDefaults(suiteName: demo ? "read-aloud-bar.demo" : "read-aloud-bar") ?? .standard
let panelDisabledPath = dir + "/panel-disabled"

// The sandbox takes turns so speaker output cannot become a simulated user command.
final class DemoSpeaker {
    var process: Process?
    var rate = 185   // words a minute; 0 leaves the system voice at its own pace
    var audioFile: URL?
    var stateChanged: ((Bool) -> Void)?
    var failed: ((String) -> Void)?
    let marker = voiceDir + "/demo-speaking"
    func stop() {
        let previous = process; process = nil
        if previous?.isRunning == true { previous?.terminate() }
        if let file = audioFile { try? FileManager.default.removeItem(at: file) }
        audioFile = nil
        try? FileManager.default.removeItem(atPath: marker)
        stateChanged?(false)
    }
    func speak(_ text: String) {
        stop()
        let file = URL(fileURLWithPath: voiceDir).appendingPathComponent("reply-\(UUID().uuidString).aiff")
        let render = Process()
        render.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        render.arguments = (rate > 0 ? ["-r", String(rate)] : []) + ["-o", file.path, "--", text]
        render.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, self.process === finished else { try? FileManager.default.removeItem(at: file); return }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
                guard finished.terminationStatus == 0, bytes > 54 else {
                    self.stop(); self.failed?("Speech generation failed. Captions remain available."); return
                }
                let player = Process()
                player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                player.arguments = [file.path]
                player.terminationHandler = { [weak self] playback in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard let self = self, self.process === playback else { try? FileManager.default.removeItem(at: file); return }
                        let ok = playback.terminationStatus == 0
                        self.stop()
                        if !ok { self.failed?("Couldn't play the demo reply. Check the Mac's audio output.") }
                    }
                }
                do {
                    self.process = player
                    try player.run()
                } catch { self.stop(); self.failed?("Couldn't play the demo reply: \(error.localizedDescription)") }
            }
        }
        do {
            try atomicJSON([:], path: marker)
            audioFile = file; process = render; stateChanged?(true)
            try render.run()
        } catch { stop(); failed?("Couldn't speak the demo reply: \(error.localizedDescription)") }
    }
}

final class Store: ObservableObject {
    @Published var showInDock = prefs.object(forKey: "showInDock") as? Bool ?? true
    @Published var mode = PanelMode(rawValue: prefs.string(forKey: "presentationMode") ?? "") ?? .menuBar
    @Published var autoExpand = prefs.bool(forKey: "autoExpand")
    @Published var autoCollapse = prefs.object(forKey: "autoCollapse") as? Bool ?? true
    @Published var hoverExpand = prefs.object(forKey: "hoverExpand") as? Bool ?? true
    @Published var edgeSide = prefs.string(forKey: "edgeSide") ?? "right"
    @Published var all: [S] = []
    func savePresentation() {
        prefs.set(mode.rawValue, forKey: "presentationMode")
        prefs.set(autoExpand, forKey: "autoExpand")
        prefs.set(autoCollapse, forKey: "autoCollapse")
        prefs.set(hoverExpand, forKey: "hoverExpand")
        prefs.set(edgeSide, forKey: "edgeSide")
        (NSApp.delegate as? AppDelegate)?.presentationChanged()
    }
    @Published var audioDisplay = AudioDisplay(rawValue: prefs.string(forKey: "audioDisplay") ?? "") ?? .both
    @Published var allowInterruption = prefs.bool(forKey: "allowInterruption")
    @Published var userCaption = ""
    @Published var sendEndsAt: Double?   // ms since 1970: when the dictated message will be sent
    @Published var assistantCaption = ""
    @Published var demoSecondsRemaining = 120
    var demoStop: (() -> Void)?
    var lastAudioRefresh = 0.0
    func saveAudioPreferences() {
        prefs.set(audioDisplay.rawValue, forKey: "audioDisplay")
        prefs.set(allowInterruption, forKey: "allowInterruption")
        let marker = voiceDir + "/allow-interruption"
        do {
            if allowInterruption { try atomicJSON([:], path: marker) }
            else { try? FileManager.default.removeItem(atPath: marker) }
        } catch { notice = "Couldn't save microphone preferences: \(error.localizedDescription)" }
    }
    func demoSay(_ text: String) {
        guard demo else { return }
        assistantCaption = text
        demoOutput?(text)
    }
    var demoOutput: ((String) -> Void)?
    var voiceChanged: (() -> Void)?
    @Published var demoSpeaking = false
    @Published var audio: AudioSnapshot?
    @Published var inputHistory = Array(repeating: 0.0, count: 24)
    @Published var voiceError = ""
    @Published var voiceStartedAt = 0.0
    @Published var audioPhase: MicrophonePhase = .off
    var isSpeaking: Bool { demoSpeaking || speaking != nil }
    var audioColor: Color {
        switch audioPhase {
        case .speaking: return .blue
        case .input, .recognizing: return .green
        case .noAudio, .error: return .red
        case .starting, .retrying: return .orange
        default: return .secondary
        }
    }
    func refreshAudio(now: Double = Date().timeIntervalSince1970) {
        if now - lastAudioRefresh < (audioDisplay == .captions ? 0.3 : 0.1) { return }
        lastAudioRefresh = now
        if settings.voice, let data = FileManager.default.contents(atPath: voiceDir + "/audio.json"),
           let snapshot = try? JSONDecoder().decode(AudioSnapshot.self, from: data) { audio = snapshot }
        audioPhase = microphonePhase(enabled: settings.voice, speaking: isSpeaking,
            recognizing: !speechIDs.isEmpty, failed: !voiceError.isEmpty,
            startedAt: voiceStartedAt, snapshot: audio, now: now)
        guard audioDisplay != .captions else { return }
        inputHistory.removeFirst()
        let fresh = audio.map { now - $0.lastBufferAt < 2 && now - $0.ts < 3 } ?? false
        inputHistory.append(settings.voice && fresh && !isSpeaking ? normalizedInputLevel(audio?.db ?? -100) : 0)
    }
    @Published var settings = loadSettings()
    @Published var activeID = ""
    @Published var activeInstance = ""
    @Published var heard = ""
    @Published var notice = "Choose a session, then turn on the microphone."
    @Published var delivery = ""
    @Published var aliases = prefs.dictionary(forKey: "voiceAliases") as? [String: String] ?? [:]
    var captures: [String: SpeechDestination] = [:]
    // Handy dictation: started by voice, ended by silence, delivered after the countdown
    struct HandySession { var afterID: Int64; var destination: SpeechDestination?; var started = Date(); var lastSpeech = Date(); var sawSpeech = false; var stopping = false }
    var handySession: HandySession?
    var handyHeld: (text: String, destination: SpeechDestination?, deadline: Date)?
    func startHandy(_ destination: SpeechDestination?) {
        guard !demo, handySession == nil, handyHeld == nil else { return }
        guard handyInstalled() else { notice = "Handy isn't installed in /Applications."; return }
        handySession = HandySession(afterID: handyLastID(), destination: destination)
        handyRun("--toggle-transcription")
        heard = "Dictating with Handy… speak, then pause"
        let method = handyPasteMethod() ?? "ctrl_v"
        notice = method == "none" ? "Handy is recording." : "Handy is recording. It will also type into the front app: set Handy's Paste method to None."
    }
    func tickHandy() {
        let now = Date()
        if let held = handyHeld {
            if now >= held.deadline { deliverHeld() }
            return
        }
        guard var h = handySession else { return }
        if let row = handyTranscript(after: h.afterID) {
            handySession = nil
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { notice = "Handy heard nothing."; heard = ""; return }
            handyHeld = (text, h.destination, now.addingTimeInterval(settings.sendDelay))
            sendEndsAt = handyHeld!.deadline.timeIntervalSince1970 * 1000; userCaption = text
            if settings.sendDelay <= 0 { deliverHeld() }
            return
        }
        if h.sawSpeech && !h.stopping && now.timeIntervalSince(h.lastSpeech) > 2.5 { h.stopping = true; handyRun("--toggle-transcription"); heard = "Transcribing…" }
        else if now.timeIntervalSince(h.started) > 120 { handyRun("--cancel"); handySession = nil; heard = ""; notice = "Handy dictation timed out."; return }
        handySession = h
    }
    func deliverHeld() {
        guard let held = handyHeld else { return }
        handyHeld = nil; sendEndsAt = nil
        let id = UUID().uuidString
        speechIDs.insert(id); captures[id] = held.destination
        voice(["event": "final", "id": id, "text": held.text])
    }
    func sendNowPressed() {
        if handyHeld != nil { deliverHeld() } else { FileManager.default.createFile(atPath: voiceDir + "/send-now", contents: Data()) }
    }
    func cancelSendPressed() {
        if handyHeld != nil { handyHeld = nil; sendEndsAt = nil; heard = ""; notice = "Message discarded." }
        else { FileManager.default.createFile(atPath: voiceDir + "/cancel-utterance", contents: Data()) }
    }
    var speechIDs = Set<String>()
    var commands: [String: (String, Date)] = [:]
    // Project threads and the numbered waiting list (logic in Threads.swift)
    @Published var book = ThreadBook()
    @Published var sessionNumbers: [String: Int] = [:]
    var speechQueue: [String] = []
    var replyTarget: (number: Int, armedAt: Date)?
    var sends: [String: (item: String, number: Int, name: String, started: Date)] = [:]
    var handledDrops = Set<String>()
    var threadEvents = Set<String>()
    var lastThreadScan = 0.0, lastAppSpeechEnd = 0.0
    var holdingSpeechLock = false
    var queueWaitingSince = 0.0
    var messageExpectedUntil = 0.0, quietSince = 0.0, mediaBusy = false, mediaPausedAt = 0.0
    @Published var mediaPaused = false
    var windowSeen: [String: Set<String>] = [:]
    var windowPending: [String: Double] = [:]
    var lastAnnounced: [String: Double] = [:], lastDropped: [String: Double] = [:]
    var lastWindowScan = 0.0, lastWindowStamp = 0.0
    @Published var windowTrusted = true
    var appSay: ((String) -> Void)?
    var appStop: (() -> Void)?
    var appSpeechBusy: (() -> Bool)?
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
            refreshNumbers()
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
        refreshNumbers(); pollSends()
    }
    func send(_ verb: String, _ s: S, text: String = "", tracked: Bool = false) {
        if demo {
            if verb == "read" { notice = demoSummary(s) }
            else if verb == "reply" {
                notice = "Message captured in \(label(s)). Say ask me a question or next session to continue the scripted demo."
            } else { notice = "Demo: \(verb) → \(label(s))" }
            return
        }
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
            voiceError = notice
            update { $0.voice = false }; voiceChanged?(); captures.removeAll(); speechIDs.removeAll(); heard = ""
            return
        }
        if kind == "diagnostic" {
            notice = event["text"] as? String ?? "Speech recognition is retrying."
            if notice.hasPrefix("Listening for your message") { messageExpectedUntil = Date().timeIntervalSince1970 + 8 }
            return
        }
        if kind == "ready" {
            notice = demo ? "Offline demo. " + (selected.map { demoSummary($0) } ?? "Choose a session.") + "" : "Listening on this Mac. Speak to the selected session."
            if demo { demoSay(notice) }
            return
        }
        if handySession != nil, kind == "begin" || kind == "partial" { handySession?.sawSpeech = true; handySession?.lastSpeech = Date(); return }
        if handySession != nil || handyHeld != nil { return }   // while Handy dictates, the Apple recogniser only signals that you are talking
        guard let id = event["id"] as? String else { return }
        if kind == "begin" {
            if demo && allowInterruption { demoStop?() }
            speechIDs.insert(id)
            if let s = selected { captures[id] = SpeechDestination(session: s.id, instance: s.instance, request: s.pending.first?.id) }
            if let current = speaking, current.phase == "speaking" { send("toggle", current) }
            heard = "Listening…"; return
        }
        if kind == "cancel" { speechIDs.remove(id); captures.removeValue(forKey: id); heard = ""; sendEndsAt = nil; return }
        if kind == "resume" { sendEndsAt = nil; return }
        guard speechIDs.contains(id) else { return }
        let text = event["text"] as? String ?? ""
        if kind == "partial" { heard = text; userCaption = text; sendEndsAt = nil; return }
        if kind == "pending" { sendEndsAt = Double(text); return }
        guard kind == "final" else { return }
        sendEndsAt = nil
        speechIDs.remove(id)
        let destination = captures.removeValue(forKey: id)
        heard = text; userCaption = text
        var respond = true
        defer { if demo && respond { demoSay(notice) } }
        let intent = demo && normalized(text) == "stop" ? VoiceIntent.stopListening : voiceIntent(text, wake: settings.wake)
        if demo, case .dictate(let message) = intent {
            let events = ["ask me a question": "question", "show an approval": "permission", "finish work": "finished", "all quiet": "quiet", "reset demo": "reset"]
            if let kind = events[normalized(message)] {
                demoEvent(kind)
                if let s = selected { notice = demoSummary(s) }
                return
            }
        }
        switch intent {
        case .startDictation:
            if settings.dictation == "handy" { startHandy(destination) } else { notice = "Say your message." }
        case .stopListening:
            update { $0.voice = false }; voiceChanged?(); notice = "Microphone off."
        case .readAgain: if let s = selected { send("read", s) }
        case .next: move(1)
        case .previous: move(-1)
        case .select(let name): selectNamed(name)
        case .whoIsWaiting: sayWaiting()
        case .replyTo(let number, let message): reply(number, message)
        case .readItem(let number): readRow(number)
        case .openItem(let number): openRow(number)
        case .dismissItem(let number): dismissRow(number)
        case .cancel:
            replyTarget = nil
            notice = "Message discarded."; heard = ""
            if let current = speaking, current.phase == "paused" { send("toggle", current) }
        case .open: if let s = selected { openChat(s) }
        case .stopSpeech: if let s = speaking { send("stop", s) }; stopAppSpeech(); notice = "Speech stopped."
        case .pause: if let s = speaking, s.phase == "speaking" { send("toggle", s) }
        case .resume: if let s = speaking, s.phase == "paused" { send("toggle", s) }
        case .approve: answer("approve action", destination: destination, permission: true)
        case .deny: answer("deny action", destination: destination, permission: true)
        case .stopWork:
            guard let s = validDestination(destination) else { return }
            send("abort", s, tracked: true)
        case .dictate(let message):
            if let target = replyTarget {   // "reply to number four", then the message
                replyTarget = nil
                if !message.isEmpty, Date().timeIntervalSince(target.armedAt) < 90 { reply(target.number, message); return }
            }
            guard !message.isEmpty, let s = validDestination(destination) else { return }
            if let current = speaking { send("stop", current) }
            if let request = s.pending.first {
                if request.kind == "permission" { notice = "Say ‘approve action’ or ‘deny action’ for the displayed request." }
                else { answer(message, destination: destination, permission: false) }
            } else {
                send("reply", s, text: message, tracked: true)
                if demo { respond = false } // Unscripted background speech is captioned, never echoed aloud.
            }
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
        if demo {
            demoEvent("quiet")
            notice = request.kind == "permission"
                ? "\(label(s)). Simulated action \(text == "approve action" ? "approved" : "denied"). Nothing was executed."
                : "\(label(s)). You answered: \(text). Say next session."
            return
        }
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
    func demoSpeech(_ text: String) {
        guard demo, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = UUID().uuidString
        voice(["event": "begin", "id": id])
        voice(["event": "final", "id": id, "text": text])
    }

    func demoSummary(_ s: S) -> String {
        if let request = s.pending.first {
            return "\(label(s)). \(request.question) " + (request.kind == "permission" ? "Say approve action or deny action." : "")
        }
        if s.work == "working" { return "\(label(s)) is working. Say finish work, or next session." }
        return "\(label(s)) is ready. Say ask me a question, or next session."
    }
    func demoEvent(_ kind: String) {
        guard demo else { return }
        if kind == "reset" { all = []; activeID = ""; activeInstance = ""; loadDemo(); return }
        guard let original = selected ?? all.first else { return }
        let request = Request(id: UUID().uuidString, kind: kind == "permission" ? "permission" : "question",
            question: kind == "permission" ? "Allow this simulated action once?" : "Which calibration should we review?",
            options: kind == "permission" ? nil : ["Grey patches", "Clear to black"],
            detail: kind == "permission" ? #"{"command":"echo This is a simulated approval; nothing executes"}"# : nil,
            tool: kind == "permission" ? "Bash (simulation)" : nil, multiSelect: false)
        let waits = kind == "question" || kind == "permission"
        let changed = S(id: original.id, instance: original.instance, local: "", name: original.name, cwd: original.cwd,
            phase: "idle", work: waits ? kind : "idle", ts: original.ts, startedAt: original.startedAt, i: 0, n: 0,
            text: "", ready: kind == "finished", pending: waits ? [request] : [])
        if let index = all.firstIndex(where: { $0.id == original.id }) { all[index] = changed }
        notice = "Demo: " + (kind == "finished" ? "work completed." : waits ? "new request." : "all quiet.")
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

struct AudioActivityView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: store.isSpeaking ? "speaker.wave.2.fill" : "mic.fill")
                    .symbolEffect(.pulse, isActive: store.isSpeaking && store.audioDisplay != .captions)
                Text(store.isSpeaking && store.allowInterruption ? "Replying · speak to interrupt" : store.audioPhase.label).font(.system(size: 11, weight: .medium))
                Spacer()
                if store.settings.voice, let audio = store.audio, store.audioDisplay != .captions {
                    Text("\(Int(audio.db)) dB").font(.system(size: 9, design: .monospaced)).monospacedDigit()
                }
            }.foregroundStyle(store.audioColor)
            if store.audioDisplay != .captions {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(store.inputHistory.indices, id: \.self) { index in
                        Capsule().fill(store.audioColor.opacity(0.85)).frame(height: 3 + 20 * store.inputHistory[index])
                    }
                }.frame(height: 24).animation(.linear(duration: 0.1), value: store.inputHistory)
                    .accessibilityLabel("Measured microphone input level")
            }
            if let ends = store.sendEndsAt {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let left = max(0, ends / 1000 - context.date.timeIntervalSince1970)
                    HStack(spacing: 8) {
                        ProgressView(value: min(1, left / 5)).progressViewStyle(.linear).tint(.orange).frame(width: 60)
                        Text("Sending in \(Int(ceil(left)))s").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        Spacer(minLength: 4)
                        Button("Send now") { store.sendNowPressed() }
                        Button("Cancel") { store.cancelSendPressed() }
                    }.controlSize(.mini)
                }
            }
            if store.audioDisplay != .waveform {
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOU").font(.system(size: 8, weight: .bold)).foregroundStyle(.green)
                    Text(store.userCaption.isEmpty ? "Your words appear here." : store.userCaption)
                        .font(.system(size: 12)).lineLimit(3).textSelection(.enabled)
                    Text(demo ? "DEMO" : "ASSISTANT").font(.system(size: 8, weight: .bold)).foregroundStyle(.blue)
                    Text(store.assistantCaption.isEmpty ? "Spoken replies appear here." : store.assistantCaption)
                        .font(.system(size: 12)).lineLimit(4).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if store.settings.voice {
                Text(store.audio?.input ?? "Waiting for microphone…").font(.system(size: 9)).foregroundStyle(.secondary)
                if store.audioPhase == .noAudio {
                    Text("No input: check macOS Sound settings, then restart the microphone.").font(.system(size: 10)).foregroundStyle(.red)
                }
            }
            if !store.voiceError.isEmpty { Text(store.voiceError).font(.system(size: 10)).foregroundStyle(.red) }
            if demo {
                HStack {
                    Button("Stop demo") { (NSApp.delegate as? AppDelegate)?.stopListening() }
                        .keyboardShortcut(".", modifiers: .command)
                    Spacer()
                    Button("Quit demo") { (NSApp.delegate as? AppDelegate)?.quitPanel() }
                }.controlSize(.small)
                HStack {
                    Button("Test speaker") { store.demoSay("Speaker test. If you can hear this, playback is working.") }
                    if store.settings.voice {
                        Button("Restart microphone") { (NSApp.delegate as? AppDelegate)?.applyVoice() }
                    }
                }.controlSize(.small)
                Text(store.settings.voice ? "Auto-stop in \(store.demoSecondsRemaining)s · say “stop demo”" : "Two-minute trials · closing or hiding stops audio")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Stop listening") { (NSApp.delegate as? AppDelegate)?.stopListening() }.keyboardShortcut(".", modifiers: .command)
                    Spacer()
                    Button("Quit") { (NSApp.delegate as? AppDelegate)?.quitPanel() }
                }.controlSize(.small)
                if store.settings.voice {
                    Text("Listening until stopped · hiding keeps the microphone on").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if store.allowInterruption { Text("Voice interruption on · use headphones to prevent echo.").font(.system(size: 9)).foregroundStyle(.orange) }
        }.padding(9).background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.07)))
    }
}
struct Card: View {
    @ObservedObject var store: Store
    @State private var demoCommand = ""
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
                    Text("CLAUDE HANDS FREE").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
                    Text(store.selected.map { store.label($0) } ?? (store.activeID.isEmpty ? "Choose a session" : "Selected session disconnected"))
                        .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                }
                Spacer()
                Button {
                    store.update { $0.voice.toggle() }
                    (NSApp.delegate as? AppDelegate)?.applyVoice()
                } label: { Image(systemName: store.settings.voice ? "mic.fill" : "mic.slash").frame(width: 30, height: 30).background(Circle().fill(store.settings.voice ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))) }
                .buttonStyle(.plain).help(store.settings.voice ? "Stop listening" : demo ? "Start the offline hands-free demo" : "Start hands-free conversation")
                Button { (NSApp.delegate as? AppDelegate)?.hidePanel() } label: {
                    Image(systemName: "xmark").frame(width: 20, height: 28)
                }.buttonStyle(.plain).help("Hide until you open it again").keyboardShortcut(.escape, modifiers: [])
                settingsMenu
            }
            Text(demo ? (store.settings.voice ? (store.demoSpeaking ? "OFFLINE DEMO · speaking · your turn follows" : "OFFLINE DEMO · local speech · no Claude usage") : "OFFLINE DEMO · click microphone for hands-free") : store.settings.voice ? "Listening · say “who's waiting” or “reply to number one …”" : "Microphone off · click the microphone to start")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            AudioActivityView(store: store)

            if demo {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Simulate speech: next session", text: $demoCommand)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: demoCommand) { _, _ in (NSApp.delegate as? AppDelegate)?.noteInteraction() }
                        .onSubmit { store.demoSpeech(demoCommand); demoCommand = "" }
                    HStack {
                        Button("Question") { store.demoEvent("question") }
                        Button("Approval") { store.demoEvent("permission") }
                        Button("Finished") { store.demoEvent("finished") }
                    }.controlSize(.small)
                    HStack {
                        Button("All quiet") { store.demoEvent("quiet") }
                        Button("Reset demo") { store.demoEvent("reset") }
                    }.controlSize(.small)
                }
            }
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
            if !store.waitingRows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("WAITING ON YOU").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.orange)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(store.waitingRows) { row in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(row.number)").font(.system(size: 15, weight: .bold)).monospacedDigit().frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(row.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 4)
                                    Button("Read") { store.readRow(row.number) }
                                    Button("Open") { store.openRow(row.number) }
                                }.controlSize(.mini).padding(6)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.06)))
                                    .contextMenu { Button("Dismiss") { store.dismissRow(row.number) } }
                            }
                        }
                    }.frame(maxHeight: 170)
                    Text("Say “reply to number \(store.waitingRows[0].number)”, then your message.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
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
            if !demo && store.settings.watchWindow && !store.windowTrusted {
                Text("To read Claude's replies aloud, turn on “Claude Hands Free Sender” in System Settings › Privacy & Security › Accessibility.")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
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
            Menu("Audio display") {
                ForEach(AudioDisplay.allCases, id: \.rawValue) { display in
                    Button((store.audioDisplay == display ? "✓ " : "") + display.title) {
                        store.audioDisplay = display; store.saveAudioPreferences()
                    }
                }
            }
            Toggle("Voice interruption (headphones)", isOn: Binding(get: { store.allowInterruption }, set: { store.allowInterruption = $0; store.saveAudioPreferences() }))
            if !demo {
                Toggle("Show in Dock", isOn: Binding(get: { store.showInDock }, set: {
                    store.showInDock = $0; prefs.set($0, forKey: "showInDock")
                    NSApp.setActivationPolicy($0 ? .regular : .accessory)
                }))
            }
            Menu("Show as") {
                ForEach(PanelMode.allCases, id: \.rawValue) { mode in
                    Button((store.mode == mode ? "✓ " : "") + mode.title) { store.mode = mode; store.savePresentation() }
                }
            }
            if store.mode == .edge {
                Menu("Screen side") {
                    Button((store.edgeSide == "left" ? "✓ " : "") + "Left") { store.edgeSide = "left"; store.savePresentation() }
                    Button((store.edgeSide == "right" ? "✓ " : "") + "Right") { store.edgeSide = "right"; store.savePresentation() }
                }
            }
            Toggle("Expand on hover", isOn: Binding(get: { store.hoverExpand }, set: { store.hoverExpand = $0; store.savePresentation() }))
            Toggle("Collapse when idle", isOn: Binding(get: { store.autoCollapse }, set: { store.autoCollapse = $0; store.savePresentation() }))
            Toggle("Pop up for new requests or finished work", isOn: Binding(get: { store.autoExpand }, set: { store.autoExpand = $0; store.savePresentation() }))
            Button("Hide until I open it") { (NSApp.delegate as? AppDelegate)?.hidePanel() }
            Divider()
            Toggle("Natural spoken rewrite", isOn: Binding(get: { store.settings.rewrite }, set: { v in store.update { $0.rewrite = v } }))
            Toggle("Show speech captions", isOn: Binding(get: { store.settings.captions }, set: { v in store.update { $0.captions = v } }))
            Toggle("Open selected chat", isOn: Binding(get: { store.settings.follow }, set: { v in store.update { $0.follow = v } }))
            Toggle("Pause music while talking or listening", isOn: Binding(get: { store.settings.pauseMedia }, set: { v in store.update { $0.pauseMedia = v } }))
            Toggle("Read replies aloud", isOn: Binding(get: { store.settings.reading }, set: { v in store.update { $0.reading = v }; if !v { store.stopAppSpeech() }; if !v, let s = store.speaking { store.send("stop", s) } }))
            if handyInstalled() {
                Picker("Dictation", selection: Binding(get: { store.settings.dictation }, set: { v in store.update { $0.dictation = v } })) {
                    Text("Apple on-device").tag("apple"); Text("Handy").tag("handy")
                }
            }
            Toggle("Wait before reading replies", isOn: Binding(get: { store.settings.manual }, set: { v in store.update { $0.manual = v } }))
            Menu("Speaking speed") {
                ForEach([0, 140, 165, 210, 250], id: \.self) { rate in Button(rate == 0 ? "Default" : "\(rate) words/min") { store.update { $0.rate = rate } } }
            }
            Divider()
            if let s = store.selected { Button("Name this session for voice…") { store.rename(s) } }
            Button("Reset panel position") { (NSApp.delegate as? AppDelegate)?.resetPosition() }
            Button("Quit · stop background relaunch") { (NSApp.delegate as? AppDelegate)?.quitPanel() }
        } label: { Image(systemName: "ellipsis").frame(width: 22, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
    }
}

final class ConversationWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct CompactTab: View {
    @ObservedObject var store: Store
    var body: some View {
        Button { (NSApp.delegate as? AppDelegate)?.showPanel() } label: {
            VStack(spacing: 3) {
                if store.settings.voice && !store.isSpeaking && store.audioDisplay != .captions {
                    HStack(spacing: 2) {
                        ForEach(0..<5) { index in
                            Capsule().fill(store.audioColor)
                                .frame(width: 2, height: 3 + 13 * store.inputHistory[store.inputHistory.count - 5 + index])
                        }
                    }.frame(width: 18, height: 18).animation(.linear(duration: 0.1), value: store.inputHistory)
                } else {
                    Image(systemName: store.isSpeaking ? "speaker.wave.2.fill" : "waveform")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(store.audioColor)
                        .symbolEffect(.pulse, isActive: store.isSpeaking)
                }
                if !store.waitingRows.isEmpty { Circle().fill(.orange).frame(width: 5, height: 5) }
            }.frame(width: store.mode == .edge ? 26 : 36, height: store.mode == .edge ? 48 : 36)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        }.buttonStyle(.plain).help("Open Claude Hands Free")
            .onHover { (NSApp.delegate as? AppDelegate)?.hoverCompact($0) }
            .contextMenu {
                Button("Open") { (NSApp.delegate as? AppDelegate)?.showPanel() }
                Button("Hide until I open it") { (NSApp.delegate as? AppDelegate)?.hidePanel() }
                Button("Quit · stop background relaunch") { (NSApp.delegate as? AppDelegate)?.quitPanel() }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = Store()
    var presentation = PanelPresentation()
    var panel: NSPanel?
    var compact: NSPanel?
    var hosting: NSHostingView<Card>?
    var statusItem: NSStatusItem?
    let popover = NSPopover()
    var hoverTask: DispatchWorkItem?
    var lastReadingStop = Date.distantPast
    var collapsing = false
    var voiceOffset: UInt64 = 0
    var voiceLogIdentity: UInt64?
    let demoSpeaker = DemoSpeaker()

    func applicationDidFinishLaunching(_ n: Notification) {
        store.update { $0.voice = false }
        let wasQuit = FileManager.default.fileExists(atPath: panelDisabledPath)
        if !demo && !CommandLine.arguments.contains("--background") { try? FileManager.default.removeItem(atPath: panelDisabledPath) }
        // The offline sandbox opens visibly; the real background app starts as an icon.
        if demo { store.mode = .floating }
        NSApp.setActivationPolicy(demo || store.showInDock ? .regular : .accessory)
        configureDemoMenu()
        presentation.mode = store.mode
        let p = ConversationWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 300), styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces]
        p.isMovableByWindowBackground = true; p.hidesOnDeactivate = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        let h = NSHostingView(rootView: Card(store: store)); p.contentView = h; hosting = h; panel = p
        let mini = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 36, height: 36), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        mini.level = .floating; mini.collectionBehavior = [.canJoinAllSpaces]; mini.hidesOnDeactivate = false
        mini.isOpaque = false; mini.backgroundColor = .clear; mini.hasShadow = true
        mini.contentView = NSHostingView(rootView: CompactTab(store: store)); compact = mini
        resetPosition()
        if let x = prefs.object(forKey: "cardX") as? Double, let y = prefs.object(forKey: "cardY") as? Double,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: x, y: y)) }) { p.setFrameTopLeftPoint(NSPoint(x: x, y: y)) }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { _ in
            if self.store.mode == .floating, !demo { prefs.set(p.frame.minX, forKey: "cardX"); prefs.set(p.frame.maxY, forKey: "cardY") }
        }
        popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: Card(store: store))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self; item.button?.action = #selector(toggleStatus)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel(demo ? "Claude Hands Free Demo" : "Claude Hands Free")
        statusItem = item
        store.voiceChanged = { [weak self] in self?.applyVoice() }
        if demo {
            store.autoCollapse = false
            demoSpeaker.stop()
            store.demoStop = { [weak self] in self?.demoSpeaker.stop() }
            demoSpeaker.stateChanged = { [weak self] speaking in self?.store.demoSpeaking = speaking }
            demoSpeaker.failed = { [weak self] message in self?.store.notice = message }
            store.demoOutput = { [weak self] text in self?.demoSpeaker.speak(text) }
        } else {
            // The app itself speaks project-thread messages and answers to "who's waiting"; sessions still speak their own replies.
            demoSpeaker.stop()
            demoSpeaker.stateChanged = { [weak self] speaking in self?.store.demoSpeaking = speaking }
            demoSpeaker.failed = { [weak self] message in self?.store.notice = message }
            store.appSay = { [weak self] text in
                guard let self = self else { return }
                self.demoSpeaker.rate = self.store.settings.rate; self.demoSpeaker.speak(text)
            }
            store.appStop = { [weak self] in self?.demoSpeaker.stop() }
            store.appSpeechBusy = { [weak self] in self?.demoSpeaker.process != nil }
            store.loadBook()
            startWindowWatcher()
        }
        store.refresh(); tick()
        if demo || !CommandLine.arguments.contains("--background") || wasQuit { showWindow() }
        applyVoice()
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in self.tick() }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self.store.refreshAudio() }
    }

    // The Sender helper, in watch mode, snapshots the Claude window for scanWindow(). It is its own app so that its
    // Accessibility permission is asked for and remembered separately; it exits when this panel does.
    func startWindowWatcher() {
        guard !demo, store.settings.watchWindow else { return }
        let stop = Process(); stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); stop.arguments = ["-f", "read-aloud-send --watch"]
        if (try? stop.run()) != nil { stop.waitUntilExit() }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-g", "-a", NSHomeDirectory() + "/.cache/read-aloud/ReadAloudSend.app", "--args", "--watch", voiceDir, String(ProcessInfo.processInfo.processIdentifier)]
        try? p.run()
    }

    @objc func toggleStatus() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: demo ? "Show Demo" : "Show Conversation", action: #selector(showWindow), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Stop microphone and speech", action: #selector(stopListening), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(quitPanel), keyEquivalent: "").target = self
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        if presentation.expanded { hidePanel() } else { showPanel() }
    }
    func noteInteraction() { presentation.lastInteraction = Date().timeIntervalSince1970 }
    @objc func showPanel() {
        hoverTask?.cancel()
        presentation.show(at: Date().timeIntervalSince1970)
        renderPresentation()
    }

    @objc func showWindow() {
        // An explicit app/Dock launch must recover a window even if menu-bar space is exhausted.
        store.mode = .floating; presentation.mode = .floating
        showPanel(); NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
    }
    func hidePanel() {
        if demo { stopListening() }
        hoverTask?.cancel(); presentation.hide(); renderPresentation()
    }
    func hoverCompact(_ inside: Bool) {
        hoverTask?.cancel()
        if inside && store.hoverExpand {
            let work = DispatchWorkItem { [weak self] in self?.showPanel() }
            hoverTask = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
    func presentationChanged() {
        popover.performClose(nil); panel?.orderOut(nil); compact?.orderOut(nil)
        presentation.mode = store.mode
        presentation.show(at: Date().timeIntervalSince1970)
        DispatchQueue.main.async { self.renderPresentation() }
    }
    func popoverDidClose(_ notification: Notification) {
        presentation.collapse()
        if demo { stopListening() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !demo { try? FileManager.default.removeItem(atPath: panelDisabledPath) }
        showWindow()
        return true
    }
    func suppressBackgroundLaunch() {
        guard !demo else { return }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: URL(fileURLWithPath: panelDisabledPath), options: .atomic)
        } catch { store.notice = "Couldn't remember Quit: \(error.localizedDescription)" }
    }
    @objc func quitPanel() {
        suppressBackgroundLaunch()
        NSApp.terminate(nil)
    }

    @objc func stopListening() {
        if !demo, let speech = store.speaking { store.send("stop", speech) }
        if !demo { store.stopAppSpeech() }
        store.update { $0.voice = false }
        demoSpeaker.stop()
        applyVoice()
        store.voiceError = ""
        store.refreshAudio()
        store.notice = "Microphone and speech stopped."
    }
    func applicationDidHide(_ notification: Notification) {
        if demo { stopListening() }
    }
    func configureDemoMenu() {
        let bar = NSMenu()
        let root = NSMenuItem()
        let menu = NSMenu(title: demo ? "Demo" : "Conversation")
        menu.addItem(withTitle: demo ? "Show Demo" : "Show Conversation", action: #selector(showWindow), keyEquivalent: "0").target = self
        menu.addItem(withTitle: demo ? "Stop Demo" : "Stop Listening", action: #selector(stopListening), keyEquivalent: ".").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: demo ? "Quit Claude Hands Free Demo" : "Quit Claude Hands Free", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        root.submenu = menu; bar.addItem(root); NSApp.mainMenu = bar
    }
    func applyVoice() {
        let executable = demo ? "read-aloud-demo-listen" : "read-aloud-listen"
        // Always end the old reader before replacing its log, including after a failed start.
        let stop = Process(); stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); stop.arguments = ["-x", executable]
        if (try? stop.run()) != nil { stop.waitUntilExit() }
        if demo { demoSpeaker.stop() }
        store.captures.removeAll(); store.speechIDs.removeAll(); store.heard = ""
        store.audio = nil; voiceLogIdentity = nil; voiceOffset = 0
        if !store.settings.voice { try? FileManager.default.removeItem(atPath: voiceDir + "/microphone-owner.json") }
        if store.settings.voice {
            store.voiceError = ""; store.voiceStartedAt = Date().timeIntervalSince1970
            store.demoSecondsRemaining = 120
            store.saveAudioPreferences()
            do {
                try FileManager.default.createDirectory(atPath: voiceDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for name in ["voice.log", "audio.json"] { try? FileManager.default.removeItem(atPath: voiceDir + "/" + name) }
                try atomicJSON(["pid": ProcessInfo.processInfo.processIdentifier], path: voiceDir + "/microphone-owner.json")
                let name = demo ? "ReadAloudDemoListen.app" : "ReadAloudListen.app"
                let bundled = Bundle.main.resourceURL?.appendingPathComponent(name).path
                let app = bundled.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory() + "/.cache/read-aloud/" + name
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-g", "-a", app]
                try p.run()
                store.notice = "Starting on-device speech recognition…"
            } catch {
                store.update { $0.voice = false }
                store.voiceError = "Couldn't start the microphone helper: \(error.localizedDescription)"
                store.notice = store.voiceError
            }
        }
        store.refreshAudio()
    }
    func tailVoice() {
        guard store.settings.voice, let h = FileHandle(forReadingAtPath: "\(voiceDir)/voice.log") else { return }
        defer { try? h.close() }
        let identity = (try? FileManager.default.attributesOfItem(atPath: "\(voiceDir)/voice.log")[.systemFileNumber]) as? UInt64
        if identity != voiceLogIdentity { voiceLogIdentity = identity; voiceOffset = 0 }
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
        let now = Date().timeIntervalSince1970
        if demoTrialExpired(isDemo: demo, listening: store.settings.voice, startedAt: store.voiceStartedAt, now: now) {
            stopListening()
            store.notice = "Demo stopped after two minutes. Start it again when you are ready."
        }
        if demo && store.settings.voice { store.demoSecondsRemaining = max(0, 120 - Int(now - store.voiceStartedAt)) }
        if FileManager.default.fileExists(atPath: voiceDir + "/show-panel") {
            try? FileManager.default.removeItem(atPath: voiceDir + "/show-panel"); showWindow()
        }
        store.refresh(); tailVoice(); store.tickHandy()
        store.scanThreads(); store.scanWindow(); store.tickSpeech(); store.tickMedia()
        // "Read replies aloud" off is enforced here too: a session still running an older copy of the mod reads regardless, so stop it
        if !demo && !store.settings.reading, let reading = store.speaking, Date().timeIntervalSince(lastReadingStop) > 2 {
            lastReadingStop = Date(); store.send("stop", reading)
        }
        if let speech = store.speaking, !speech.text.isEmpty { store.assistantCaption = speech.text }
        let needsAnswer = store.waitingRows.count
        let symbol = demo ? "ladybug" : needsAnswer > 0 ? "exclamationmark.bubble" : store.settings.voice ? "waveform.circle.fill" : "waveform.circle"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude Hands Free")
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = demo ? "Claude Hands Free Demo · no Claude usage" : needsAnswer > 0 ? "\(needsAnswer) waiting on you" : "Claude Hands Free"
        var events = Set(store.all.flatMap { $0.pending.map { $0.id } })
        for s in store.all where s.ready && s.work == "idle" { events.insert("finished-\(s.id)-\(s.instance)") }
        if store.threadEvents.count > 200 { store.threadEvents.removeAll() }
        events.formUnion(store.threadEvents)
        let mouse = NSEvent.mouseLocation
        let inside = (panel?.isVisible == true && panel!.frame.contains(mouse))
            || (compact?.isVisible == true && compact!.frame.contains(mouse)) || popover.isShown
        presentation.tick(events: events, now: Date().timeIntervalSince1970, pointerInside: inside,
            autoExpand: store.autoExpand, autoCollapse: store.autoCollapse && store.mode != .menuBar)
        renderPresentation()
    }
    func renderPresentation() {
        guard let p = panel, let mini = compact, let h = hosting else { return }
        let size = h.fittingSize
        if abs(p.frame.height - size.height) > 1 {
            let top = p.frame.maxY; p.setContentSize(size); p.setFrameTopLeftPoint(NSPoint(x: p.frame.minX, y: top))
        }
        if presentation.mode == .menuBar {
            p.orderOut(nil); mini.orderOut(nil)
            if presentation.expanded && !presentation.hidden {
                if !popover.isShown, let button = statusItem?.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
            } else if popover.isShown { popover.performClose(nil) }
            return
        }
        if popover.isShown { popover.performClose(nil) }
        guard !presentation.hidden else { p.orderOut(nil); mini.orderOut(nil); return }
        let screen = mini.screen ?? p.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            if presentation.mode == .edge {
                mini.setContentSize(NSSize(width: 26, height: 48))
                mini.setFrameOrigin(NSPoint(x: store.edgeSide == "left" ? frame.minX + 3 : frame.maxX - 29, y: frame.midY - 24))
                let x = store.edgeSide == "left" ? mini.frame.maxX + 5 : mini.frame.minX - p.frame.width - 5
                let y = min(frame.maxY - p.frame.height, max(frame.minY, mini.frame.midY - p.frame.height / 2))
                p.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                let x = max(frame.minX + 8, min(p.frame.minX, frame.maxX - p.frame.width - 8))
                let y = max(frame.minY + 8, min(p.frame.minY, frame.maxY - p.frame.height - 8))
                if p.frame.minX != x || p.frame.minY != y { p.setFrameOrigin(NSPoint(x: x, y: y)) }
                mini.setContentSize(NSSize(width: 36, height: 36))
                mini.setFrameOrigin(NSPoint(x: p.frame.maxX - 36, y: p.frame.maxY - 36))
            }
        }
        if presentation.expanded {
            mini.orderOut(nil)
            if !p.isVisible { p.orderFrontRegardless() }
        } else if p.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animateCollapse(p, into: mini)
        } else if !collapsing {
            p.orderOut(nil)
            if !mini.isVisible { mini.orderFrontRegardless() }
        }
    }

    // the card shrinks and fades into its icon instead of vanishing
    func animateCollapse(_ p: NSPanel, into mini: NSPanel) {
        guard !collapsing else { return }
        collapsing = true
        let original = p.frame
        let target = NSRect(x: mini.frame.midX - 6, y: mini.frame.midY - 6, width: 12, height: 12)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4; ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(target, display: true); p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.collapsing = false
            if !self.presentation.expanded { p.orderOut(nil); if !mini.isVisible { mini.orderFrontRegardless() } }
            p.alphaValue = 1; p.setFrame(original, display: false)
        })
    }
    func resetPosition() {
        guard let p = panel, let sc = NSScreen.main else { return }
        p.setFrameTopLeftPoint(NSPoint(x: sc.visibleFrame.maxX - p.frame.width - 20, y: sc.visibleFrame.maxY - 20))
    }
    func applicationWillTerminate(_ n: Notification) {
        suppressBackgroundLaunch()
        demoSpeaker.stop()
        if store.holdingSpeechLock { rmdir(speechLockPath) }
        stopListening()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    }
}
@main struct ConversationPanel {
    static func main() {
        #if TESTING
        panelSelfTests()
        #else
        if !demo && CommandLine.arguments.contains("--background") && FileManager.default.fileExists(atPath: panelDisabledPath) { return }
        try? FileManager.default.createDirectory(atPath: voiceDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(voiceDir + "/panel.lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if !CommandLine.arguments.contains("--background") { try? atomicJSON([:], path: voiceDir + "/show-panel") }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(demo || (prefs.object(forKey: "showInDock") as? Bool ?? true) ? .regular : .accessory)
        let delegate = AppDelegate(); app.delegate = delegate; app.run()
        #endif
    }
}
