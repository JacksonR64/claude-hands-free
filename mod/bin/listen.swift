// On-device recognition while the user has enabled conversation mode.
import Speech
import AVFoundation
import Darwin

let demo = Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true
let root = NSHomeDirectory() + "/.cache/read-aloud/conversation" + (demo ? "-demo" : "")
let playbackMarker = root + "/demo-speaking"
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

final class Listener {
    let engine = AVAudioEngine()
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    let requestLock = NSLock()
    var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?
    var utterance: String?
    var transcript = ""
    var lastChange = Date(), lastVoice = Date(), started = Date()
    var generation = 0
    var failures = 0
    var mutedForPlayback = false
    var noiseFloor: Float = -58
    var timer: Timer?

    func start() {
        guard let recognizer = recognizer, recognizer.supportsOnDeviceRecognition else {
            emit("error", text: "On-device English recognition is unavailable. Enable its language support in macOS, then try again."); exit(2)
        }
        guard recognizer.isAvailable else { emit("error", text: "Speech recognition is unavailable. Try again shortly."); exit(2) }
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
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
                    DispatchQueue.main.async {
                        if db < self.noiseFloor + 6 { self.noiseFloor = self.noiseFloor * 0.98 + db * 0.02 }
                        if db > max(-48, min(-30, self.noiseFloor + 12)) { self.lastVoice = Date() }
                    }
                }
            }
            engine.prepare(); try engine.start(); restart()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
            emit("ready", text: "Listening on this Mac")
        } catch { emit("error", text: "Couldn't start microphone processing: \(error.localizedDescription)"); exit(3) }
    }
    func restart() {
        generation += 1
        let mine = generation
        task?.cancel()
        let fresh = SFSpeechAudioBufferRecognitionRequest()
        fresh.requiresOnDeviceRecognition = true
        fresh.shouldReportPartialResults = true
        requestLock.lock()
        request?.endAudio(); request = fresh
        requestLock.unlock()
        started = Date(); utterance = nil; transcript = ""; lastChange = Date()
        task = recognizer?.recognitionTask(with: fresh) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == mine, !self.mutedForPlayback,
                      !(demo && FileManager.default.fileExists(atPath: playbackMarker)) else { return }
                if let result = result {
                    self.failures = 0
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        if self.utterance == nil { self.utterance = UUID().uuidString; emit("begin", id: self.utterance) }
                        if text != self.transcript { self.transcript = text; self.lastChange = Date(); emit("partial", id: self.utterance, text: text) }
                    }
                    if result.isFinal { self.finish(); return }
                }
                if error != nil {
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
        if let id = utterance, !transcript.isEmpty { emit("final", id: id, text: transcript) }
        restart()
    }
    func tick() {
        if demo && FileManager.default.fileExists(atPath: playbackMarker) {
            if !mutedForPlayback {
                mutedForPlayback = true; generation += 1; task?.cancel()
                requestLock.lock(); request?.endAudio(); request = nil; requestLock.unlock()
                if let id = utterance { emit("cancel", id: id) }
                utterance = nil; transcript = ""
            }
            return
        }
        if mutedForPlayback { mutedForPlayback = false; restart(); return }
        if utterance != nil, Date().timeIntervalSince(lastChange) > 1.7, Date().timeIntervalSince(lastVoice) > 1.2 { finish() }
        else if Date().timeIntervalSince(started) > 45 { if utterance != nil { finish() } else { restart() } }
    }
}

try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let lock = open(root + "/listener.lock", O_CREAT | O_RDWR, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
FileManager.default.createFile(atPath: root + "/voice.log", contents: Data(), attributes: [.posixPermissions: 0o600])
let listener = Listener()
SFSpeechRecognizer.requestAuthorization { status in
    guard status == .authorized else { emit("error", text: "Allow Speech Recognition for Read Aloud Conversation in macOS Privacy settings."); exit(2) }
    AVCaptureDevice.requestAccess(for: .audio) { allowed in
        guard allowed else { emit("error", text: "Allow Microphone access for Read Aloud Conversation in macOS Privacy settings."); exit(3) }
        DispatchQueue.main.async { listener.start() }
    }
}
RunLoop.main.run()
