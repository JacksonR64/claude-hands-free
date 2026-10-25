import Foundation

func panelSelfTests() {
    assert(demo, "Run tests with --demo to disable real IPC")
    assert(voiceIntent("Okay next session") == .next)
    assert(voiceIntent("Okay Claude, move to the printers session") == .select("printers"))
    assert(voiceIntent("Switch to Home Assistant") == .select("home assistant"))
    assert(voiceIntent("Next session button needs more contrast") == .dictate("Next session button needs more contrast"))
    assert(voiceIntent("yes") == .dictate("yes"))
    assert(voiceIntent("approve action") == .approve)
    assert(voiceIntent("stop speaking") != voiceIntent("stop working"))
    let candidates = [VoiceCandidate(id: "a", names: ["Printer calibration"]), VoiceCandidate(id: "b", names: ["Printer queue"])]
    assert(matchingSessions("printer", candidates: candidates).count == 2)
    assert(matchingSessions("printer calibration", candidates: candidates) == ["a"])
    assert(matchingSessions("print", candidates: candidates).isEmpty)
    let pin = SpeechDestination(session: "a", instance: "first", request: "q-1")
    assert(!destinationIsCurrent(pin, session: "a", instance: "second", request: "q-1"))
    assert(!destinationIsCurrent(pin, session: "a", instance: "first", request: "q-2"))

    let store = Store(); store.loadDemo()
    func speak(_ text: String, beforeFinal: (() -> Void)? = nil) {
        let id = UUID().uuidString
        store.voice(["event": "begin", "id": id])
        beforeFinal?()
        store.voice(["event": "final", "id": id, "text": text])
    }
    assert(store.activeID == "printers")
    speak("Okay next session")
    assert(store.activeID == "portfolio")
    speak("Move to the printers session")
    assert(store.activeID == "printers")
    speak("Clear to black")
    assert(store.notice == "Demo response: Clear to black")
    speak("This must not go to another session", beforeFinal: { store.select(store.all[1], read: false) })
    assert(store.notice.contains("changed while you spoke"))
    let previous = store.activeID
    store.voice(["event": "final", "id": "no-begin", "text": "next session"])
    assert(store.activeID == previous)
    speak("Switch to unknown session")
    assert(store.activeID == previous)
    assert(store.notice.contains("No session matches"))
    print("Voice parsing, ambiguity, request identity and full panel routing checks passed")
}
