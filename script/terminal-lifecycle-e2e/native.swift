import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO

func consoleState() -> [String: Any] {
    var errors: [String] = []
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    func boolean(_ key: String, allowNumber: Bool = false) -> Bool? {
        guard let value = session?[key] as? NSNumber else {
            errors.append("Missing/invalid session key: " + key)
            return nil
        }
        guard
            CFGetTypeID(value) == CFBooleanGetTypeID()
                || (allowNumber && (value == 0 || value == 1))
        else {
            errors.append("Ambiguous session key: " + key)
            return nil
        }
        return value.boolValue
    }
    if session == nil { errors.append("No Quartz GUI session") }
    let onConsole = boolean(kCGSessionOnConsoleKey as String)
    let loginDone = boolean(kCGSessionLoginDoneKey as String)
    let lockValue = session?["CGSSessionScreenIsLocked"]
    var locked = lockValue == nil ? nil : boolean("CGSSessionScreenIsLocked", allowNumber: true)
    let sessionUID = session?[kCGSessionUserIDKey as String] as? NSNumber
    var console = stat()
    let consoleError = stat("/dev/console", &console)
    if consoleError != 0 { errors.append("Cannot stat /dev/console: errno \(errno)") }
    if sessionUID == nil { errors.append("Missing/invalid session user ID") }
    if onConsole == false { errors.append("Session is not on console") }
    if loginDone == false { errors.append("Session login is incomplete") }
    if locked == true { errors.append("Desktop is locked; unlock the interactive console before running") }
    if sessionUID?.uint32Value != getuid() || (consoleError == 0 && console.st_uid != getuid()) {
        errors.append("Session/console user differs from invoking user")
    }
    let validConsole =
        session != nil && onConsole == true && loginDone == true
        && sessionUID?.uint32Value == getuid() && consoleError == 0 && console.st_uid == getuid()
    if lockValue == nil && validConsole {
        locked = false
    } else if lockValue == nil {
        errors.append("Absent lock key without a valid interactive console")
    }
    return [
        "ready": errors.isEmpty, "errors": errors,
        "sessionPresent": session != nil,
        "onConsole": onConsole as Any? ?? NSNull(), "loginDone": loginDone as Any? ?? NSNull(),
        "screenLocked": locked as Any? ?? NSNull(), "lockKeyPresent": lockValue != nil,
        "lockSignal": lockValue == nil
            ? (validConsole ? "observed-key-absence-in-valid-console" : "unknown-invalid-console")
            : (locked == nil ? "invalid-present-value" : "explicit-session-value"),
        "lockRaw": lockValue.map { String(describing: $0) } ?? "missing",
        "lockCFTypeID": lockValue.map { CFGetTypeID($0 as CFTypeRef) } as Any? ?? NSNull(),
        "sessionUID": sessionUID as Any? ?? NSNull(), "invokingUID": getuid(),
        "consoleUID": consoleError == 0 ? console.st_uid as Any : NSNull(), "consoleStatError": consoleError,
    ]
}
func requireConsole() {
    let state = consoleState()
    guard state["ready"] as? Bool == true else {
        let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        fail("Interactive console unavailable: " + String(decoding: data ?? Data(), as: UTF8.self))
    }
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
func emit(_ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
        fail("JSON encoding failed")
    }
    print(String(decoding: data, as: UTF8.self))
}
func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func tree(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 30 else { return [] }
    return [element] + children(element).flatMap { tree($0, depth: depth + 1) }
}
func string(_ element: AXUIElement, _ name: String) -> String {
    attr(element, name) as? String ?? ""
}
func terminal(_ element: AXUIElement) -> Bool {
    string(element, kAXRoleAttribute) == kAXTextAreaRole
        && string(element, kAXDescriptionAttribute).hasPrefix("Terminal output, ")
}
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : ""
if command == "probe" {
    let console = consoleState()
    emit([
        "accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess(),
        "console": console["ready"] as? Bool == true, "consoleState": console,
    ])
    exit(0)
}
if command == "session" {
    emit(consoleState())
    exit(0)
}
if command == "canonical-path" {
    guard args.count == 3 else { fail("canonical-path requires one path") }
    print(URL(fileURLWithPath: args[2]).resolvingSymlinksInPath().standardizedFileURL.path)
    exit(0)
}
if command == "paths" {
    emit([
        "home": FileManager.default.homeDirectoryForCurrentUser.path,
        "nsHome": NSHomeDirectory(),
        "support": FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path,
        "environmentHome": ProcessInfo.processInfo.environment["HOME"] ?? "",
        "fixedHome": ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "",
    ])
    exit(0)
}
guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { fail("Missing AX or screen recording access") }
requireConsole()
if command == "launch" {
    struct Request: Decodable {
        let bundle: String
        let bundleID: String
        let environment: [String: String]
        let arguments: [String]
    }
    guard args.count == 4,
        let data = try? Data(contentsOf: URL(fileURLWithPath: args[2])),
        let request = try? JSONDecoder().decode(Request.self, from: data)
    else { fail("launch requires request JSON and receipt path") }
    let bundleURL = URL(fileURLWithPath: request.bundle).resolvingSymlinksInPath()
    let expectedExecutable = bundleURL.appendingPathComponent("Contents/MacOS/awesoMux").path
    guard
        !NSWorkspace.shared.runningApplications.contains(where: {
            $0.executableURL?.resolvingSymlinksInPath().path == expectedExecutable
        })
    else { fail("Copied bundle already running") }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    configuration.environment = request.environment
    configuration.arguments = request.arguments
    var receipt: [String: Any]?
    NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { application, error in
        guard let application else {
            receipt = ["status": "error", "reason": error?.localizedDescription ?? "No running application returned"]
            return
        }
        let identityTask = Process()
        let identityOutput = Pipe()
        identityTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        identityTask.arguments = ["-p", String(application.processIdentifier), "-o", "lstart="]
        var identityEnvironment = ProcessInfo.processInfo.environment
        identityEnvironment["TZ"] = "UTC"
        identityEnvironment["LC_ALL"] = "C"
        identityTask.environment = identityEnvironment
        identityTask.standardOutput = identityOutput
        do { try identityTask.run() } catch {
            receipt = ["status": "identity-mismatch", "reason": "Cannot inspect launched process start"]
            return
        }
        let startData = identityOutput.fileHandleForReading.readDataToEndOfFile()
        identityTask.waitUntilExit()
        let processStart = String(decoding: startData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let executableRaw = application.executableURL?.path ?? ""
        let executable = application.executableURL?.resolvingSymlinksInPath().path ?? ""
        receipt = [
            "status": executable == expectedExecutable && application.bundleIdentifier == request.bundleID && !processStart.isEmpty
                && identityTask.terminationStatus == 0 ? "launched" : "identity-mismatch",
            "pid": application.processIdentifier,
            "executable": executable,
            "executableRaw": executableRaw,
            "expectedExecutable": expectedExecutable,
            "bundleID": application.bundleIdentifier ?? "",
            "launchDate": application.launchDate?.timeIntervalSince1970 ?? 0,
            "processStart": processStart,
        ]
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while receipt == nil && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    let result = receipt ?? ["status": "pending", "reason": "LaunchServices completion deadline"]
    do {
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try encoded.write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    } catch { fail("Cannot persist LaunchServices receipt: \(error)") }
    emit(result)
    exit(result["status"] as? String == "launched" ? 0 : 2)
}
guard args.count >= 3, let pid = Int32(args[2]) else { fail("Owned app PID required") }
let ax = AXUIElementCreateApplication(pid)
let timeoutError = AXUIElementSetMessagingTimeout(ax, 2)
var windowValue: CFTypeRef?
let windowsError = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windowValue)
let windows = windowValue as? [AXUIElement] ?? []
let ownedCG =
    (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []).filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid
    }
if command == "diagnose" {
    func record(_ element: AXUIElement) -> [String: Any] {
        var owner: pid_t = 0
        let ownerError = AXUIElementGetPid(element, &owner)
        var attributes: [String: Any] = [:]
        for name in [
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXModalAttribute,
            kAXPositionAttribute, kAXSizeAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        ] {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            var entry: [String: Any] = ["error": error.rawValue]
            if let value {
                entry["value"] = String(describing: value)
                entry["cfTypeID"] = CFGetTypeID(value)
            }
            attributes[name] = entry
        }
        return [
            "pid": owner, "pidError": ownerError.rawValue,
            "cfTypeID": CFGetTypeID(element),
            "cfType": String(describing: CFCopyTypeIDDescription(CFGetTypeID(element))),
            "equalsApplicationRoot": CFEqual(element, ax), "attributes": attributes,
        ]
    }
    var result: [String: Any] = [
        "pid": pid, "messagingTimeoutError": timeoutError.rawValue,
        "windowsError": windowsError.rawValue, "application": record(ax),
        "windowElements": windows.map(record), "ownedCGWindows": ownedCG,
    ]
    var modalContents: [[String: Any]] = []
    for candidate in windows {
        var owner: pid_t = 0
        guard AXUIElementGetPid(candidate, &owner) == .success, owner == pid,
            string(candidate, kAXRoleAttribute) == kAXWindowRole,
            (attr(candidate, kAXModalAttribute) as? Bool) == true
        else { continue }
        var nodes: [[String: Any]] = []
        var truncated = false
        func visit(_ element: AXUIElement, depth: Int) {
            var elementOwner: pid_t = 0
            guard AXUIElementGetPid(element, &elementOwner) == .success, elementOwner == pid else { return }
            guard depth < 20, nodes.count < 128 else { truncated = true; return }
            nodes.append(record(element))
            for child in children(element) { visit(child, depth: depth + 1) }
        }
        visit(candidate, depth: 0)
        modalContents.append(["elements": nodes, "truncated": truncated])
    }
    result["modalContents"] = modalContents
    if let windowValue {
        result["windowsCFTypeID"] = CFGetTypeID(windowValue)
        result["windowsRaw"] = String(describing: windowValue)
    }
    emit(result)
    exit(0)
}
guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
    fail("Owned app PID unavailable")
}
func ownedWindow(_ element: AXUIElement) -> Bool {
    var owner: pid_t = 0
    return AXUIElementGetPid(element, &owner) == .success && owner == pid
        && string(element, kAXRoleAttribute) == kAXWindowRole && !CFEqual(element, ax)
}
// One content window is the shared invariant. Attached alerts may be separate AX windows.
let mainWindows = windows.filter {
    ownedWindow($0) && string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
        && (attr($0, kAXModalAttribute) as? Bool) != true
}
func cgID(_ element: AXUIElement, modalEvidence: Bool = false) -> UInt32 {
    guard ownedWindow(element) else { fail("Expected actual AXWindow with exact owned PID") }
    if modalEvidence {
        guard (attr(element, kAXModalAttribute) as? Bool) == true,
            string(element, kAXSubroleAttribute) == kAXDialogSubrole
        else { fail("Expected owned modal AXDialog for evidence") }
    }
    func bounds() -> CGRect {
        guard ownedWindow(element), let rawPosition = attr(element, kAXPositionAttribute),
            let rawSize = attr(element, kAXSizeAttribute),
            CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { fail("AX window bounds unavailable") }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
            AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
        else { fail("AX window bounds invalid") }
        return CGRect(origin: position, size: size)
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    repeat {
        requireConsole()
        let before = bounds()
        guard
            let inventory = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { fail("CG window inventory unavailable") }
        let matches = inventory.filter { entry in
            guard (entry[kCGWindowOwnerPID as String] as? Int32) == pid,
                (entry[kCGWindowIsOnscreen as String] as? Bool) == true,
                modalEvidence || (entry[kCGWindowLayer as String] as? Int) == 0,
                let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: rawBounds)
            else { return false }
            return abs(rect.minX - before.minX) < 2 && abs(rect.minY - before.minY) < 2
                && abs(rect.width - before.width) < 2 && abs(rect.height - before.height) < 2
        }
        guard matches.count <= 1 else { fail("Ambiguous owned AX/CG window correspondence") }
        if let match = matches.first, bounds() == before {
            guard let id = match[kCGWindowNumber as String] as? UInt32 else { fail("Owned CG window ID invalid") }
            return id
        }
        if ProcessInfo.processInfo.systemUptime >= deadline { break }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    } while ProcessInfo.processInfo.systemUptime < deadline
    fail("Exact owned AX/CG window correspondence unavailable")
}
guard mainWindows.count <= 1 else { fail("Ambiguous owned standard AX windows") }
guard mainWindows.count == 1 else { fail("Expected one owned standard AX/CG window") }
let window = mainWindows[0]
let windowID = cgID(window)
if args.count > 3, command != "snapshot", let expected = UInt32(args[3]), expected != windowID {
    fail("Owned window ID changed")
}
func inputAdmission(_ expectedTitle: String) -> [String: Any] {
    var result: [String: Any] = [
        "ready": false, "windowID": windowID,
        "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
    ]
    var focused: CFTypeRef?
    let focusedError = AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focused)
    result["focusedError"] = focusedError.rawValue
    guard focusedError == .success, let focused else { return result }
    result["focusedCFTypeID"] = CFGetTypeID(focused)
    guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return result }
    let target = focused as! AXUIElement
    var owner: pid_t = 0
    let ownerError = AXUIElementGetPid(target, &owner)
    result["pid"] = owner
    result["pidError"] = ownerError.rawValue
    guard ownerError == .success, owner == pid else { return result }
    let isTerminal = terminal(target)
    let description = string(target, kAXDescriptionAttribute)
    result["terminal"] = isTerminal
    result["description"] = description
    let prefix = "Terminal output, "
    let observedTitle = String(description.dropFirst(prefix.count))
    let canonicalTitle = URL(fileURLWithPath: observedTitle).resolvingSymlinksInPath().path
    result["canonicalTitle"] = canonicalTitle
    result["expectedTitle"] = expectedTitle
    let identityMatches = description.hasPrefix(prefix + "/") && expectedTitle.hasPrefix("/")
        && canonicalTitle == URL(fileURLWithPath: expectedTitle).resolvingSymlinksInPath().path
    var targetWindow: CFTypeRef?
    let windowError = AXUIElementCopyAttributeValue(target, kAXWindowAttribute as CFString, &targetWindow)
    var relationship: [String: Any] = ["error": windowError.rawValue, "equalsOwnedWindow": false]
    if let targetWindow {
        relationship["cfTypeID"] = CFGetTypeID(targetWindow)
        if CFGetTypeID(targetWindow) == AXUIElementGetTypeID() {
            let related = targetWindow as! AXUIElement
            var relatedOwner: pid_t = 0
            let relatedError = AXUIElementGetPid(related, &relatedOwner)
            relationship["pid"] = relatedOwner
            relationship["pidError"] = relatedError.rawValue
            if relatedError == .success, relatedOwner == pid {
                relationship["equalsOwnedWindow"] = CFEqual(related, window)
                relationship["equalsApplicationRoot"] = CFEqual(related, ax)
                relationship["role"] = string(related, kAXRoleAttribute)
                relationship["subrole"] = string(related, kAXSubroleAttribute)
            }
        }
    }
    result["targetWindow"] = relationship
    result["ready"] = result["frontmost"] as? Bool == true && isTerminal
        && identityMatches
        && windowError == .success && relationship["equalsOwnedWindow"] as? Bool == true
    return result
}
let elements = windows.flatMap { tree($0) }
if command == "dump" {
    emit(elements.map { element in
        ["role": string(element, kAXRoleAttribute), "title": string(element, kAXTitleAttribute), "value": string(element, kAXValueAttribute), "description": string(element, kAXDescriptionAttribute)]
    })
    exit(0)
}
if command == "key" {
    guard args.count == 5, let code = UInt16(args[4]), [UInt16(36), UInt16(53), UInt16(125)].contains(code), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { fail("Owned keyboard target unavailable") }
    requireConsole()
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("Cannot create keyboard event") }
        event.postToPid(pid)
    }
    emit(["keyCode":code])
    exit(0)
}
if command == "press" {
    guard args.count == 5 else { fail("press requires exact title") }
    let matches = elements.filter { string($0, kAXRoleAttribute) == kAXButtonRole && (string($0, kAXTitleAttribute) == args[4] || string($0, kAXDescriptionAttribute) == args[4]) }
    guard matches.count == 1, let target = matches.first, (attr(target, kAXEnabledAttribute) as? Bool) == true else { fail("Exact enabled button unavailable") }
    requireConsole()
    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { fail("Button press failed") }
    emit(["pressed":args[4]])
    exit(0)
}
if command == "snapshot" {
    let focused = attr(ax, kAXFocusedUIElementAttribute)
    let focusedElement = focused.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    let focusedWindow = attr(ax, kAXFocusedWindowAttribute)
    let ownedFocusedWindow =
        focusedWindow.map {
            CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, window)
        } ?? false
    func buttonRecords(_ nodes: [AXUIElement]) -> [[String: String]] {
        nodes.filter { string($0, kAXRoleAttribute) == kAXButtonRole }.map {
            ["title": string($0, kAXTitleAttribute), "description": string($0, kAXDescriptionAttribute)]
        }
    }
    let modals = windows.filter { (attr($0, kAXModalAttribute) as? Bool) == true }
    let modalElements = modals.flatMap { tree($0) }
    let terminalLabels = elements.filter(terminal).map { string($0, kAXDescriptionAttribute) }
    let result: [String: Any] = [
        "pid": pid, "windowID": windowID,
        "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
        "ownedWindowFocused": ownedFocusedWindow,
        "focusedTerminal": focusedElement.map(terminal) ?? false,
        "focusedDescription": focusedElement.map { string($0, kAXDescriptionAttribute) } ?? "",
        "focusedValue": focusedElement.map { string($0, kAXValueAttribute) } ?? "",
        "terminals": terminalLabels,
        "modalCount": modals.count,
        "modalButtons": buttonRecords(modalElements),
        "buttons": buttonRecords(elements),
    ]
    emit(result)
} else if command == "activate" {
    requireConsole()
    var result: [String: Any] = [
        "pid": pid, "windowID": windowID, "activationPolicy": app.activationPolicy.rawValue,
        "finishedLaunching": app.isFinishedLaunching, "terminated": app.isTerminated,
        "frontmostBefore": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
    ]
    let requested = app.activate(options: [])
    result["activationRequested"] = requested
    emit(result)
} else if command == "menu" {
    guard args.count == 6, let bar = attr(ax, kAXMenuBarAttribute) else { fail("menu requires window ID, menu and item") }
    let menuBar = bar as! AXUIElement
    let menus = children(menuBar).filter { (string($0, kAXTitleAttribute) == args[4] || string($0, kAXDescriptionAttribute) == args[4]) }
    guard menus.count == 1 else { fail("Exact menu unavailable") }
    requireConsole()
    guard AXUIElementPerformAction(menus[0], kAXPressAction as CFString) == .success else { fail("Cannot open exact menu") }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var target: AXUIElement?
    var inventory: [[String: Any]] = []
    repeat {
        let items = tree(menus[0]).filter { string($0, kAXRoleAttribute) == kAXMenuItemRole }
        inventory = items.map { ["title": string($0, kAXTitleAttribute), "enabled": (attr($0, kAXEnabledAttribute) as? Bool) == true] }
        let matches = items.filter { string($0, kAXTitleAttribute) == args[5] }
        guard matches.count <= 1 else { fail("Ambiguous exact menu item") }
        if let item = matches.first, (attr(item, kAXEnabledAttribute) as? Bool) == true {
            target = item
            break
        }
        if ProcessInfo.processInfo.systemUptime >= deadline { break }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    } while ProcessInfo.processInfo.systemUptime < deadline
    guard let target else {
        let data = try? JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys])
        fail("Exact enabled menu item unavailable: " + String(decoding: data ?? Data(), as: UTF8.self))
    }
    requireConsole()
    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { fail("Menu press failed") }
    emit(["pressed": args[5]])
} else if command == "cancel" {
    let buttons = elements.filter {
        string($0, kAXRoleAttribute) == kAXButtonRole && string($0, kAXTitleAttribute) == "Cancel"
    }
    guard buttons.count == 1 else {
        fail("Exact Cancel button unavailable")
    }
    requireConsole()
    guard AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success else { fail("Cancel press failed") }
    emit(["cancelled": true])
} else if command == "input-ready" {
    guard args.count == 5 else { fail("input-ready requires window ID and terminal title") }
    emit(inputAdmission(args[4]))
} else if command == "type" {
    guard args.count == 6 else { fail("type requires window ID, terminal title and text") }
    let admission = inputAdmission(args[4])
    guard admission["ready"] as? Bool == true else {
        let data = try? JSONSerialization.data(withJSONObject: admission, options: [.sortedKeys])
        fail("Exact owned focused terminal identity mismatch: " + String(decoding: data ?? Data(), as: UTF8.self))
    }
    // postToPid avoids arbitrary global keystrokes. No clipboard or paste pathway.
    for unit in args[5].utf16 {
        var character = unit
        let key: CGKeyCode = unit == 13 ? 36 : 0
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        else { fail("Cannot create keyboard event") }
        if unit != 13 {
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
        }
        requireConsole()
        down.postToPid(pid)
        up.postToPid(pid)
    }
    emit(["typed": true])
} else if command == "screenshot" {
    guard args.count == 5 else { fail("screenshot requires window ID and output PNG") }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    let modalWindows = windows.filter { (attr($0, kAXModalAttribute) as? Bool) == true }
    guard modalWindows.count <= 1 else { fail("Multiple owned modal windows") }
    let captureID = modalWindows.first.map { cgID($0, modalEvidence: true) } ?? windowID
    task.arguments = ["-x", "-l", String(captureID), args[4]]
    do { try task.run(); task.waitUntilExit() } catch { fail("screencapture launch failed: \(error)") }
    guard task.terminationStatus == 0,
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[4]) as CFURL, nil),
        CGImageSourceGetType(source) as String? == "public.png",
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 100, image.height > 100
    else {
        fail("Window capture did not produce a decodable PNG")
    }
    emit(["windowID": captureID, "mainWindowID": windowID, "width": image.width, "height": image.height, "path": args[4]])
} else {
    fail("Unknown helper command")
}
