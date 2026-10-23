import ApplicationServices
import Darwin
import Foundation

/// AX transport runs outside the SwiftUI host to avoid self-AX deadlocks.
@main
struct SettingsInteractionAXClient {
    static func main() {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        print("Settings AX helper trusted=\(AXIsProcessTrusted()) target=\(pid)")
        let deadline = Date().addingTimeInterval(45)
        var last = -1
        while kill(pid, 0) == 0 && Date() < deadline {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("command.json")),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sequence = command["sequence"] as? Int, sequence != last,
                  let action = command["action"] as? String, let id = command["identifier"] as? String else {
                usleep(25_000); continue
            }
            last = sequence
            var response: [String: Any] = ["sequence": sequence, "ok": false]
            if action == "cancel", let button = find(in: app, matching: {
                read($0, kAXRoleAttribute as String) as? String == kAXButtonRole as String &&
                    ["Cancel", "取消"].contains(text($0))
            }) {
                let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                response["ok"] = result == .success || result == .failure
                response["cancelAction"] = result.rawValue
            } else if let element = find(in: app, matching: { read($0, kAXIdentifierAttribute as String) as? String == id }) {
                if action == "read" {
                    response["ok"] = true
                    response["text"] = text(element)
                } else if action == "press" {
                    let pressable = find(in: element, matching: { actions($0).contains(kAXPressAction as String) }) ?? element
                    let result = AXUIElementPerformAction(pressable, kAXPressAction as CFString)
                    response["ok"] = result == .success || result == .failure
                    response["pressAction"] = result.rawValue
                } else if action == "select", let title = command["title"] as? String {
                    let pressable = find(in: element, matching: { actions($0).contains(kAXPressAction as String) }) ?? element
                    let status = AXUIElementPerformAction(pressable, kAXPressAction as CFString)
                    if status == .success || status == .failure {
                        var selected = false
                        for _ in 0..<40 {
                            if let item = find(in: app, matching: {
                                read($0, kAXRoleAttribute as String) as? String == kAXMenuItemRole as String && text($0) == title
                            }) {
                                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                                response["ok"] = result == .success || result == .failure
                                response["menuAction"] = result.rawValue
                                selected = true
                                break
                            }
                            usleep(25_000)
                        }
                        if !selected { response["message"] = "No rendered menu item named \(title)" }
                    } else { response["message"] = "Cannot open rendered picker: \(status.rawValue)" }
                } else { response["message"] = "Unsupported Settings action \(action)" }
            } else { response["message"] = "No rendered Settings element \(id)" }
            do {
                try JSONSerialization.data(withJSONObject: response).write(to: root.appendingPathComponent("ack.json"), options: .atomic)
            } catch { print("FAIL: Cannot acknowledge Settings AX: \(error)"); exit(2) }
            print("Settings AX \(sequence) \(action):\(id): \(response)")
        }
        exit(kill(pid, 0) == 0 ? 3 : 0)
    }
    private static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private static func text(_ element: AXUIElement) -> String {
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let value = read(element, attribute as String) as? String, !value.isEmpty { return value }
        }
        return ""
    }
    private static func actions(_ element: AXUIElement) -> [String] {
        var result: CFArray?
        _ = AXUIElementCopyActionNames(element, &result)
        return result as? [String] ?? []
    }
    private static func find(in root: AXUIElement, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root], seen: [AXUIElement] = []
        while !queue.isEmpty && seen.count < 2000 {
            let element = queue.removeFirst()
            if seen.contains(where: { CFEqual($0, element) }) { continue }
            seen.append(element)
            if predicate(element) { return element }
            queue.append(contentsOf: read(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? [])
            if element === root { queue.append(contentsOf: read(element, kAXWindowsAttribute as String) as? [AXUIElement] ?? []) }
        }
        return nil
    }
}
