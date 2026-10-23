import AppKit
import ApplicationServices
import Darwin
import Foundation

@main
struct InspectorTypeMatrixAXClient {
    private struct Node {
        let element: AXUIElement
        let role: String
        let id: String
        let value: String
        let label: String
        let field: String?
        let writable: Bool
    }
    private static let types = ["article", "book", "inBook", "inCollection", "inProceedings", "proceedings", "thesis", "preprint", "report", "patent", "dataset", "software", "online", "manuscript", "misc"]
    // Independent contract: these field identifiers must remain reachable in a
    // populated paper, including fields outside its default type schema.
    private static let fields = Set(["subtitle", "editors", "translators", "address", "organization", "type", "urlDate", "journal", "bookTitle", "publisher", "institution", "school", "series", "volume", "issue", "pages", "month", "doi", "isbn", "url", "language", "event", "eventDate", "venue", "edition", "chapter", "eprint", "eprintType", "eprintClass", "pubState", "howpublished"])
    static func main() {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
            if error == .cannotComplete { print("FAIL: AX timed out at \(attribute)"); exit(4) }
            return error == .success ? result : nil
        }
        func scan() -> [Node] {
            let windows = (read(app, "AXWindows") as? [AXUIElement]) ?? []
            var queue: [(AXUIElement, String?)] = windows.map { ($0, nil) }
            var seen: [AXUIElement] = []
            var nodes: [Node] = []
            while !queue.isEmpty && seen.count < 3000 {
                let (element, inheritedField) = queue.removeFirst()
                if seen.contains(where: { CFEqual($0, element) }) { continue }
                seen.append(element)
                let role = read(element, "AXRole") as? String ?? ""
                let id = read(element, "AXIdentifier") as? String ?? ""
                let value = read(element, "AXValue") as? String ?? ""
                let field = id.hasPrefix("paper-field-") ? String(id.dropFirst("paper-field-".count)) : inheritedField
                var writable = DarwinBoolean(false)
                if ["AXTextField", "AXTextArea"].contains(role) { _ = AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &writable) }
                let label = role == "AXButton" || role == "AXLink" ?
                    ([read(element, "AXTitle") as? String, read(element, "AXDescription") as? String].compactMap { $0 }.joined(separator: " ")) : ""
                nodes.append(Node(element: element, role: role, id: id, value: value, label: label, field: field, writable: writable.boolValue))
                if let children = read(element, "AXChildren") as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, field) }) }
                if let sheets = read(element, "AXSheets") as? [AXUIElement] { queue.append(contentsOf: sheets.map { ($0, field) }) }
            }
            return nodes
        }
        func command(_ command: String) {
            try! Data(command.utf8).write(to: root.appendingPathComponent("command"), options: .atomic)
            for _ in 0..<100 {
                if (try? String(contentsOf: root.appendingPathComponent("ack"))) == command { usleep(120_000); return }
                usleep(30_000)
            }
            print("FAIL: Fixture did not acknowledge \(command)"); exit(5)
        }
        func press(_ node: Node?, _ purpose: String) {
            guard let node else { print("FAIL: Missing \(purpose)"); exit(6) }
            let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
            guard result == .success || result == .failure else { print("FAIL: Could not press \(purpose): \(result.rawValue)"); exit(7) }
            usleep(300_000)
        }
        var reports: [[String: Any]] = []
        for (index, type) in types.enumerated() {
            command("select:\(index):\(index)")
            var nodes = scan()
            // Direct editing is entered from idle text, before touching the
            // bulk pencil. Keep the full type/advanced matrix after this check.
            for field in ["title", "authors"] {
                let activation = nodes.first { node in
                    guard node.id == "paper-field-\(field)" else { return false }
                    var actions: CFArray?
                    _ = AXUIElementCopyActionNames(node.element, &actions)
                    return (actions as? [String])?.contains(kAXPressAction as String) == true
                }
                press(activation, "direct \(field) activation \(type)")
                nodes = scan()
                guard nodes.contains(where: { $0.field == field && $0.writable }) else {
                    print("FAIL: \(type) direct \(field) did not enter native editing before the pencil"); exit(12)
                }
            }
            press(nodes.first { $0.id == "paper-edit-metadata" && $0.role == "AXButton" }, "metadata edit \(type)")
            nodes = scan()
            var reachable = Set(nodes.compactMap { $0.writable ? $0.field : nil })
            press(nodes.first { $0.id == "paper-open-advanced-fields" }, "advanced \(type)")
            nodes = scan()
            reachable.formUnion(nodes.compactMap { $0.writable ? $0.field : nil })
            let missing = fields.subtracting(reachable)
            guard missing.isEmpty else { print("FAIL: \(type) editable fields missing: \(missing.sorted())"); exit(8) }
            guard nodes.contains(where: { $0.value == "MATRIX-CUSTOM-VALUE" && $0.writable }) else { print("FAIL: \(type) custom field not editable"); exit(9) }
            press(nodes.first { ($0.role == "AXButton") && ($0.label == "完成" || $0.label == "Done" || $0.label.hasPrefix("完成 ")) }, "advanced Done \(type)")
            nodes = scan()
            let annotationTab = nodes.first {
                $0.role == "AXButton" && ($0.label == "标注" || $0.label == "Annotations" || $0.label.hasPrefix("标注 "))
            }
            if annotationTab == nil {
                for node in nodes where node.id.contains("tab") || !node.label.isEmpty {
                    print("MATRIX NAV role=\(node.role) id=\(node.id) label=\(node.label) value=\(node.value)")
                }
            }
            press(annotationTab, "annotations \(type)")
            command("scroll:\(index)")
            nodes = scan()
            // Lazy annotation content must expose records beyond the old 80 cap.
            guard nodes.contains(where: { $0.value.contains("MATRIX-ANNOTATION-84") }) else { print("FAIL: \(type) annotation85 was not reachable after scrolling"); exit(10) }
            reports.append(["type": type, "directTitleAndAuthors": true, "editableFields": reachable.count,
                            "advancedNodes": nodes.count, "annotation85": true])
            print("PASS: \(type) direct title/authors, all31 bulk fields/custom editable, annotation85 reachable")
        }
        command("finish:all")
        guard (try? String(contentsOf: root.appendingPathComponent("persistence"))) == "unchanged" else { print("FAIL: Merely cycling inspector states changed fixture data"); exit(11) }
        if let report = ProcessInfo.processInfo.environment["PAPERMANAGER_MATRIX_REPORT"] {
            try? JSONSerialization.data(withJSONObject: ["ok": true, "types": reports], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report))
        }
        print("Inspector type matrix: 15 types passed, direct title/authors and all31 bulk fields/custom/85annotations reachable")
    }
}
