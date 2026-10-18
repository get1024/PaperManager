import AppKit
import ApplicationServices
import Darwin
import Foundation

@main
struct InspectorAXClient {
    static func main() {
        setbuf(stdout, nil)
        let verbose = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_VERBOSE"] == "1"
        guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
        print("AX CLIENT trusted=\(AXIsProcessTrusted()) target=\(pid)")
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        var value: CFTypeRef?
        var windows: [AXUIElement] = []
        for _ in 0..<40 {
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            if error == .success, let found = value as? [AXUIElement], !found.isEmpty { windows = found; break }
            if kill(pid, 0) != 0 { print("AX CLIENT host exited"); exit(3) }
            usleep(100_000)
        }
        guard !windows.isEmpty else { print("AX CLIENT could not read fixture windows"); exit(4) }
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        // Activate AX before selection, then read the rebuilt inspector three
        // times so cached nodes and subsequent hierarchy requests are covered.
        let phases = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_PHASE_FILE"] == nil ? 1 : 4
        for phase in 0..<phases {
          if phase == 1, let path = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_PHASE_FILE"] {
            try! Data("select".utf8).write(to: URL(fileURLWithPath: path))
            usleep(500_000)
          }
          var queue = windows
          var seen: [AXUIElement] = []
          var reads = 0
          var foundCitekey = false
          while !queue.isEmpty && seen.count < 4_000 {
            let element = queue.removeFirst()
            guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
            seen.append(element)
            var role: CFTypeRef?, identifier: CFTypeRef?, nodeValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &role)
            _ = AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &identifier)
            if verbose { print("AX NODE phase=\(phase) index=\(seen.count) role=\(role as? String ?? "") id=\(identifier as? String ?? "")") }
            _ = AXUIElementCopyAttributeValue(element, "AXValue" as CFString, &nodeValue)
            if nodeValue as? String == "vaswani2017" {
                foundCitekey = true
                print("AX CLIENT found selectable citekey role=\(role as? String ?? "")")
            }
            var attributeNames: CFArray?
            _ = AXUIElementCopyAttributeNames(element, &attributeNames)
            let names = (attributeNames as? [String]) ?? ["AXRole", "AXRoleDescription", "AXIdentifier", "AXTitle", "AXDescription", "AXValue", "AXHelp"]
            for name in names {
                if verbose { print("AX CLIENT node=\(seen.count) read=\(name)") }
                value = nil
                let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                if result == .cannotComplete || result == .invalidUIElement {
                    print("AX CLIENT ERROR \(result.rawValue) at phase=\(phase) node=\(seen.count) role=\(role as? String ?? "") attribute=\(name)"); exit(5)
                }
                reads += 1
            }
            for name in ["AXChildren", "AXVisibleChildren", "AXContents", "AXChildrenInNavigationOrder"] {
                value = nil
                if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                   let children = value as? [AXUIElement] { queue.append(contentsOf: children) }
            }
          }
          guard seen.count > 10 else { print("AX CLIENT failed to enter the actual inspector hierarchy"); exit(6) }
          if phase >= 1 && !foundCitekey { print("AX CLIENT failed to enter the selected paper inspector"); exit(7) }
          print("AX CLIENT PASS phase=\(phase) nodes=\(seen.count) reads=\(reads)")
        }
    }
}
