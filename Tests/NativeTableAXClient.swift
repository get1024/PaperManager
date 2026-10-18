import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Public cross-process AX calls, including writability checks used by UI
/// inspection clients. No node, row or offscreen cell is omitted.
@main
struct NativeTableAXClient {
    struct Entry { let element: AXUIElement; var row: Int?; var column: Int? }
    struct Cell: Hashable { let row: Int; let column: Int }

    static func main() throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
        let expected = Int(ProcessInfo.processInfo.environment["PAPERMANAGER_AX_ROWS"] ?? "72") ?? 72
        print("AX PERF CLIENT trusted=\(AXIsProcessTrusted()) target=\(pid) expectedRows=\(expected)")
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 10)
        var windows: [AXUIElement] = []
        for _ in 0..<50 {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value) == .success,
               let found = value as? [AXUIElement], !found.isEmpty { windows = found; break }
            if kill(pid, 0) != 0 { print("AX PERF host exited before discovery"); exit(3) }
            usleep(100_000)
        }
        guard !windows.isEmpty else { print("AX PERF could not read fixture windows"); exit(4) }
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var queue = windows.map { Entry(element: $0) }, cursor = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]
        var nodes = 0, readCount = 0, settableCount = 0, tableRows = 0, tableColumns = 0
        var roleCounts: [String: Int] = [:], values: [Cell: Set<String>] = [:], rowCellCounts: [Int: Int] = [:]
        var readSeconds: [String: Double] = [:], settableSeconds: [String: Double] = [:]
        let start = CFAbsoluteTimeGetCurrent()

        func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let began = CFAbsoluteTimeGetCurrent()
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            readSeconds[name, default: 0] += CFAbsoluteTimeGetCurrent() - began
            readCount += 1
            if error == .cannotComplete || error == .invalidUIElement {
                print("AX PERF read failure=\(error.rawValue) attr=\(name) nodes=\(nodes) elapsed=\(CFAbsoluteTimeGetCurrent() - start)")
                exit(5)
            }
            return error == .success ? value : nil
        }
        func record(_ value: CFTypeRef?, entry: Entry) {
            guard let row = entry.row, let column = entry.column, let value else { return }
            let string: String?
            if let text = value as? String { string = text }
            else if let number = value as? NSNumber { string = number.stringValue }
            else { string = nil }
            if let string, !string.isEmpty { values[Cell(row: row, column: column), default: []].insert(string) }
        }

        while cursor < queue.count && nodes < 10_000 {
            let entry = queue[cursor]; cursor += 1
            let hash = CFHash(entry.element)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, entry.element) }) else { continue }
            seen[hash, default: []].append(entry.element); nodes += 1
            let role = read(entry.element, "AXRole") as? String ?? ""
            roleCounts[role, default: 0] += 1
            let identifier = read(entry.element, "AXIdentifier") as? String ?? ""
            record(read(entry.element, "AXValue"), entry: entry)
            var attributeNames: CFArray?
            _ = AXUIElementCopyAttributeNames(entry.element, &attributeNames)
            let names = attributeNames as? [String] ?? []
            for name in names {
                var settable: DarwinBoolean = false
                let began = CFAbsoluteTimeGetCurrent()
                let error = AXUIElementIsAttributeSettable(entry.element, name as CFString, &settable)
                settableSeconds[name, default: 0] += CFAbsoluteTimeGetCurrent() - began
                settableCount += 1
                if error == .cannotComplete || error == .invalidUIElement {
                    print("AX PERF settable failure=\(error.rawValue) attr=\(name) role=\(role) nodes=\(nodes) elapsed=\(CFAbsoluteTimeGetCurrent() - start)")
                    exit(5)
                }
                let value = read(entry.element, name)
                if name == "AXValue" { record(value, entry: entry) }
            }
            if identifier == "paper-table" {
                let rows = read(entry.element, "AXRows") as? [AXUIElement] ?? []
                let columns = read(entry.element, "AXColumns") as? [AXUIElement] ?? []
                tableRows = rows.count; tableColumns = columns.count
                queue.append(contentsOf: rows.enumerated().map { Entry(element: $0.element, row: $0.offset) })
                queue.append(contentsOf: columns.map { Entry(element: $0) })
                print("AX PERF TABLE rows=\(tableRows) columns=\(tableColumns)")
            }
            let children = read(entry.element, "AXChildren") as? [AXUIElement] ?? []
            if let row = entry.row, entry.column == nil, role == "AXRow" {
                rowCellCounts[row] = children.count
                queue.append(contentsOf: children.enumerated().map { Entry(element: $0.element, row: row, column: $0.offset) })
            } else {
                queue.append(contentsOf: children.map { Entry(element: $0, row: entry.row, column: entry.column) })
            }
            for name in ["AXVisibleChildren", "AXContents", "AXChildrenInNavigationOrder"] {
                if let related = read(entry.element, name) as? [AXUIElement] {
                    queue.append(contentsOf: related.map { Entry(element: $0, row: entry.row, column: entry.column) })
                }
            }
            if nodes % 200 == 0 {
                print(String(format: "AX PERF PROGRESS nodes=%d elapsed=%.3f", nodes, CFAbsoluteTimeGetCurrent() - start))
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        var verified = 0
        for row in 0..<expected {
            guard rowCellCounts[row] == 7 else { continue }
            let titleValues = values[Cell(row: row, column: 0)] ?? []
            guard let title = titleValues.first(where: { $0.hasPrefix("AX Perf Title ") }),
                  let source = Int(title.dropFirst("AX Perf Title ".count)) else { continue }
            let expectedValues = [1: "AX Perf Author \(source); Shared Author", 2: "2026", 3: "AX Perf Source \(source)",
                                  4: String(source % 5 + 1), 6: "AX Perf Note \(source)"]
            guard expectedValues.allSatisfy({ values[Cell(row: row, column: $0.key)]?.contains($0.value) == true }),
                  values[Cell(row: row, column: 5)]?.isEmpty == false else { continue }
            verified += 1
        }
        let result: [String: Any] = ["rows": tableRows, "columns": tableColumns, "verifiedRows": verified,
            "nodes": nodes, "attributeReads": readCount, "settableChecks": settableCount, "seconds": elapsed,
            "roles": roleCounts, "readSeconds": readSeconds, "settableSeconds": settableSeconds]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(format: "AX PERF RESULT rows=%d columns=%d verified=%d nodes=%d reads=%d settable=%d seconds=%.3f", tableRows, tableColumns, verified, nodes, readCount, settableCount, elapsed))
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_RESULT_JSON"] { try data.write(to: URL(fileURLWithPath: path)) }
        if let path = ProcessInfo.processInfo.environment["PAPERMANAGER_AX_PERF_FINISH"] {
            try Data("finished".utf8).write(to: URL(fileURLWithPath: path)); usleep(250_000)
        }
        guard tableRows == expected, tableColumns == 7, verified == expected, roleCounts["AXSlider"] == expected else {
            print("AX PERF FAIL: all rows and all seven column values must remain reachable"); exit(6)
        }
        let budget = Double(ProcessInfo.processInfo.environment["PAPERMANAGER_AX_MAX_SECONDS"] ?? "30") ?? 30
        guard elapsed < budget else { print("AX PERF FAIL scan exceeded \(budget)-second budget"); exit(7) }
        print("AX PERF PASS all \(verified) rows × 7 columns, including offscreen rows")
    }
}
