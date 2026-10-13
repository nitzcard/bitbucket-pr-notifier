import ApplicationServices
import AppKit

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A UI element of the app under test, read and driven through the Accessibility API.
struct Element: CustomStringConvertible {
    let ref: AXUIElement

    static func application(pid: pid_t) -> Element {
        let app = AXUIElementCreateApplication(pid)
        // A status menu holds the app's run loop while it's open; don't wait long on any call.
        AXUIElementSetMessagingTimeout(app, 3)
        return Element(ref: app)
    }

    func attribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? { attribute(name) as? String }

    var role: String { string(kAXRoleAttribute) ?? "" }
    var subrole: String { string(kAXSubroleAttribute) ?? "" }
    var title: String { string(kAXTitleAttribute) ?? "" }
    var value: String { string(kAXValueAttribute) ?? "" }
    var help: String { string(kAXHelpAttribute) ?? "" }
    var isEnabled: Bool { (attribute(kAXEnabledAttribute) as? Bool) ?? true }
    var isSelected: Bool {
        (attribute(kAXValueAttribute) as? Int).map { $0 != 0 } ?? false
    }

    /// Everything the element says about itself, to match against.
    var label: String {
        [title, string(kAXDescriptionAttribute) ?? "", value, help, string(kAXPlaceholderValueAttribute) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " | ")
    }

    var description: String { "\(role)(\(label))" }

    var children: [Element] {
        ((attribute(kAXChildrenAttribute) as? [AXUIElement]) ?? []).map(Element.init)
    }

    var windows: [Element] {
        ((attribute(kAXWindowsAttribute) as? [AXUIElement]) ?? []).map(Element.init)
    }

    /// All elements below this one, breadth first. The tree can loop back on
    /// itself, so each element is visited once, and the walk stops at `limit`.
    func descendants(limit: Int = 4000) -> [Element] {
        var seen: [CFHashCode: [AXUIElement]] = [:]
        func isNew(_ el: AXUIElement) -> Bool {
            let hash = CFHash(el)
            if seen[hash, default: []].contains(where: { CFEqual($0, el) }) { return false }
            seen[hash, default: []].append(el)
            return true
        }
        _ = isNew(ref)
        var found: [Element] = []
        var queue = [self]
        while !queue.isEmpty, found.count < limit {
            let next = queue.removeFirst().children.filter { isNew($0.ref) }
            found += next
            queue += next
        }
        return found
    }

    func all(_ role: String? = nil, matching text: String? = nil) -> [Element] {
        descendants().filter { el in
            (role == nil || el.role == role) && (text.map { el.label.contains($0) } ?? true)
        }
    }

    func first(_ role: String? = nil, matching text: String? = nil) -> Element? {
        all(role, matching: text).first
    }

    /// Whether any element below shows `text`.
    func shows(_ text: String) -> Bool { first(matching: text) != nil }

    func press() throws { try perform(kAXPressAction) }

    func perform(_ action: String) throws {
        let result = AXUIElementPerformAction(ref, action as CFString)
        // A press that opens a menu or modal alert may time out even though it worked.
        guard result == .success || result == .cannotComplete else {
            throw TestFailure("\(action) on \(self) failed (\(result.rawValue))")
        }
    }

    func set(_ name: String, to value: AnyObject) throws {
        let result = AXUIElementSetAttributeValue(ref, name as CFString, value)
        guard result == .success else { throw TestFailure("Setting \(name) on \(self) failed (\(result.rawValue))") }
    }

    /// Replaces the field's text the way typing would, so SwiftUI bindings update.
    func type(_ text: String, pid: pid_t) throws {
        try set(kAXFocusedAttribute, to: true as CFBoolean)
        Thread.sleep(forTimeInterval: 0.2)
        let source = CGEventSource(stateID: .hidSystemState)
        // ⌘A, then the text, then the field holds exactly `text`.
        func key(_ code: CGKeyCode, flags: CGEventFlags = [], unicode: String? = nil) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
                event.flags = flags
                if let unicode {
                    let chars = Array(unicode.utf16)
                    event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                }
                event.postToPid(pid)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        key(0, flags: .maskCommand) // A
        key(51) // Delete
        for ch in text { key(0, unicode: String(ch)) }
        Thread.sleep(forTimeInterval: 0.2)
    }
}

/// Polls until `body` returns a value, or fails with `what` after `timeout` seconds.
@discardableResult
func waitFor<T>(_ what: String, timeout: TimeInterval = 10, _ body: () throws -> T?) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let value = try body() { return value }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    throw TestFailure("Timed out after \(Int(timeout))s waiting for \(what)")
}

func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () throws -> Bool) throws {
    try waitFor(what, timeout: timeout) { try condition() ? true : nil }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw TestFailure(message()) }
}
