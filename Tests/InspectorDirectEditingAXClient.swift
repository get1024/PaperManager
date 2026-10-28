import ApplicationServices
import Darwin
import Foundation

/// A separate process is required: synchronous AX transport to the host from
/// inside that same host can deadlock despite using a background Swift task.
@main
struct InspectorDirectEditingAXClient {
    static func main() {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        print("Direct AX helper trusted=\(AXIsProcessTrusted()) target=\(pid)")
        var lastSequence = -1
        let deadline = Date().addingTimeInterval(35)
        while kill(pid, 0) == 0 && Date() < deadline {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("command.json")),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sequence = command["sequence"] as? Int, sequence != lastSequence,
                  let identifier = command["identifier"] as? String else { usleep(25_000); continue }
            lastSequence = sequence
            let message = activate(identifier, in: app)
            let ack: [String: Any] = ["sequence": sequence, "ok": message == nil, "message": message ?? ""]
            do {
                try JSONSerialization.data(withJSONObject: ack).write(to: root.appendingPathComponent("ack.json"), options: .atomic)
            } catch { print("FAIL: Direct AX helper cannot acknowledge: \(error)"); exit(2) }
            print("Direct AX helper sequence=\(sequence) field=\(identifier) result=\(message ?? "pressed")")
        }
        exit(kill(pid, 0) == 0 ? 3 : 0)
    }

    private static func activate(_ identifier: String, in app: AXUIElement) -> String? {
        func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return status == .success ? value : nil
        }
        // A key SwiftUI window may precede its externally published AX tree.
        // Wait by reading only; once an action is dispatched it is never replayed.
        let deadline = Date().addingTimeInterval(2)
        var scanned = 0
        var windows = 0
        var attempts = 0
        repeat {
            var queue = read(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
            windows = queue.count
            var seen: [AXUIElement] = []
            attempts += 1
            while !queue.isEmpty && seen.count < 2000 {
                let element = queue.removeFirst()
                if seen.contains(where: { CFEqual($0, element) }) { continue }
                seen.append(element)
                if read(element, kAXIdentifierAttribute as String) as? String == identifier {
                    var names: CFArray?
                    _ = AXUIElementCopyActionNames(element, &names)
                    if (names as? [String])?.contains(kAXPressAction as String) == true {
                        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
                        // Host verifies the actual native editor, never retries a
                        // delivered SwiftUI action simply because it returned -25200.
                        return status == .success || status == .failure ? nil : "AX press error \(status.rawValue)"
                    }
                }
                queue.append(contentsOf: read(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? [])
            }
            scanned = seen.count
            if Date() < deadline { usleep(50_000) }
        } while Date() < deadline
        return "No direct activation action for \(identifier), scanned \(scanned) nodes in \(windows) windows after \(attempts) read-only readiness checks"
    }
}
