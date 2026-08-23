import Foundation

/// The JSON payload the snapshot walker script returns. Kept as a thin Codable
/// mirror of the JS so outline building — the part with actual logic — is plain
/// Swift and headlessly testable.
struct BrowserWalkerPayload: Codable, Equatable, Sendable {
    struct Node: Codable, Equatable, Sendable {
        var d: Int
        var role: String
        var name: String
        var value: String
        /// Index into the page-side `window.__orchardRefs.els`; -1 = not interactive.
        var i: Int
    }

    var title: String
    var url: String
    var truncated: Bool
    var nodes: [Node]
}

/// Turns a walker payload into the agent-facing text outline plus the `@eN` ref
/// table. Refs are numbered in document order; duplicate role+name pairs get an
/// ordinal suffix ("(2nd)") so the outline alone disambiguates them — same
/// convention as Orca's snapshot engine (src/main/browser/snapshot-engine.ts).
enum BrowserSnapshotOutline {
    static func build(payload: BrowserWalkerPayload, epoch: Int) -> BrowserPageSnapshot {
        var refs: [String: BrowserSnapshotRef] = [:]
        var lines: [String] = []
        var counter = 0

        var nameCounts: [String: Int] = [:]
        for node in payload.nodes where node.i >= 0 {
            nameCounts["\(node.role):\(node.name)", default: 0] += 1
        }
        var nameOccurrence: [String: Int] = [:]

        for node in payload.nodes {
            let indent = String(repeating: "  ", count: max(0, node.d))
            if node.role == "text" {
                lines.append("\(indent)\(node.name)")
                continue
            }
            var line = "\(indent)- \(node.role)"
            if !node.name.isEmpty {
                var display = node.name
                if node.i >= 0 {
                    let key = "\(node.role):\(node.name)"
                    let nth = (nameOccurrence[key] ?? 0) + 1
                    nameOccurrence[key] = nth
                    if (nameCounts[key] ?? 1) > 1 && nth > 1 {
                        display += " (\(ordinal(nth)))"
                    }
                }
                line += " \"\(display)\""
            }
            if !node.value.isEmpty {
                line += " (value: \(node.value))"
            }
            if node.i >= 0 {
                counter += 1
                let ref = "@e\(counter)"
                refs[ref] = BrowserSnapshotRef(ref: ref, index: node.i,
                                               role: node.role, name: node.name)
                line += " [\(ref)]"
            }
            lines.append(line)
        }

        var header = "Page: \(payload.title.isEmpty ? "(untitled)" : payload.title)\nURL: \(payload.url)\n"
        if payload.truncated {
            header += "(outline truncated at node budget)\n"
        }
        return BrowserPageSnapshot(epoch: epoch,
                                   outline: header + lines.joined(separator: "\n"),
                                   refs: refs)
    }

    private static func ordinal(_ n: Int) -> String {
        switch n % 10 {
        case 1 where n % 100 != 11: return "\(n)st"
        case 2 where n % 100 != 12: return "\(n)nd"
        case 3 where n % 100 != 13: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}
