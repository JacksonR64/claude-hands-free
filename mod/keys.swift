import Cocoa
import ApplicationServices
setbuf(stdout, nil)
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(opts) { print("noperm") }
// Option+Space -> "toggle" (passed through to Handy); Option+S -> "stop" (swallowed only while speaking);
// Option+R -> "clip" (always swallowed, so only the first session's tap sees it: one press, one reading)
let cb: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return Unmanaged.passUnretained(event) }
    let f = event.flags
    guard f.contains(.maskAlternate), !f.contains(.maskCommand), !f.contains(.maskControl), !f.contains(.maskShift),
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return Unmanaged.passUnretained(event) }
    switch event.getIntegerValueField(.keyboardEventKeycode) {
    case 49: print("toggle")
    case 1:
        print("stop")
        if FileManager.default.fileExists(atPath: "/tmp/read-aloud.speaking") { return nil }
    case 15:
        print("clip")
        return nil
    default: break
    }
    return Unmanaged.passUnretained(event)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: cb, userInfo: nil) else { print("notap"); exit(1) }
let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
CFRunLoopRun()
