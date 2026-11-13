// Presses keys the way a physical keyboard does, so Blip's key listener (keyspy's
// MacKeyServer, a CGEventTap) sees them. The release test builds it on the runner:
//
//   swiftc -O tests/mac/keys.swift -o "$RUNNER_TEMP/keys"
//
// Usage
//   keys down fn            hold the Fn (globe) key
//   keys up fn              release it
//   keys chord fn+space     press each key in order, release in reverse (Blip's hands-free toggle)
//   keys chord cmd+ctrl+v   (Blip's "Paste last transcript")
//   keys tap escape         press and release one key
//   keys watch 5            print every key event a session event tap sees for 5 s
//   keys access             print whether this process may listen to and post events
//   keys mic                print whether this process may use the microphone
//   keys responsible        print the process macOS charges this one's privacy checks to
//
// Modifiers (fn, cmd, ctrl, alt, shift) are sent as flagsChanged events with the
// matching flag, which is what a real keyboard produces and what MacKeyServer reads.
import AVFoundation
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

let modifiers: [String: (code: CGKeyCode, flag: CGEventFlags)] = [
  "fn": (63, .maskSecondaryFn),
  "cmd": (55, .maskCommand),
  "ctrl": (59, .maskControl),
  "alt": (58, .maskAlternate),
  "shift": (56, .maskShift),
]
let keys: [String: CGKeyCode] = [
  "space": 49, "escape": 53, "return": 36, "tab": 48, "delete": 51,
  "a": 0, "c": 8, "n": 45, "v": 9, "w": 13,
]

// Flags held by this invocation. A separate `keys up fn` starts from none, which
// is right: it releases the only key the previous `keys down fn` held.
var held: CGEventFlags = []

func fail(_ message: String) -> Never {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
  exit(2)
}

func post(_ code: CGKeyCode, keyDown: Bool, type: CGEventType? = nil) {
  let source = CGEventSource(stateID: .hidSystemState)
  guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown) else {
    fail("could not create an event for key code \(code)")
  }
  if let type { event.type = type }
  event.flags = held
  event.post(tap: .cghidEventTap)
  usleep(40_000)
}

func press(_ name: String) {
  if let m = modifiers[name] {
    held.insert(m.flag)
    post(m.code, keyDown: true, type: .flagsChanged)
  } else if let code = keys[name] {
    post(code, keyDown: true)
  } else {
    fail("unknown key: \(name)")
  }
}

func release(_ name: String) {
  if let m = modifiers[name] {
    held.remove(m.flag)
    post(m.code, keyDown: false, type: .flagsChanged)
  } else if let code = keys[name] {
    post(code, keyDown: false)
  } else {
    fail("unknown key: \(name)")
  }
}

func watch(seconds: Double) {
  let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
  let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
  let callback: CGEventTapCallBack = { _, type, event, _ in
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    print("event type=\(type.rawValue) code=\(code) flags=0x\(String(event.flags.rawValue, radix: 16))")
    fflush(stdout)
    return Unmanaged.passUnretained(event)
  }
  guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: mask, callback: callback, userInfo: nil)
  else {
    print("TAP_CREATE_FAILED")
    exit(3)
  }
  let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
  CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
  CGEvent.tapEnable(tap: tap, enable: true)
  print("TAP_READY")
  fflush(stdout)
  CFRunLoopRunInMode(.defaultMode, seconds, false)
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first ?? "", args.count) {
case ("down", 2): press(args[1])
case ("up", 2): release(args[1])
case ("tap", 2):
  press(args[1])
  release(args[1])
case ("chord", 2):
  let names = args[1].split(separator: "+").map(String.init)
  names.forEach(press)
  usleep(80_000)
  names.reversed().forEach(release)
case ("watch", 2): watch(seconds: Double(args[1]) ?? 5)
case ("access", 1):
  print("listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess()) accessibility=\(AXIsProcessTrusted())")
case ("mic", 1):
  switch AVCaptureDevice.authorizationStatus(for: .audio) {
  case .authorized: print("authorized")
  case .denied: print("denied")
  case .restricted: print("restricted")
  case .notDetermined: print("not-determined")
  @unknown default: print("unknown")
  }
case ("responsible", 1):
  // Private but stable libsystem call; TCC uses the same answer.
  typealias Responsible = @convention(c) (pid_t) -> pid_t
  guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
    fail("responsibility_get_pid_responsible_for_pid not found")
  }
  let pid = unsafeBitCast(symbol, to: Responsible.self)(getpid())
  var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { fail("no path for pid \(pid)") }
  print(String(cString: path))
default:
  fail("usage: keys down|up|tap KEY | chord K1+K2 | watch SECONDS | access | mic | responsible")
}
