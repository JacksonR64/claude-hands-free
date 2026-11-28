// Sends one spoken reply into one project thread by typing it into the Claude desktop app, as the user.
// Usage: read-aloud-send <request.json>   ({"id", "project_id", "thread_id", "text", "ts"}; result in sent-<id>.json beside it)
// It opens the thread's link, checks the page address and the reply box before pasting, and checks the text arrived
// before pressing Return. It needs the macOS Accessibility permission; nothing is sent without it.
import Cocoa
import ApplicationServices

let claudeBundle = "com.anthropic.claudefordesktop"

// Watch mode: read-aloud-send --watch <state dir> <owner pid>
// Every two seconds, write what the Claude desktop window is showing (page address, and the titled or texted elements
// outside the sidebar) to claude-window.json, so the panel can read new replies aloud without any thread's help.
// Nothing is typed or clicked in this mode. It stops when the panel that started it exits.
func snapshotPages() -> [[String: Any]] {
    guard let app = claude() else { return [] }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var pages: [[String: Any]] = []
    func gather(_ e: AXUIElement, _ depth: Int, _ nodes: inout [[Any]]) {
        guard depth < 70, nodes.count < 4000 else { return }
        let role = attr(e, "AXRole") as? String ?? ""
        let title = String((attr(e, "AXTitle") as? String ?? "").prefix(300))
        if role == "AXGroup" && title == "Sidebar" { return }
        let value = role == "AXStaticText" ? String((attr(e, "AXValue") as? String ?? "").prefix(1500)) : ""
        if !title.isEmpty || !value.isEmpty { nodes.append([depth, role, title, value]) }
        for child in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { gather(child, depth + 1, &nodes) }
    }
    func find(_ e: AXUIElement, _ depth: Int) {
        guard depth < 30 else { return }
        if attr(e, "AXRole") as? String == "AXWebArea", let url = (attr(e, "AXURL") as? URL)?.absoluteString, url.contains("claude.ai/") {
            var nodes: [[Any]] = []
            gather(e, 0, &nodes)
            pages.append(["url": url, "title": attr(e, "AXTitle") as? String ?? "", "nodes": nodes])
            return
        }
        for child in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { find(child, depth + 1) }
    }
    for window in (attr(ax, "AXWindows") as? [AXUIElement]) ?? [] { find(window, 0) }
    return pages
}
func watch(_ dir: String, _ owner: Int32) -> Never {
    let path = dir + "/claude-window.json"
    var last = Data()
    var lastWrite = Date.distantPast
    var asked = false
    while true {
        if kill(owner, 0) != 0 { try? FileManager.default.removeItem(atPath: path); exit(0) }
        let trusted = AXIsProcessTrusted()
        if !trusted && !asked { asked = true; _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
        let pages = trusted ? snapshotPages() : []
        let body = (try? JSONSerialization.data(withJSONObject: pages)) ?? Data()
        if body != last || Date().timeIntervalSince(lastWrite) > 10 {
            last = body; lastWrite = Date()
            let whole: [String: Any] = ["ts": Date().timeIntervalSince1970, "trusted": trusted, "pages": pages]
            if let data = try? JSONSerialization.data(withJSONObject: whole) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
        sleep(trusted ? 2 : 5)
    }
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--watch", let owner = Int32(CommandLine.arguments[3]) {
    watch(CommandLine.arguments[2], owner)
}
guard CommandLine.arguments.count == 2 else { print("usage: read-aloud-send <request.json>"); exit(64) }
let requestPath = CommandLine.arguments[1]
guard let data = FileManager.default.contents(atPath: requestPath),
      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = request["id"] as? String, UUID(uuidString: id) != nil,
      let projectID = request["project_id"] as? String, let text = request["text"] as? String else { exit(65) }
try? FileManager.default.removeItem(atPath: requestPath)
let threadID = request["thread_id"] as? String ?? ""
let resultPath = (requestPath as NSString).deletingLastPathComponent + "/sent-\(id).json"

func finish(_ status: String, _ detail: String = "") -> Never {
    if let out = try? JSONSerialization.data(withJSONObject: ["id": id, "status": status, "detail": detail]) {
        try? out.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resultPath)
    }
    exit(status == "sent" ? 0 : 1)
}
func safeID(_ value: String, _ prefix: String) -> Bool {
    value.hasPrefix(prefix) && value.count < 120 && value.dropFirst(prefix.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
}
guard safeID(projectID, "chan_"), threadID.isEmpty || safeID(threadID, "cmsg_") else { finish("failed", "The thread address is not valid.") }
let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
guard !message.isEmpty, message.count <= 8000 else { finish("failed", "The message is empty or too long.") }
guard Date().timeIntervalSince1970 - (request["ts"] as? Double ?? 0) < 60 else { finish("failed", "The request expired. Say it again.") }

guard AXIsProcessTrusted() else {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)   // shows macOS's own prompt
    Thread.sleep(forTimeInterval: 1)
    finish("permission")
}

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func walk(_ e: AXUIElement, _ depth: Int, _ visit: (AXUIElement, String) -> Void) {
    visit(e, attr(e, "AXRole") as? String ?? "")
    guard depth < 60 else { return }
    for child in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(child, depth + 1, visit) }
}
func claude() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundle).first }

// the page showing this project (and this thread), and its reply box
func locate() -> (page: Bool, box: AXUIElement?) {
    guard let app = claude() else { return (false, nil) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var page = false
    var box: AXUIElement?
    let wanted = threadID.isEmpty ? "prompt" : "reply"
    for window in (attr(ax, "AXWindows") as? [AXUIElement]) ?? [] {
        var here = false
        var candidate: AXUIElement?
        walk(window, 0) { e, role in
            if role == "AXWebArea", let url = (attr(e, "AXURL") as? URL)?.absoluteString,
               url.contains("/project/" + projectID), threadID.isEmpty || url.contains("thread=" + threadID) { here = true }
            if role == "AXTextArea", candidate == nil, (attr(e, "AXDescription") as? String ?? "").lowercased().contains(wanted) { candidate = e }
        }
        if here { page = true; box = candidate; break }
    }
    return (page, box)
}
func squeezed(_ s: String) -> String { s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 0xFFFC }.map(String.init).joined() }
func boxText(_ box: AXUIElement) -> String { squeezed(attr(box, "AXValue") as? String ?? "") }
func key(_ code: CGKeyCode, command: Bool = false) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = command ? .maskCommand : []
        event?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}
func ready(_ box: AXUIElement) -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundle && (attr(box, "AXFocused") as? Bool ?? false)
}

guard let url = URL(string: "claude://code/project/\(projectID)" + (threadID.isEmpty ? "" : "?thread=\(threadID)")) else { finish("failed", "Bad link.") }
NSWorkspace.shared.open(url)
var box: AXUIElement?
let deadline = Date().addingTimeInterval(12)
while Date() < deadline {
    usleep(400_000)
    let found = locate()
    if found.page, let b = found.box { box = b; break }
}
guard let box = box else { finish("failed", "Claude didn't open that thread's reply box.") }

var focused = false
for _ in 0..<8 {
    claude()?.activate()
    AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(250_000)
    if ready(box) { focused = true; break }
}
guard focused else { finish("failed", "I couldn't put the cursor in the reply box.") }
guard boxText(box).isEmpty else { finish("failed", "That reply box already has a draft in it. Send or clear it first.") }

let board = NSPasteboard.general
let saved = board.string(forType: .string)
func restoreBoard() { board.clearContents(); if let saved = saved { board.setString(saved, forType: .string) } }
board.clearContents(); board.setString(message, forType: .string)
key(9, command: true)   // Command-V
var arrived = false
let probe = String(squeezed(message).prefix(24))
for _ in 0..<10 { usleep(200_000); if boxText(box).contains(probe) { arrived = true; break } }
guard arrived else { restoreBoard(); finish("failed", "The text didn't arrive in the reply box. Nothing was sent.") }
// same page, same box, still in front: only then press Return
guard locate().page, ready(box) else { restoreBoard(); finish("failed", "Claude changed page before sending. Your text is in the reply box, not sent.") }
key(36)
var cleared = false
for _ in 0..<15 { usleep(200_000); if boxText(box).isEmpty { cleared = true; break } }
restoreBoard()
finish(cleared ? "sent" : "failed", cleared ? "" : "I pressed Return but the reply box didn't clear. Check the thread.")
