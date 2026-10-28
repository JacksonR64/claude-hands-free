// On-device recognition while the user has enabled conversation mode.
import AppKit
import Speech
import AVFoundation
import Darwin

let demo = Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true
let root = NSHomeDirectory() + "/.cache/read-aloud/conversation" + (demo ? "-demo" : "")
let playbackMarker = root + "/demo-speaking"
let interruptionMarker = root + "/allow-interruption"
func emit(_ event: String, id: String? = nil, text: String? = nil) {
    var value: [String: Any] = ["event": event, "ts": Date().timeIntervalSince1970 * 1000]
    if let id = id { value["id"] = id }; if let text = text { value["text"] = text }
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    var line = data; line.append(10)
    FileHandle.standardOutput.write(line)
    if let handle = FileHandle(forWritingAtPath: root + "/voice.log") {
        defer { try? handle.close() }; handle.seekToEndOfFile(); handle.write(line)
    }
}

func playbackIsActive() -> Bool {
    if demo { return FileManager.default.fileExists(atPath: playbackMarker) }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    return files.filter { $0.hasPrefix("s-") && $0.hasSuffix(".json") }.contains { name in
        guard let data = FileManager.default.contents(atPath: root + "/" + name),
              let state = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else { return false }
        return isCurrentPlayback(state, now: Date().timeIntervalSince1970)
    }
}

final class Listener {
    let ownerPID: Int32? = {
        guard let data = FileManager.default.contents(atPath: root + "/microphone-owner.json"),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Int32],
              let pid = value["pid"], pid > 0 else { return nil }
        return pid
    }()
    let engine = AVAudioEngine()
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    let requestLock = NSLock()
    var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?
    var utterance: String?
    var transcript = ""
    var carried = ""                    // earlier recogniser segments of this same utterance (a request lasts under a minute)
    var pendingUntil: Date?              // set while the send countdown runs
    var pendingStart = Date()
    let sendDelay: Double = {            // seconds of silence before a dictated message is sent; ~/.config/read-aloud/settings.json "sendDelay"
        let path = NSHomeDirectory() + "/.config/read-aloud/settings.json"
        if let d = FileManager.default.contents(atPath: path), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let v = j["sendDelay"] as? Double { return max(0, min(30, v)) }
        return 5
    }()
    // settings.json: "wake" (phrase) and "requireWake" (default true: dictation needs it; commands never do)
    let settingsJSON: [String: Any] = {
        let path = NSHomeDirectory() + "/.config/read-aloud/settings.json"
        guard let d = FileManager.default.contents(atPath: path), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }()
    var wakeWord: String { (settingsJSON["wake"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "okay claude" }
    var requireWake: Bool { !demo && (settingsJSON["requireWake"] as? Bool ?? true) }
    var useHandy: Bool { (settingsJSON["dictation"] as? String) == "handy" }   // the app starts Handy instead of arming Apple dictation
    var armedUntil = Date.distantPast    // "okay Claude" on its own: the next utterance is the message
    var full: String { carried.isEmpty ? transcript : transcript.isEmpty ? carried : carried + " " + transcript }
    var lastChange = Date(), lastVoice = Date(), started = Date()
    var generation = 0
    var failures = 0
    var mutedForPlayback = false
    var noiseFloor: Float = -58
    var timer: Timer?
    var db: Float = -100, peakDB: Float = -100
    var frames = 0
    var lastBufferAt = 0.0
    var recognitionState = "starting"
    var inputName = "Default microphone"

    func start() {
        guard let pid = ownerPID, kill(pid, 0) == 0 else { exit(0) }
        guard let recognizer = recognizer, recognizer.supportsOnDeviceRecognition else {
            emit("error", text: "On-device English recognition is unavailable. Enable its language support in macOS, then try again."); exit(2)
        }
        guard recognizer.isAvailable else { emit("error", text: "Speech recognition is unavailable. Try again shortly."); exit(2) }
        do {
            inputName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default microphone"
            // Gate known playback instead of enabling the voice-processing path that stalled capture.
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "No microphone", code: 1) }
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.requestLock.lock()
                self.request?.append(buffer)
                self.requestLock.unlock()
                if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    var sum: Float = 0
                    for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
                    let db = 10 * log10(max(sum / Float(buffer.frameLength), 0.0000000001))
                    let frameCount = Int(buffer.frameLength)
                    DispatchQueue.main.async {
                        self.db = db; self.peakDB = max(self.peakDB, db)
                        self.frames += frameCount; self.lastBufferAt = Date().timeIntervalSince1970
                        if db < self.noiseFloor + 6 { self.noiseFloor = self.noiseFloor * 0.98 + db * 0.02 }
                        if db > max(-48, min(-30, self.noiseFloor + 12)) { self.lastVoice = Date() }
                    }
                }
            }
            for marker in ["/cancel-utterance", "/send-now"] { try? FileManager.default.removeItem(atPath: root + marker) }
            engine.prepare(); try engine.start(); restart()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            emit("ready", text: "Listening on this Mac")
        } catch { emit("error", text: "Couldn't start microphone processing: \(error.localizedDescription)"); exit(3) }
    }
    func restart(keep: Bool = false) {
        generation += 1
        let mine = generation
        task?.cancel()
        let fresh = SFSpeechAudioBufferRecognitionRequest()
        fresh.requiresOnDeviceRecognition = true
        fresh.shouldReportPartialResults = true
        fresh.taskHint = .dictation
        recognitionState = "listening"
        requestLock.lock()
        request?.endAudio(); request = fresh
        requestLock.unlock()
        started = Date(); transcript = ""
        if !keep { utterance = nil; carried = ""; pendingUntil = nil; lastChange = Date() }
        task = recognizer?.recognitionTask(with: fresh) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == mine, !self.mutedForPlayback,
                      !playbackIsActive() || FileManager.default.fileExists(atPath: interruptionMarker) else { return }
                if let result = result {
                    self.failures = 0
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        if self.utterance == nil { self.utterance = UUID().uuidString; emit("begin", id: self.utterance) }
                        if text != self.transcript { self.transcript = text; self.lastChange = Date(); emit("partial", id: self.utterance, text: self.full) }
                    }
                    if result.isFinal {   // the recogniser ended this segment: keep the words and carry on listening
                        if self.utterance != nil { self.carried = self.full; self.restart(keep: true) } else { self.restart() }
                        return
                    }
                }
                if let error = error {
                    self.recognitionState = "retrying"
                    emit("diagnostic", text: "Speech recogniser: \(error.localizedDescription)")
                    if let id = self.utterance { emit("cancel", id: id) }
                    self.failures += 1
                    if self.failures >= 5 { emit("error", text: "Speech recognition stopped. Turn the microphone off and on to retry."); exit(4) }
                    self.generation += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.restart() }
                }
            }
        }
    }
    func finish() {
        if let id = utterance, !full.isEmpty {
            var out = full
            if requireWake, case .dictate = voiceIntent(full, wake: wakeWord), startsWithWake(full, wake: wakeWord) { out = withoutWake(full, wake: wakeWord) }
            emit("final", id: id, text: out)
        }
        armedUntil = .distantPast
        restart()
    }
    func tick() {
        if let pid = ownerPID, kill(pid, 0) != 0 { exit(0) }
        let status: [String: Any] = ["ts": Date().timeIntervalSince1970, "lastBufferAt": lastBufferAt,
            "db": db, "peakDB": peakDB, "frames": frames, "input": inputName,
            "state": mutedForPlayback ? "playback" : recognitionState]
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            try? data.write(to: URL(fileURLWithPath: root + "/audio.json"), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root + "/audio.json")
        }
        if playbackIsActive() && !FileManager.default.fileExists(atPath: interruptionMarker) {
            if !mutedForPlayback {
                mutedForPlayback = true; generation += 1; task?.cancel()
                requestLock.lock(); request?.endAudio(); request = nil; requestLock.unlock()
                if let id = utterance { emit("cancel", id: id) }
                utterance = nil; transcript = ""; carried = ""; pendingUntil = nil
            }
            return
        }
        if mutedForPlayback { mutedForPlayback = false; restart(); return }
        let now = Date()
        if let until = pendingUntil {   // countdown: more speech cancels it, the panel can cancel or send now
            if lastChange > pendingStart { pendingUntil = nil; emit("resume", id: utterance) }
            else if FileManager.default.fileExists(atPath: root + "/cancel-utterance") {
                try? FileManager.default.removeItem(atPath: root + "/cancel-utterance")
                if let id = utterance { emit("cancel", id: id) }
                restart()
            } else if now >= until || FileManager.default.fileExists(atPath: root + "/send-now") {
                try? FileManager.default.removeItem(atPath: root + "/send-now")
                finish()
            }
            return
        }
        if shouldFinishSpeech(hasTranscript: utterance != nil && !full.isEmpty, unchangedFor: now.timeIntervalSince(lastChange), quietFor: now.timeIntervalSince(lastVoice)) {
            let intent = voiceIntent(full, wake: wakeWord)
            if case .dictate = intent {
                let addressed = startsWithWake(full, wake: wakeWord) || now < armedUntil
                if requireWake && !addressed {   // not said to us: never sent
                    emit("diagnostic", text: "Heard speech without “\(wakeWord)”. Say it first to dictate a message.")
                    if let id = utterance { emit("cancel", id: id) }
                    restart(); return
                }
                if requireWake && startsWithWake(full, wake: wakeWord) && withoutWake(full, wake: wakeWord).isEmpty {   // only the wake phrase
                    armedUntil = now.addingTimeInterval(8)
                    emit("diagnostic", text: "Listening for your message…")
                    if let id = utterance { emit("cancel", id: id) }
                    restart(); return
                }
                if sendDelay <= 0 { finish() }   // a message: the countdown runs
                else {
                    pendingStart = now; pendingUntil = now.addingTimeInterval(sendDelay)
                    emit("pending", id: utterance, text: String(Int(pendingUntil!.timeIntervalSince1970 * 1000)))
                }
            } else if case .startDictation = intent, !useHandy {   // "okay Claude, dictate": the next utterance is the message
                armedUntil = now.addingTimeInterval(8)
                emit("diagnostic", text: "Listening for your message…")
                if let id = utterance { emit("cancel", id: id) }
                restart()
            } else { finish() }   // commands are sent at once, with no countdown
        } else if now.timeIntervalSince(started) > 45 {   // the recogniser caps a request at about a minute: carry the words over
            if utterance != nil { carried = full; restart(keep: true) } else { restart() }
        }

    }
}

@main struct ConversationListener {
    static func main() throws {
        if CommandLine.arguments.contains("--status") {   // read-only: report the macOS permission state and exit
            print("speech", SFSpeechRecognizer.authorizationStatus().rawValue, "microphone", AVCaptureDevice.authorizationStatus(for: .audio).rawValue, "(0 undecided, 3 allowed)")
            return
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(root + "/listener.lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        FileManager.default.createFile(atPath: root + "/voice.log", contents: Data(), attributes: [.posixPermissions: 0o600])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let listener = Listener()
        guard let pid = listener.ownerPID, kill(pid, 0) == 0 else { return }

        // a menu-bar-style app is never frontmost, and macOS then does not show the permission prompt: come forward while asking
        func foreground(_ on: Bool) {
            app.setActivationPolicy(on ? .regular : .accessory)
            if on { app.activate(ignoringOtherApps: true) }
        }

        func authorizeMicrophone() {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { listener.start(); return }
            emit("diagnostic", text: "Waiting for macOS Microphone permission…")
            foreground(true)
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async { foreground(false) }
                guard allowed else { emit("error", text: "Allow Microphone access for the conversation helper in macOS Privacy settings."); exit(3) }
                DispatchQueue.main.async { listener.start() }
            }
        }

        DispatchQueue.main.async {
            if SFSpeechRecognizer.authorizationStatus() == .authorized { authorizeMicrophone(); return }
            emit("diagnostic", text: "Waiting for macOS Speech Recognition permission…")
            foreground(true)
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { foreground(false) }
                guard status == .authorized else { emit("error", text: "Allow Speech Recognition for the conversation helper in macOS Privacy settings."); exit(2) }
                DispatchQueue.main.async { authorizeMicrophone() }
            }
        }
        withExtendedLifetime(listener) { app.run() }
    }
}
