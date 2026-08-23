import Darwin
import Foundation

/// Best-effort cwd of a live process. Production uses `proc_pidinfo`; tests inject
/// a map. A miss is `nil` — never an error.
public typealias ProcessWorkingDirectoryLookup = @Sendable (Int32) -> String?

@_silgen_name("proc_pidinfo")
private func orchard_proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64,
                                  _ buffer: UnsafeMutableRawPointer?,
                                  _ buffersize: Int32) -> Int32

/// `PROC_PIDVNODEPATHINFO` layout on darwin (sys/proc_info.h): cwd path sits at
/// offset 152 in a 2352-byte `proc_vnodepathinfo`.
public enum ProcessWorkingDirectory {
    public static let libproc: ProcessWorkingDirectoryLookup = { pid in
        lookup(pid: pid)
    }

    public static func lookup(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        let flavor: Int32 = 9
        let size = 2352
        let pathOffset = 152
        var buffer = [UInt8](repeating: 0, count: size)
        let written = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            return orchard_proc_pidinfo(pid, flavor, 0, base, Int32(size))
        }
        guard written == Int32(size) else { return nil }
        return buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let pointer = base.advanced(by: pathOffset).assumingMemoryBound(to: CChar.self)
            let path = String(cString: pointer)
            return path.isEmpty ? nil : path
        }
    }
}
