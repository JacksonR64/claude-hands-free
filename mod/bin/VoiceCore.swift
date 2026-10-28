import Foundation

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
    case next, previous, select(String), pause, resume, stopSpeech, stopWork, stopListening, readAgain, open, approve, deny, cancel, dictate(String)
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
    default: break
    }
    for prefix in ["switch to ", "move to ", "go to ", "select session "] where text.hasPrefix(prefix) {
        var name = String(text.dropFirst(prefix.count))
        if name.hasPrefix("the ") { name = String(name.dropFirst(4)) }
        for suffix in [" session", " chat", " conversation"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)); break }
        if !name.isEmpty { return .select(name) }
    }
    return .dictate(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
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
