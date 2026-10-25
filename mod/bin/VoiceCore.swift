import Foundation

enum VoiceIntent: Equatable {
    case next, previous, select(String), pause, resume, stopSpeech, stopWork, open, approve, deny, cancel, dictate(String)
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

func destinationIsCurrent(_ destination: SpeechDestination, session: String, instance: String, request: String?) -> Bool {
    destination.session == session && destination.instance == instance && destination.request == request
}
