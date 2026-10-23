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
        // Activate AX before selection, then exercise idle -> direct title ->
        // direct authors -> bulk edit -> idle, without using a pencil to enter
        // either direct editor.
        let phases = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_PHASE_FILE"] == nil ? 1 : 6
        var editButton: AXUIElement?
        var titleActivation: AXUIElement?
        var authorsActivation: AXUIElement?
        for phase in 0..<phases {
          if phase == 1, let path = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_PHASE_FILE"] {
            try! Data("select".utf8).write(to: URL(fileURLWithPath: path))
            usleep(500_000)
          }
          if phase >= 2 {
            let target = phase == 2 ? titleActivation : (phase == 3 ? authorsActivation : editButton)
            guard let target else {
                print("AX CLIENT missing direct/bulk action at phase=\(phase)"); exit(8)
            }
            var enabled: CFTypeRef?, actionNames: CFArray?
            _ = AXUIElementCopyAttributeValue(target, kAXEnabledAttribute as CFString, &enabled)
            _ = AXUIElementCopyActionNames(target, &actionNames)
            print("AX CLIENT phase=\(phase) target enabled=\(String(describing: enabled)) actions=\(String(describing: actionNames))")
            let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
            // Some SwiftUI hosts return AXFailure after scheduling the button
            // action. Do not press it twice: assert the resulting hierarchy
            // below, so the mode transition itself determines success.
            guard result == .success || result == .failure else {
                print("AX CLIENT could not activate the fixture editor: error=\(result.rawValue)"); exit(8)
            }
            print("AX CLIENT editor action returned=\(result.rawValue); checking resulting hierarchy")
            usleep(300_000)
          }
          var queue = windows
          var seen: [AXUIElement] = []
          var reads = 0
          var foundCitekey = false
          var foundEditableTitle = false
          var foundEditableAuthors = false
          while !queue.isEmpty && seen.count < 4_000 {
            let element = queue.removeFirst()
            guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
            seen.append(element)
            var role: CFTypeRef?, identifier: CFTypeRef?, nodeValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &role)
            _ = AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &identifier)
            if verbose { print("AX NODE phase=\(phase) index=\(seen.count) role=\(role as? String ?? "") id=\(identifier as? String ?? "")") }
            _ = AXUIElementCopyAttributeValue(element, "AXValue" as CFString, &nodeValue)
            if identifier as? String == "paper-edit-metadata", role as? String == "AXButton" { editButton = element }
            if let text = nodeValue as? String, ["AXTextField", "AXTextArea"].contains(role as? String ?? "") {
                var writable = DarwinBoolean(false)
                _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable)
                if writable.boolValue {
                    if text.hasPrefix("Attention Is All You Need") { foundEditableTitle = true }
                    if text.contains("Synthetic Coauthor") { foundEditableAuthors = true }
                }
            }
            if ["paper-field-title", "paper-field-authors"].contains(identifier as? String ?? "") {
                var actions: CFArray?
                _ = AXUIElementCopyActionNames(element, &actions)
                if (actions as? [String])?.contains(kAXPressAction as String) == true {
                    if identifier as? String == "paper-field-title" { titleActivation = element }
                    else { authorsActivation = element }
                }
            }
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
          if phase >= 1 {
            guard editButton != nil else { print("AX CLIENT missing the inspector edit action"); exit(8) }
            let expectedTitle = phase == 2 || phase == 4
            let expectedAuthors = phase == 3 || phase == 4
            if expectedTitle != foundEditableTitle || expectedAuthors != foundEditableAuthors {
                print("AX CLIENT direct/bulk editability mismatch at phase=\(phase) nodes=\(seen.count) title=\(foundEditableTitle) authors=\(foundEditableAuthors)"); exit(9)
            }
          }
          print("AX CLIENT PASS phase=\(phase) nodes=\(seen.count) reads=\(reads) editableTitle=\(foundEditableTitle) editableAuthors=\(foundEditableAuthors)")
        }
    }
}
