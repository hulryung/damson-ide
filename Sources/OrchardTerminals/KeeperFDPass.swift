import Darwin
import Foundation

/// SCM_RIGHTS fd passing for the keeper handshake — the Swift counterpart of damson's
/// `CFDPass` C shim (`cfd_send` / `cfd_recv`), which damson does not export as a
/// product. The CMSG_* macros don't import into Swift, so their arithmetic is done by
/// hand here — safely, because this file only ever passes exactly ONE `Int32` fd per
/// message, so every length is a compile-time constant that can be written down and
/// checked against `<sys/socket.h>` once:
///
///   Darwin aligns cmsg fields to 4 bytes (`__DARWIN_ALIGN32`);
///   `cmsghdr` = { cmsg_len: socklen_t, cmsg_level: Int32, cmsg_type: Int32 } = 12 B;
///   CMSG_LEN(4) = 12 + 4 = 16, CMSG_SPACE(4) = 16, CMSG_DATA offset = 12.
///
/// The payload is always a single byte: the keeper protocol frames each fd message as
/// "1 payload byte + 1 fd" (see DamsonControl/KeeperProtocol.swift), and the peer reads
/// lines byte-by-byte precisely so it can never consume that byte without MSG_CONTROL.
enum KeeperFDPass {
    private static let controlSize = 16
    private static let dataOffset = 12

    /// Send `payload` (one byte) with `fd` attached as ancillary SCM_RIGHTS data.
    /// Returns the `sendmsg` result: 1 on success, -1 on error (EINTR retried).
    static func send(_ socket: Int32, fd: Int32, payload: UInt8) -> Int {
        var payloadByte = payload
        var control = [UInt8](repeating: 0, count: controlSize)
        control.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: socklen_t(controlSize), toByteOffset: 0, as: socklen_t.self)
            raw.storeBytes(of: SOL_SOCKET, toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: SCM_RIGHTS, toByteOffset: 8, as: Int32.self)
            raw.storeBytes(of: fd, toByteOffset: dataOffset, as: Int32.self)
        }
        return control.withUnsafeMutableBytes { controlRaw in
            withUnsafeMutablePointer(to: &payloadByte) { payloadPtr in
                var iov = iovec(iov_base: UnsafeMutableRawPointer(payloadPtr), iov_len: 1)
                return withUnsafeMutablePointer(to: &iov) { iovPtr -> Int in
                    var msg = msghdr()
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = controlRaw.baseAddress
                    msg.msg_controllen = socklen_t(controlSize)
                    var r = sendmsg(socket, &msg, 0)
                    while r < 0 && errno == EINTR { r = sendmsg(socket, &msg, 0) }
                    return r
                }
            }
        }
    }

    /// Receive one payload byte plus its attached fd. Mirrors `cfd_recv`: returns the
    /// `recvmsg` byte count (0 = EOF, -1 = error) and sets `outFD` to the received
    /// descriptor (CLOEXEC applied) or -1 when none arrived. Truncated ancillary data
    /// closes any received fd and reports an error, so a half-delivered descriptor can
    /// never leak into the caller.
    static func recv(_ socket: Int32, outFD: inout Int32, payload: inout UInt8) -> Int {
        outFD = -1
        var control = [UInt8](repeating: 0, count: controlSize)
        let (received, fd, truncated): (Int, Int32, Bool) =
            control.withUnsafeMutableBytes { controlRaw in
                withUnsafeMutablePointer(to: &payload) { payloadPtr in
                    var iov = iovec(iov_base: UnsafeMutableRawPointer(payloadPtr), iov_len: 1)
                    return withUnsafeMutablePointer(to: &iov) { iovPtr -> (Int, Int32, Bool) in
                        var msg = msghdr()
                        msg.msg_iov = iovPtr
                        msg.msg_iovlen = 1
                        msg.msg_control = controlRaw.baseAddress
                        msg.msg_controllen = socklen_t(controlSize)
                        var r = recvmsg(socket, &msg, 0)
                        while r < 0 && errno == EINTR { r = recvmsg(socket, &msg, 0) }
                        guard r >= 0 else { return (r, -1, false) }
                        var fd: Int32 = -1
                        if msg.msg_controllen >= socklen_t(controlSize) {
                            let level = controlRaw.load(fromByteOffset: 4, as: Int32.self)
                            let type = controlRaw.load(fromByteOffset: 8, as: Int32.self)
                            let len = controlRaw.load(fromByteOffset: 0, as: socklen_t.self)
                            if level == SOL_SOCKET && type == SCM_RIGHTS
                                && len >= socklen_t(controlSize) {
                                fd = controlRaw.load(fromByteOffset: dataOffset, as: Int32.self)
                            }
                        }
                        return (r, fd, (msg.msg_flags & MSG_CTRUNC) != 0)
                    }
                }
            }
        guard received >= 0 else { return -1 }
        if truncated {
            if fd >= 0 { close(fd) }
            return -1
        }
        if fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        outFD = fd
        return received
    }
}
