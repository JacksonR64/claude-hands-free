import Foundation
import SQLite3

enum PanelMode: String, CaseIterable {
    case menuBar, edge, floating
    var title: String { self == .menuBar ? "Menu bar" : self == .edge ? "Screen edge" : "Floating icon" }
}

// Visibility changes follow intent or a genuinely new event, never a heartbeat.
struct PanelPresentation {
    var mode: PanelMode = .menuBar
    var expanded = false
    var hidden = false
    var lastInteraction: TimeInterval = 0
    var hovered = false   // the pointer has been over it since it last opened
    static let idleSeconds: TimeInterval = 2    // untouched: tuck away after this long
    static let leaveSeconds: TimeInterval = 1   // after the pointer leaves: a short grace, then tuck away
    var seenEvents = Set<String>()
    mutating func show(at now: TimeInterval) { hidden = false; expanded = true; lastInteraction = now; hovered = false }
    mutating func hide() { hidden = true; expanded = false }
    mutating func collapse() { expanded = false }
    mutating func tick(events: Set<String>, now: TimeInterval, pointerInside: Bool, autoExpand: Bool, autoCollapse: Bool) {
        let fresh = events.subtracting(seenEvents)
        seenEvents = events
        if autoExpand && !hidden && !fresh.isEmpty { show(at: now) }
        if pointerInside { lastInteraction = now; hovered = true }
        if autoCollapse && expanded && !pointerInside && now - lastInteraction >= (hovered ? Self.leaveSeconds : Self.idleSeconds) { collapse() }
    }
}

enum VoiceIntent: Equatable {
    case startDictation, next, previous, select(String), pause, resume, stopSpeech, stopWork, stopListening, readAgain, open, approve, deny, cancel, dictate(String)
    // The numbered "waiting on you" list: project threads and sessions that need an answer.
    case whoIsWaiting, replyTo(Int, String), readItem(Int), openItem(Int), dismissItem(Int)
}

let numberWords: [String: Int] = ["one": 1, "won": 1, "two": 2, "too": 2, "three": 3, "four": 4, "for": 4, "fore": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "ate": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5]
func spokenNumber(_ word: String) -> Int? {
    if let n = Int(word) { return n > 0 && n < 100 ? n : nil }
    return numberWords[word]
}

// "reply to number four, yes go ahead" / "read number two" / "open 3" / "dismiss number one".
// A reply keeps the speaker's own wording; anything that is not clearly a numbered command stays ordinary dictation.
func numberedCommand(_ transcript: String, wake: String = "okay claude") -> VoiceIntent? {
    let raw = transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var words: [(word: String, index: Int)] = []
    for (index, token) in raw.enumerated() { for word in normalized(token).split(separator: " ") { words.append((String(word), index)) } }
    var i = 0
    func starts(_ phrase: String) -> Bool {
        let parts = phrase.split(separator: " ").map(String.init)
        return !parts.isEmpty && i + parts.count <= words.count && zip(parts, words[i...]).allSatisfy { $0 == $1.word }
    }
    func skip(_ phrases: [String]) -> Bool {
        for phrase in phrases where starts(phrase) { i += phrase.split(separator: " ").count; return true }
        return false
    }
    _ = skip([normalized(wake), "okay claude", "ok claude", "hey claude", "okay", "ok"])
    while skip(["i ll", "i will", "i want to", "i d like to", "let me", "can you", "could you", "please", "and", "now"]) {}
    guard i < words.count else { return nil }
    let verb = words[i].word; i += 1
    let replying = ["reply", "respond", "answer", "tell", "message"].contains(verb)
    guard replying || ["read", "play", "open", "show", "dismiss", "clear", "skip"].contains(verb) else { return nil }
    let hadTo = skip(["to"])
    _ = skip(["the"])
    let hadKeyword = skip(["number", "numbers", "thread", "item"])
    guard i < words.count else { return nil }
    guard let number = spokenNumber(words[i].word) ?? (hadKeyword && words[i].word == "to" ? 2 : nil) else { return nil }
    let last = words[i].index; i += 1
    if replying {
        // "tell 5 people" is a message; "reply to four" and "tell number four" are commands
        guard hadKeyword || (hadTo && ["reply", "respond"].contains(verb)) else { return nil }
        var rest = Array(raw[(last + 1)...])
        if let first = rest.first, normalized(first) == "saying" { rest.removeFirst() }
        let text = rest.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        return .replyTo(number, text)
    }
    guard i == words.count else { return nil }   // "read 3 files in the repo" is a message
    switch verb {
    case "read", "play": return .readItem(number)
    case "open", "show": return .openItem(number)
    default: return .dismissItem(number)
    }
}

func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
        .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
}

func voiceIntent(_ transcript: String, wake: String = "okay claude") -> VoiceIntent {
    var text = normalized(transcript)
    let prefixes = [normalized(wake), "okay claude", "ok claude", "hey claude", "okay", "ok"]
    for prefix in prefixes where text.hasPrefix(prefix + " ") { text = String(text.dropFirst(prefix.count + 1)); break }
    switch text {
    case "dictate", "start dictation", "take a message", "new message": return .startDictation
    case "next session", "next chat", "next conversation": return .next
    case "previous session", "previous chat", "previous conversation": return .previous
    case "pause", "pause speaking": return .pause
    case "resume speaking", "keep reading": return .resume
    case "stop speaking", "be quiet": return .stopSpeech
    case "microphone off", "stop listening", "turn off the microphone", "stop demo", "end demo": return .stopListening
    case "read again", "repeat that", "say that again": return .readAgain
    case "stop working", "stop work", "cancel work": return .stopWork
    case "open session", "open chat", "show session": return .open
    case "approve action", "allow action": return .approve
    case "deny action", "reject action": return .deny
    case "cancel message", "discard message": return .cancel
    case "who s waiting", "who is waiting", "whos waiting", "what s waiting", "what is waiting", "who s waiting for me", "who is waiting for me",
         "who s waiting on me", "who is waiting on me", "what s waiting on me", "what s waiting for me", "who needs me", "what needs me",
         "waiting list", "list waiting", "anything waiting", "is anything waiting", "who needs a reply", "what needs my attention":
        return .whoIsWaiting
    default: break
    }
    if let command = numberedCommand(transcript, wake: wake) { return command }
    for prefix in ["switch to ", "move to ", "go to ", "select session "] where text.hasPrefix(prefix) {
        var name = String(text.dropFirst(prefix.count))
        if name.hasPrefix("the ") { name = String(name.dropFirst(4)) }
        for suffix in [" session", " chat", " conversation"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)); break }
        if !name.isEmpty { return .select(name) }
    }
    return .dictate(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
}

// ---- Handy (https://github.com/cjpais/Handy): optional dictation engine. Its CLI starts/stops a recording and it
// keeps every transcript in history.db, so the app can take the text itself instead of letting Handy paste it.
let handyBinary = "/Applications/Handy.app/Contents/MacOS/Handy"
var handySupport = NSHomeDirectory() + "/Library/Application Support/com.pais.handy"
func handyInstalled() -> Bool { FileManager.default.isExecutableFile(atPath: handyBinary) }

func handyQuery<T>(_ sql: String, _ read: (OpaquePointer) -> T?) -> T? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(handySupport + "/history.db", &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle = db else { sqlite3_close(db); return nil }
    defer { sqlite3_close(handle) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else { return nil }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW ? read(statement) : nil
}
func handyLastID() -> Int64 { handyQuery("SELECT COALESCE(MAX(id), 0) FROM transcription_history") { sqlite3_column_int64($0, 0) } ?? 0 }
// the newest transcript after `id` (the post-processed text when Handy made one)
func handyTranscript(after id: Int64) -> (id: Int64, text: String)? {
    handyQuery("SELECT id, COALESCE(NULLIF(post_processed_text, ''), transcription_text) FROM transcription_history WHERE id > \(id) ORDER BY id DESC LIMIT 1") { s in
        guard let c = sqlite3_column_text(s, 1) else { return nil }
        return (sqlite3_column_int64(s, 0), String(cString: c))
    }
}
func handyPasteMethod() -> String? {
    guard let d = FileManager.default.contents(atPath: handySupport + "/settings_store.json"),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return ((j["settings"] as? [String: Any]) ?? j)["paste_method"] as? String
}
func handyRun(_ flag: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: handyBinary); p.arguments = [flag]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run()
}

func wakePrefixes(_ wake: String) -> [String] { [normalized(wake), "okay claude", "ok claude", "hey claude"] }

// Dictation starts only when the utterance opens with the wake phrase; commands need no wake phrase.
func startsWithWake(_ transcript: String, wake: String = "okay claude") -> Bool {
    let text = normalized(transcript)
    return wakePrefixes(wake).contains { !$0.isEmpty && (text == $0 || text.hasPrefix($0 + " ")) }
}

func withoutWake(_ transcript: String, wake: String = "okay claude") -> String {
    let tokens = transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    for prefix in wakePrefixes(wake) where !prefix.isEmpty {
        let words = prefix.split(separator: " ").map(String.init)
        if tokens.count >= words.count, zip(tokens, words).allSatisfy({ normalized($0.0) == $0.1 }) {
            return tokens.dropFirst(words.count).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-"))
        }
    }
    return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct VoiceCandidate { let id: String; let names: [String] }

// An exact alias wins; otherwise all token-sequence matches must identify one session.
func matchingSessions(_ query: String, candidates: [VoiceCandidate]) -> [String] {
    let needle = normalized(query)
    guard !needle.isEmpty else { return [] }
    let exact = candidates.filter { $0.names.contains { normalized($0) == needle } }.map(\.id)
    if !exact.isEmpty { return exact }
    return candidates.filter { candidate in
        candidate.names.contains { (" " + normalized($0) + " ").contains(" " + needle + " ") }
    }.map(\.id)
}

struct SpeechDestination: Equatable {
    let session: String
    let instance: String
    let request: String?
}

struct AudioSnapshot: Decodable {
    let ts: Double
    let lastBufferAt: Double
    let db: Double
    let peakDB: Double
    let frames: Int
    let input: String
    let state: String
}

struct PlaybackSnapshot: Decodable {
    let phase: String
    let ts: Double
}

func isCurrentPlayback(_ state: PlaybackSnapshot, now: Double) -> Bool {
    state.phase == "speaking" && now * 1000 - state.ts < 12000 && now * 1000 >= state.ts - 1000
}

enum AudioDisplay: String, CaseIterable {
    case waveform, captions, both
    var title: String { rawValue.capitalized }
}

func demoTrialExpired(isDemo: Bool, listening: Bool, startedAt: Double, now: Double) -> Bool {
    isDemo && listening && now - startedAt >= 120
}

enum MicrophonePhase {
    case off, starting, quiet, input, recognizing, speaking, noAudio, retrying, error
    var label: String {
        switch self {
        case .off: return "Microphone off"
        case .starting: return "Starting microphone…"
        case .quiet: return "Listening · quiet input"
        case .input: return "Sound detected"
        case .recognizing: return "Recognising speech…"
        case .speaking: return "Replying · wait for your turn"
        case .noAudio: return "No audio arriving"
        case .retrying: return "Retrying speech recognition…"
        case .error: return "Microphone error"
        }
    }
}

func normalizedInputLevel(_ db: Double) -> Double {
    guard db.isFinite else { return 0 }
    return min(1, max(0, (db + 65) / 45))
}

func shouldFinishSpeech(hasTranscript: Bool, unchangedFor: Double, quietFor: Double) -> Bool {
    // Steady room noise must not hold a recognised answer until the 45-second request limit.
    hasTranscript && unchangedFor > 0.9 && (quietFor > 0.6 || unchangedFor > 1.8)
}

func microphonePhase(enabled: Bool, speaking: Bool, recognizing: Bool, failed: Bool,
                     startedAt: Double, snapshot: AudioSnapshot?, now: Double) -> MicrophonePhase {
    if speaking { return .speaking }
    if failed { return .error }
    guard enabled else { return .off }
    guard let audio = snapshot, now - audio.ts < 3, now >= audio.ts - 1 else {
        return now - startedAt < 6 ? .starting : .noAudio
    }
    guard audio.frames > 0, now - audio.lastBufferAt < 2 else { return .noAudio }
    if audio.state == "retrying" { return .retrying }
    if recognizing { return .recognizing }
    return normalizedInputLevel(audio.db) > 0.15 ? .input : .quiet
}

func destinationIsCurrent(_ destination: SpeechDestination, session: String, instance: String, request: String?) -> Bool {
    destination.session == session && destination.instance == instance && destination.request == request
}
