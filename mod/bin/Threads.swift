// Project threads run in the cloud and cannot load the mod. They drop a small JSON file for each message meant for
// the user into a folder on this Mac; the app reads it aloud, keeps a numbered "waiting on you" list, and sends a
// spoken reply back by typing it into that thread in the Claude desktop app (see send.swift).
import Cocoa
import Darwin

struct ThreadItem: Codable, Identifiable, Equatable {
    var projectID: String, threadID: String, project: String, thread: String, text: String
    var waiting: Bool, ts: Double, number: Int
    var id: String { projectID + "/" + threadID }
    var name: String { thread.isEmpty ? (project.isEmpty ? "Project chat" : project) : project.isEmpty ? thread : "\(project), \(thread)" }
    var url: URL? { URL(string: "claude://code/project/\(projectID)" + (threadID.isEmpty ? "" : "?thread=\(threadID)")) }
}

func validCloudID(_ value: String, prefix: String) -> Bool {
    value.hasPrefix(prefix) && value.count > prefix.count + 5 && value.count < 120
        && value.dropFirst(prefix.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

// {"project": "...", "project_id": "chan_...", "thread": "...", "thread_id": "cmsg_...", "text": "...", "waiting": true}
func parseDrop(_ data: Data, now: Double) -> ThreadItem? {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let projectID = j["project_id"] as? String, validCloudID(projectID, prefix: "chan_") else { return nil }
    let threadID = j["thread_id"] as? String ?? ""
    guard threadID.isEmpty || validCloudID(threadID, prefix: "cmsg_") else { return nil }
    func line(_ key: String, _ limit: Int) -> String {
        String((j[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
    let waiting = j["waiting"] as? Bool ?? false
    let text = line("text", 4000)
    guard !text.isEmpty || !waiting else { return nil }   // an empty, not-waiting drop only clears the thread from the list
    return ThreadItem(projectID: projectID, threadID: threadID, project: line("project", 120), thread: line("thread", 120),
                      text: text, waiting: waiting, ts: now, number: 0)
}

func lowestFreeNumber(_ used: Set<Int>) -> Int { (1...).first { !used.contains($0) } ?? 1 }

// A waiting thread keeps its number until it is answered or dismissed, so "number four" stays number four.
struct ThreadBook: Codable, Equatable {
    var items: [ThreadItem] = []
    var waiting: [ThreadItem] { items.filter { $0.waiting }.sorted { $0.number < $1.number } }
    @discardableResult mutating func apply(_ drop: ThreadItem, alsoUsed: Set<Int> = []) -> ThreadItem {
        var item = drop
        if let index = items.firstIndex(where: { $0.id == drop.id }) {
            let old = items.remove(at: index)
            item.number = old.number
            if item.text.isEmpty { item.text = old.text }
            if item.project.isEmpty { item.project = old.project }
            if item.thread.isEmpty { item.thread = old.thread }
        }
        if !item.waiting { item.number = 0 }
        else if item.number == 0 { item.number = lowestFreeNumber(Set(items.filter { $0.waiting }.map(\.number)).union(alsoUsed)) }
        items.append(item)
        return item
    }
    mutating func clear(_ id: String) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].waiting = false; items[index].number = 0 }
    }
    mutating func prune(now: Double) {
        items.removeAll { now - $0.ts > 14 * 86400 }
        let quiet = items.filter { !$0.waiting }.sorted { $0.ts > $1.ts }
        if quiet.count > 40 { let drop = Set(quiet.dropFirst(40).map(\.id)); items.removeAll { drop.contains($0.id) } }
    }
}

// plain words for the synthesiser: no markdown, links or code
func speakable(_ text: String, limit: Int = 1500) -> String {
    var s = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " code block. ", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "https?://\\S+", with: " link ", options: .regularExpression)
    s = s.replacingOccurrences(of: "[*_#>|~`]+", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    return s.count > limit ? String(s.prefix(limit)) + ". The rest is in the thread." : s
}

// the opening sentence of a message, for a headline
func headline(_ text: String, limit: Int = 160) -> String {
    let s = speakable(text, limit: 4000)
    var end = s.endIndex
    if let r = s.range(of: "[.!?](\\s|$)", options: .regularExpression) { end = r.lowerBound }
    let first = String(s[..<end])
    return first.count > limit ? String(first.prefix(limit)) : first
}

// ---- The free route: the Sender helper snapshots what the Claude desktop window shows (send.swift, watch mode) and the
// panel picks new replies out of it. It only sees the project and thread that are on screen.
struct WindowNode { let depth: Int, role: String, title: String, value: String }
struct WindowMessage: Equatable {
    let inThread: Bool, threadTitle: String, fromClaude: Bool, head: String, body: String
    var key: String { "\(head)|\(body.prefix(160))" }
}
func looksLikeTimestamp(_ text: String) -> Bool {
    text.range(of: "^((Today|Yesterday) at )?\\d{1,2}:\\d{2}\\s?[AP]M$|^[A-Z][a-z]{2} \\d{1,2}, \\d{1,2}:\\d{2}\\s?[AP]M$|^[A-Z][a-z]+day, [A-Z][a-z]+ \\d{1,2}, \\d{4}$",
               options: .regularExpression) != nil
}
func parseWindowMessages(_ nodes: [WindowNode]) -> [WindowMessage] {
    var stack: [WindowNode] = []
    var out: [WindowMessage] = []
    for (i, n) in nodes.enumerated() {
        while let top = stack.last, top.depth >= n.depth { stack.removeLast() }
        defer { stack.append(n) }
        guard n.role == "AXGroup", n.title.range(of: "^Message \\d+$", options: .regularExpression) != nil else { continue }
        let groups = stack.filter { $0.role == "AXGroup" }
        let inThread = groups.contains { $0.title == "Thread messages" }
        guard inThread || groups.contains(where: { $0.title == "Chat messages" }) else { continue }
        var threadTitle = ""
        if inThread, let t = groups.firstIndex(where: { $0.title == "Threads" }), t > 0 { threadTitle = groups[t - 1].title }
        var head = "", fromClaude = false, parts: [String] = [], headDepth = 0
        var table: [String] = []   // a table is exposed three times (by row, by column, then headers); keep the by-row copy
        func closeTable() {
            if table.count > 2, let again = table[2...].firstIndex(of: table[0]) { table = Array(table[..<again]) }
            parts += table; table = []
        }
        var j = i + 1
        while j < nodes.count, nodes[j].depth > n.depth {
            let m = nodes[j]; j += 1
            if m.role == "AXHeading", head.isEmpty {
                if m.title.hasPrefix("Claude responded: ") { fromClaude = true; head = String(m.title.dropFirst(18)) }
                else if m.title.hasPrefix("You said: ") { head = String(m.title.dropFirst(10)) }
                headDepth = m.depth
                continue
            }
            if m.role == "AXButton", m.title.hasPrefix("Show message actions") { break }
            if m.role == "AXToolbar", m.title == "Message actions" { break }   // times and status follow; they change, the reply does not
            guard m.role == "AXStaticText", !head.isEmpty, !m.value.hasPrefix("Claude responded: "), !m.value.hasPrefix("You said: "),
                  !looksLikeTimestamp(m.value) else { continue }
            if m.depth >= headDepth + 4 { table.append(m.value) } else { closeTable(); parts.append(m.value) }
        }
        closeTable()
        guard !head.isEmpty else { continue }
        let body = parts.joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        out.append(WindowMessage(inThread: inThread, threadTitle: threadTitle, fromClaude: fromClaude, head: head, body: body.isEmpty ? head : body))
    }
    return out
}
func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern), let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

enum WaitingEntry { case thread(ThreadItem), session(S) }
struct WaitingRow: Identifiable {
    let number: Int, name: String, detail: String, entry: WaitingEntry
    var id: Int { number }
}

let speechLockPath = "/tmp/read-aloud.lock"   // shared with every session's mod: one voice at a time
func expandedPath(_ path: String) -> String { (path as NSString).expandingTildeInPath }

// One line per event (drop received, spoken, reply sent) so "it didn't read" can be checked. Names only, never message text.
func threadLog(_ line: String) {
    guard !demo else { return }
    let path = voiceDir + "/threads.log"
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
    if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64, size > 400_000 { try? FileManager.default.removeItem(atPath: path) }
    if let handle = FileHandle(forWritingAtPath: path) { defer { try? handle.close() }; handle.seekToEndOfFile(); handle.write(data) }
    else { FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) }
}

extension Store {
    var bookPath: String { voiceDir + "/threads.json" }
    func loadBook() {
        guard !demo, let data = FileManager.default.contents(atPath: bookPath), let saved = try? JSONDecoder().decode(ThreadBook.self, from: data) else { return }
        book = saved
    }
    func saveBook() {
        guard !demo, let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: URL(fileURLWithPath: bookPath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bookPath)
    }

    // sessions with a pending question or approval share the numbers with waiting threads
    func refreshNumbers() {
        let needing = Set(all.filter { !$0.pending.isEmpty }.map(\.id))
        var numbers = sessionNumbers.filter { needing.contains($0.key) }
        for s in all where needing.contains(s.id) && numbers[s.id] == nil {
            numbers[s.id] = lowestFreeNumber(Set(numbers.values).union(book.waiting.map(\.number)))
        }
        if numbers != sessionNumbers { sessionNumbers = numbers }
    }
    var waitingRows: [WaitingRow] {
        var rows = book.waiting.map { WaitingRow(number: $0.number, name: $0.name, detail: $0.text, entry: .thread($0)) }
        for s in all { if let n = sessionNumbers[s.id], let request = s.pending.first {
            rows.append(WaitingRow(number: n, name: label(s), detail: request.question, entry: .session(s)))
        } }
        return rows.sorted { $0.number < $1.number }
    }

    func scanThreads(now: Double = Date().timeIntervalSince1970) {
        guard !demo, now - lastThreadScan >= 1 else { return }
        lastThreadScan = now
        let fm = FileManager.default
        let inbox = expandedPath(settings.threadInbox)
        try? fm.createDirectory(atPath: inbox, withIntermediateDirectories: true)
        var changed = false
        for file in ((try? fm.contentsOfDirectory(atPath: inbox)) ?? []).sorted() where file.hasSuffix(".json") && !file.hasPrefix(".") {
            let path = inbox + "/" + file
            guard !handledDrops.contains(file), let data = fm.contents(atPath: path) else { continue }
            guard let drop = parseDrop(data, now: now) else {
                // possibly half-written: try again for a minute, then set it aside
                let made = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? Date()
                if Date().timeIntervalSince(made) > 60 {
                    try? fm.createDirectory(atPath: inbox + "/rejected", withIntermediateDirectories: true)
                    if (try? fm.moveItem(atPath: path, toPath: inbox + "/rejected/" + file)) == nil { handledDrops.insert(file) }
                }
                continue
            }
            if (try? fm.removeItem(atPath: path)) == nil { handledDrops.insert(file) }
            let fresh = !drop.text.isEmpty
            var incoming = drop
            // Focus and Headlines: everything unheard gets a number, so it can be opened or read by voice
            if settings.mode != "everything", fresh, !onScreen.contains(drop.id) { incoming.waiting = true }
            let item = book.apply(incoming, alsoUsed: Set(sessionNumbers.values))
            changed = true
            threadLog("drop \(item.name) waiting=\(item.waiting) number=\(item.number) reading=\(settings.reading)")
            if fresh { announce(item) }
        }
        if changed { book.prune(now: now); saveBook() }
    }
    // Background music gets into the microphone and is hard to hear a reply over. While the app or a session is talking, or a
    // message is being taken, whatever is playing on this Mac (AirPlay included) is paused; it carries on a moment afterwards.
    // Only media this app paused is started again. osascript does the asking because macOS refuses other unsigned callers.
    func mediaCommand(_ pause: Bool, done: @escaping (Bool) -> Void) {
        let script = """
        ObjC.import('Foundation');
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
        ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
        var playing = $.NSClassFromString('MRNowPlayingRequest').localIsPlaying;
        if (\(pause ? "playing" : "!playing")) $.MRMediaRemoteSendCommand(\(pause ? 1 : 0), $());
        playing ? 'playing' : 'stopped';
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-l", "JavaScript", "-e", script]
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            var wasPlaying = false
            if (try? p.run()) != nil {
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit(); wasPlaying = text.contains("playing")
            }
            DispatchQueue.main.async { done(wasPlaying) }
        }
    }
    func tickMedia(now: Double = Date().timeIntervalSince1970) {
        guard !demo, !mediaBusy else { return }
        let armed = (replyTarget.map { Date().timeIntervalSince($0.armedAt) < 20 } ?? false) || (replyDirect.map { Date().timeIntervalSince($0.armedAt) < 20 } ?? false)
        let wantQuiet = settings.pauseMedia && (isSpeaking || (appSpeechBusy?() ?? false) || !speechQueue.isEmpty
            || (settings.voice && (armed || sendEndsAt != nil || handyHeld != nil || now < messageExpectedUntil)))
        if wantQuiet {
            let rising = quietSince == 0
            quietSince = now
            guard rising, !mediaPaused else { return }
            mediaBusy = true
            mediaCommand(true) { [weak self] wasPlaying in
                guard let self = self else { return }
                self.mediaBusy = false
                if wasPlaying { self.mediaPaused = true; self.mediaPausedAt = now; threadLog("media paused") }
            }
        } else {
            guard quietSince > 0, now - quietSince >= 2.5 else { return }
            quietSince = 0
            guard mediaPaused else { return }
            mediaPaused = false; mediaBusy = true
            mediaCommand(false) { [weak self] _ in self?.mediaBusy = false; threadLog("media resumed") }
        }
    }
    // New replies in the window: the first sight of a chat is only a baseline, so opening an old thread reads nothing out.
    func scanWindow(now: Double = Date().timeIntervalSince1970) {
        guard !demo, settings.watchWindow, now - lastWindowScan >= 2 else { return }
        lastWindowScan = now
        guard let data = FileManager.default.contents(atPath: voiceDir + "/claude-window.json"),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ts = j["ts"] as? Double, ts != lastWindowStamp else { return }
        lastWindowStamp = ts
        windowTrusted = j["trusted"] as? Bool ?? false
        var changed = false
        var visible = Set<String>()
        defer { onScreen = visible }
        let focused = settings.mode != "everything"
        for page in (j["pages"] as? [[String: Any]]) ?? [] {
            let url = page["url"] as? String ?? ""
            guard let projectID = firstMatch("/project/(chan_[A-Za-z0-9]+)", in: url), validCloudID(projectID, prefix: "chan_") else { continue }
            let threadID = firstMatch("[?&]thread=(cmsg_[A-Za-z0-9]+)", in: url) ?? ""
            var project = page["title"] as? String ?? ""
            if project.hasSuffix(" - Claude Code") { project = String(project.dropLast(14)) }
            let nodes = ((page["nodes"] as? [[Any]]) ?? []).compactMap { n -> WindowNode? in
                guard n.count == 4, let depth = n[0] as? Int, let role = n[1] as? String, let title = n[2] as? String, let value = n[3] as? String else { return nil }
                return WindowNode(depth: depth, role: role, title: title, value: value)
            }
            let messages = parseWindowMessages(nodes)
            for inThread in [false, true] {
                let list = messages.filter { $0.inThread == inThread }
                guard !list.isEmpty, !inThread || !threadID.isEmpty else { continue }
                let container = projectID + "/" + (inThread ? threadID : "")
                visible.insert(container)
                func item(for m: WindowMessage, waiting: Bool) -> ThreadItem {
                    ThreadItem(projectID: projectID, threadID: inThread ? threadID : "", project: project, thread: inThread ? m.threadTitle : "",
                               text: String(m.body.prefix(700)), waiting: waiting, ts: now, number: 0)
                }
                guard var known = windowSeen[container] else {
                    windowSeen[container] = Set(list.map(\.key))
                    // opened because something was waiting there: read that one message, now that it is on screen
                    if focused, book.items.contains(where: { $0.id == container && $0.waiting }), let m = list.last, m.fromClaude {
                        let read = book.apply(item(for: m, waiting: m.body.contains("?")), alsoUsed: Set(sessionNumbers.values))
                        changed = true
                        threadLog("window opened \(read.name)")
                        readOnScreen(read, body: m.body)
                    }
                    continue
                }
                for (index, m) in list.enumerated() where !known.contains(m.key) {
                    if index < list.count - 3 { known.insert(m.key); continue }   // older history scrolled into view
                    let pending = container + "|" + m.key
                    guard let first = windowPending[pending] else { windowPending[pending] = now; continue }
                    guard now - first >= 1.5 else { continue }   // still the same after a second look: not half-written
                    windowPending.removeValue(forKey: pending); known.insert(m.key)
                    if !m.fromClaude {   // answered by typing: no longer waiting
                        if book.items.contains(where: { $0.id == container && $0.waiting }) { book.clear(container); changed = true }
                        continue
                    }
                    if settings.mode == "focus" {   // on screen: read this one in full, and drop anything still queued
                        let read = book.apply(item(for: m, waiting: m.body.contains("?")), alsoUsed: Set(sessionNumbers.values))
                        changed = true
                        threadLog("window focus \(read.name)")
                        readOnScreen(read, body: m.body)
                        continue
                    }
                    let drop = item(for: m, waiting: settings.mode == "headlines" || m.body.contains("?"))
                    let recent = lastDropped[container].map { now - $0 < 20 } ?? false   // the thread also dropped a file for this
                    let item = recent ? drop : book.apply(drop, alsoUsed: Set(sessionNumbers.values))
                    changed = changed || !recent
                    threadLog("window \(item.name) waiting=\(item.waiting) duplicate=\(recent)")
                    if !recent { announce(item, limit: 600) }
                }
                windowSeen[container] = known
            }
        }
        if windowPending.count > 300 { windowPending.removeAll() }
        if changed { book.prune(now: now); saveBook() }
    }
    // Focus: the message on screen is read in full, alone. Whatever was queued before it is dropped, never read back to back.
    func readOnScreen(_ item: ThreadItem, body: String) {
        lastAnnounced[item.id] = item.ts
        lastRead = item
        threadEvents.insert("thread-\(item.id)-\(Int(item.ts))")
        notice = "Reading: " + item.name
        guard settings.reading else { return }
        speechQueue = [speakable(body, limit: 2500) + (settings.voice ? " End of message. Say reply to answer." : "")]
    }
    // what is said for a message in the quieter modes; nil in Everything, which reads it all
    func shortNotice(_ item: ThreadItem) -> String? {
        switch settings.mode {
        case "focus": return "Message waiting from \(item.name). Number \(item.number)."
        case "headlines": return "\(item.name) says: \(headline(item.text)). Say open number \(item.number) to hear more."
        default: return nil
        }
    }
    func announce(_ item: ThreadItem, limit: Int) {
        lastAnnounced[item.id] = item.ts
        threadEvents.insert("thread-\(item.id)-\(Int(item.ts))")
        notice = (item.waiting ? "Number \(item.number) is waiting: " : "New message: ") + item.name
        guard settings.reading else { return }
        if let short = shortNotice(item) { speechQueue.append(short); return }
        speechQueue.append("\(item.name). \(speakable(item.text, limit: limit))" + (item.waiting ? " Waiting on you. Number \(item.number)." : ""))
    }
    func announce(_ item: ThreadItem) {
        lastDropped[item.id] = item.ts
        if let seen = lastAnnounced[item.id], item.ts - seen < 20 { return }   // already read from the window
        if settings.mode == "focus", onScreen.contains(item.id) { return }   // on screen: the window reader reads the real message
        threadEvents.insert("thread-\(item.id)-\(Int(item.ts))")
        notice = (item.waiting ? "Number \(item.number) is waiting: " : "New message: ") + item.name
        guard settings.reading else { return }
        if let short = shortNotice(item) { speechQueue.append(short); return }
        speechQueue.append("\(item.name). \(speakable(item.text))" + (item.waiting ? " Waiting on you. Number \(item.number)." : ""))
    }

    // queued thread messages wait their turn behind session replies and the user's own speech
    func tickSpeech(now: Double = Date().timeIntervalSince1970) {
        guard !demo else { return }
        let busy = appSpeechBusy?() ?? false
        if holdingSpeechLock && !busy { rmdir(speechLockPath); holdingSpeechLock = false; lastAppSpeechEnd = now }
        if !settings.reading { speechQueue.removeAll() }
        guard !busy, !speechQueue.isEmpty, now - lastAppSpeechEnd > 1.5 else { queueWaitingSince = speechQueue.isEmpty ? 0 : queueWaitingSince; return }
        if queueWaitingSince == 0 { queueWaitingSince = now }
        // wait for a session's reply or the user's own speech to finish, but never hold a message for more than 30 seconds
        let blocked = speaking != nil || !speechIDs.isEmpty || handySession != nil || handyHeld != nil
        if blocked && now - queueWaitingSince < 30 { return }
        if let made = (try? FileManager.default.attributesOfItem(atPath: speechLockPath))?[.modificationDate] as? Date,
           Date().timeIntervalSince(made) > 600 { rmdir(speechLockPath) }
        guard mkdir(speechLockPath, 0o755) == 0 || now - queueWaitingSince > 45 else { return }
        holdingSpeechLock = true; queueWaitingSince = 0
        threadLog("speak \(speechQueue[0].prefix(60))")
        let next = speechQueue.removeFirst()
        assistantCaption = next
        appSay?(next)
    }
    // an answer to a voice command is spoken at once
    func say(_ text: String) {
        notice = text
        guard !demo else { return }
        if let current = speaking { send("stop", current) }
        assistantCaption = text
        appSay?(text)
    }
    func stopAppSpeech() { speechQueue.removeAll(); appStop?() }

    func sayWaiting() {
        refreshNumbers()
        let rows = waitingRows
        if rows.isEmpty { say("Nothing is waiting on you."); return }
        say("\(rows.count) waiting. " + rows.map { "Number \($0.number): \($0.name)." }.joined(separator: " ")
            + " Say read number, or reply to number, then your message.")
    }
    func row(_ number: Int) -> WaitingRow? {
        refreshNumbers()
        if let found = waitingRows.first(where: { $0.number == number }) { return found }
        say(waitingRows.isEmpty ? "Nothing is waiting on you." : "There is no number \(number). Say who's waiting to hear the list.")
        return nil
    }
    func readRow(_ number: Int) {
        guard let r = row(number) else { return }
        say("Number \(number). \(r.name). \(speakable(r.detail))")
    }
    func openRow(_ number: Int) {
        guard let r = row(number) else { return }
        switch r.entry {
        case .thread(let item): if !demo, let url = item.url { NSWorkspace.shared.open(url) }
        case .session(let s): openChat(s)
        }
        notice = "Opened number \(number): \(r.name)."
    }
    func dismissRow(_ number: Int) {
        guard let r = row(number) else { return }
        guard case .thread(let item) = r.entry else { say("Number \(number) is a live question. Answer it or deny it."); return }
        book.clear(item.id); saveBook()
        say("Dismissed number \(number).")
    }
    func reply(_ number: Int, _ text: String) {
        if number == 0 {   // "reply": to the message that was just read on screen
            replyTarget = nil
            guard let item = lastRead else { say("Open a message first, then say reply."); return }
            if !text.isEmpty { replyDirect = nil; sendToThread(item, number: 0, text: text); return }
            replyDirect = (item, Date())
            notice = "Say your reply to \(item.name)."
            if !demo {
                stopAppSpeech()
                NSSound(named: "Tink")?.play()
                if settings.dictation == "handy" { startHandy(nil) }
            }
            return
        }
        guard let r = row(number) else { replyTarget = nil; return }
        if text.isEmpty {   // "reply to number four" on its own: the next thing said is the message
            replyTarget = (number, Date())
            notice = "Say your reply to number \(number): \(r.name)."
            if !demo {
                NSSound(named: "Tink")?.play()
                if settings.dictation == "handy" { startHandy(nil) }
            }
            return
        }
        replyTarget = nil
        switch r.entry {
        case .thread(let item): sendToThread(item, number: number, text: text)
        case .session(let s):
            select(s, read: false)
            guard let request = s.pending.first else { send("reply", s, text: text, tracked: true); return }
            if request.kind == "permission" { say("Number \(number) needs an approval. Say approve action or deny action."); return }
            answer(text, destination: SpeechDestination(session: s.id, instance: s.instance, request: request.id), permission: false)
        }
    }

    func sendToThread(_ item: ThreadItem, number: Int, text: String) {
        if demo { book.clear(item.id); notice = "Demo: reply to number \(number) captured. Nothing was sent."; return }
        let id = UUID().uuidString
        let request = voiceDir + "/send-\(id).json"
        do {
            try atomicJSON(["id": id, "project_id": item.projectID, "thread_id": item.threadID, "text": text,
                            "ts": Date().timeIntervalSince1970], path: request)
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("ReadAloudSend.app").path
            let app = bundled.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory() + "/.cache/read-aloud/ReadAloudSend.app"
            // LaunchServices makes the sender its own app, so macOS asks for (and remembers) its Accessibility permission, not the panel's
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-n", "-g", "-a", app, "--args", request]
            try p.run()
            sends[id] = (item.id, number, item.name, Date())
            delivery = number == 0 ? "Sending to \(item.name)…" : "Sending to number \(number): \(item.name)…"
        } catch { say("Couldn't start the sender: \(error.localizedDescription)") }
    }
    func pollSends() {
        for (id, send) in Array(sends) {
            let path = voiceDir + "/sent-\(id).json"
            if let data = FileManager.default.contents(atPath: path), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try? FileManager.default.removeItem(atPath: path)
                sends.removeValue(forKey: id)
                let detail = j["detail"] as? String ?? ""
                threadLog("send \(send.name) status=\(j["status"] as? String ?? "?") \(detail)")
                switch j["status"] as? String ?? "" {
                case "sent":
                    book.clear(send.item); saveBook()
                    delivery = "Sent to \(send.name)."; say("Sent to number \(send.number).")
                case "permission":
                    delivery = "Allow “Claude Hands Free Sender” in System Settings › Privacy & Security › Accessibility, then repeat your reply."
                    say("I need permission to type into Claude. Turn on Claude Hands Free Sender under Accessibility in System Settings, then say it again.")
                default:
                    delivery = "Not sent to \(send.name): \(detail)"; say("I couldn't send to number \(send.number). \(detail)")
                }
            } else if Date().timeIntervalSince(send.started) > 40 {
                sends.removeValue(forKey: id)
                try? FileManager.default.removeItem(atPath: voiceDir + "/send-\(id).json")
                delivery = "No confirmation from the sender for \(send.name). Check the thread before repeating."
                say("I got no confirmation for number \(send.number). Check the thread before repeating.")
            }
        }
    }
}
