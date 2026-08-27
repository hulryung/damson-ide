import Foundation

/// The generation label a remote pane's *own* connection carries, and the surgery that
/// replaces it when the pane opens a new one (T89).
///
/// A remote pane is a connection, and every relaunch of it — a respawn, a reconnect —
/// is a different connection to the same place. `incarnation` already counted them, but
/// only here: the far side had no idea, so a question asked about "this pane's remote
/// process" could be answered from a process a later connection started, which is a
/// reconnect being reported as continuity.
///
/// The label fixes that by existing on both sides. The pane's launch writes it into the
/// identity record on the host, and a liveness question carries it; when the two differ,
/// the answer is refused rather than served from the newer one. It shares its shape with
/// `RemoteConnectionGeneration` (`host#sequence.epoch`) because it is the same idea —
/// one continuous span of contact, named so a second span cannot pass for it.
///
/// `epoch` is a fresh nonce on every launch, not a derivative of the sequence: a pane
/// restored into a new app instance keeps its incarnation numbering, and two spans that
/// only differ by a counter somebody could recompute would be forgeable by accident.
public enum RemotePaneGeneration {
    /// The shell variable the prelude assigns the label to. Chosen to be
    /// unmistakable — the rewrite below only ever touches assignments to this exact
    /// name, the same discipline `KeeperRemoteRestoration` applies to a `-R` it wrote
    /// itself.
    public static let marker = "__opg="

    public static func mint(executionHostId: String, incarnation: Int) -> String {
        let host = KeeperRemoteRestoration.hostLabel(executionHostId)
        let epoch = String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(8))
        return "\(host)#\(max(1, incarnation)).\(epoch)"
    }

    /// A label is host-name characters, `#`, digits, `.`, hex. Nothing in that set is
    /// altered by either layer of shell quoting a remote launch goes through, which is
    /// what makes a plain substring rewrite safe on both an argv element and a
    /// fully-quoted command line.
    public static func isValidLabel(_ label: String) -> Bool {
        guard let hash = label.firstIndex(of: "#"), hash != label.startIndex else { return false }
        let host = label[label.startIndex..<hash]
        guard host.allSatisfy({ $0.isLetter || $0.isNumber || "._-@".contains($0) }) else {
            return false
        }
        let rest = label[label.index(after: hash)...]
        guard let dot = rest.firstIndex(of: ".") else { return false }
        guard let sequence = Int(rest[rest.startIndex..<dot]), sequence > 0 else { return false }
        let epoch = rest[rest.index(after: dot)...]
        return !epoch.isEmpty && epoch.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The label a recorded launch would write, or nil when it writes none.
    public static func label(in text: String) -> String? {
        guard let range = text.range(of: "\(marker)\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let found = String(rest[rest.startIndex..<end])
        return isValidLabel(found) ? found : nil
    }

    /// Re-stamp a recorded launch with the generation the *new* connection will be.
    ///
    /// Returns the text unchanged when it carries no label of ours — a pane launched
    /// before this existed, or one whose command nobody here wrote. Rewriting a string
    /// we did not author is how somebody else's script quietly acquires our semantics.
    public static func rewrite(_ text: String, to label: String) -> String {
        guard isValidLabel(label), let existing = self.label(in: text) else { return text }
        return text.replacingOccurrences(of: "\(marker)\"\(existing)\"",
                                         with: "\(marker)\"\(label)\"")
    }

    public static func rewrite(argv: [String], to label: String) -> [String] {
        argv.map { rewrite($0, to: label) }
    }
}
