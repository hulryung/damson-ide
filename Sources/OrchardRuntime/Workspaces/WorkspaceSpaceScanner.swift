import Foundation

/// Walks a local workspace path for disk usage. Never follows symlinks, never
/// talks to git, never talks to a remote host. Call off the main actor — a
/// view body must not walk disk.
public enum WorkspaceSpaceScanner: Sendable {
    /// Resource keys for one entry. Allocated size is the reclaimable figure;
    /// logical `fileSize` is the fallback when allocated is missing (some
    /// volumes / ramdisks).
    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
    ]

    public static func measure(path: String) -> WorkspaceSpaceMeasurement {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return WorkspaceSpaceMeasurement(
                status: .missing,
                error: "Path is not on this machine.")
        }
        if !FileManager.default.isReadableFile(atPath: root.path) {
            return WorkspaceSpaceMeasurement(
                status: .permissionDenied,
                error: "No access to this path.")
        }
        if !isDirectory.boolValue {
            let values = resourceValues(root)
            let kind: WorkspaceSpaceItemKind = values.isSymbolicLink == true
                ? .symlink : (values.isRegularFile == true ? .file : .other)
            let size = allocatedSize(values: values)
            return WorkspaceSpaceMeasurement(
                status: .ok,
                sizeBytes: size,
                topLevelItems: [
                    WorkspaceSpaceItem(name: root.lastPathComponent, path: root.path,
                                       kind: kind, sizeBytes: size)
                ])
        }
        do {
            // Empty options: do not skip hidden (`.git` is most of a worktree)
            // and do not follow symlinks (enumerator never does by default).
            let children = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: resourceKeys,
                options: [])
            var items: [WorkspaceSpaceItem] = []
            var total = allocatedSize(of: root)
            var skipped = 0
            for child in children {
                let (size, skippedChild, kind) = measureEntry(child)
                total += size
                skipped += skippedChild
                items.append(WorkspaceSpaceItem(
                    name: child.lastPathComponent,
                    path: child.path,
                    kind: kind,
                    sizeBytes: size))
            }
            let compacted = WorkspaceSpaceProjection.compactTopLevelItems(items)
            return WorkspaceSpaceMeasurement(
                status: .ok,
                error: nil,
                sizeBytes: total,
                skippedEntryCount: skipped,
                topLevelItems: compacted.items,
                omittedTopLevelItemCount: compacted.omittedCount,
                omittedTopLevelSizeBytes: compacted.omittedBytes)
        } catch let error as NSError {
            return measurement(from: error)
        } catch {
            return WorkspaceSpaceMeasurement(
                status: .error, error: String(describing: error))
        }
    }

    /// Walk one top-level child. Directories are enumerated without following
    /// symlinks (`skipsPackageDescendants` is off so `.git` counts).
    private static func measureEntry(_ url: URL)
        -> (size: Int, skipped: Int, kind: WorkspaceSpaceItemKind) {
        let values = resourceValues(url)
        if values.isSymbolicLink == true {
            return (allocatedSize(values: values), 0, .symlink)
        }
        if values.isDirectory == true {
            let walked = walkDirectory(url)
            return (walked.size + allocatedSize(values: values), walked.skipped, .directory)
        }
        if values.isRegularFile == true {
            return (allocatedSize(values: values), 0, .file)
        }
        return (allocatedSize(values: values), 0, .other)
    }

    private static func walkDirectory(_ url: URL) -> (size: Int, skipped: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { _, _ in true })
        else {
            return (0, 1)
        }
        var size = 0
        var skipped = 0
        while let next = enumerator.nextObject() {
            guard let child = next as? URL else {
                skipped += 1
                continue
            }
            let values = resourceValues(child)
            if values.isSymbolicLink == true {
                // Count the symlink node, do not descend (enumerator already doesn't).
                size += allocatedSize(values: values)
                enumerator.skipDescendants()
                continue
            }
            size += allocatedSize(values: values)
        }
        return (size, skipped)
    }

    private static func resourceValues(_ url: URL) -> URLResourceValues {
        (try? url.resourceValues(forKeys: Set(resourceKeys))) ?? URLResourceValues()
    }

    private static func allocatedSize(of url: URL) -> Int {
        allocatedSize(values: resourceValues(url))
    }

    private static func allocatedSize(values: URLResourceValues) -> Int {
        if let total = values.totalFileAllocatedSize, total > 0 { return total }
        if let allocated = values.fileAllocatedSize, allocated > 0 { return allocated }
        return values.fileSize ?? 0
    }

    private static func measurement(from error: NSError) -> WorkspaceSpaceMeasurement {
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoPermissionError, NSFileReadNoSuchFileError:
                let missing = error.code == NSFileReadNoSuchFileError
                return WorkspaceSpaceMeasurement(
                    status: missing ? .missing : .permissionDenied,
                    error: missing ? "Path is not on this machine." : "No access to this path.")
            default:
                break
            }
        }
        if error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES) {
            return WorkspaceSpaceMeasurement(
                status: .permissionDenied, error: "No access to this path.")
        }
        return WorkspaceSpaceMeasurement(status: .error, error: error.localizedDescription)
    }
}
