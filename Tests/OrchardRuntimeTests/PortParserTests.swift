import XCTest
@testable import OrchardRuntime

final class PortParserTests: XCTestCase {
    func testParsesLsofFieldOutput() {
        let ports = LsofParser.parse([
            "p123",
            "cnode",
            "n127.0.0.1:5173",
            "p456",
            "cnginx",
            "n*:8080",
        ].joined(separator: "\n"))

        XCTAssertEqual(ports, [
            RawListeningPort(host: "127.0.0.1", port: 5173, pid: 123, processName: "node"),
            RawListeningPort(host: "*", port: 8080, pid: 456, processName: "nginx"),
        ])
    }

    func testParsesMultipleListenersOnOneProcess() {
        let ports = LsofParser.parse([
            "p123",
            "cnode",
            "n127.0.0.1:5173",
            "n127.0.0.1:55173",
        ].joined(separator: "\n"))

        XCTAssertEqual(ports.map(\.port), [5173, 55173])
        XCTAssertEqual(Set(ports.map(\.pid)), [123])
        XCTAssertEqual(Set(ports.map(\.processName)), ["node"])
    }

    func testParsesIPv6AndListenSuffix() {
        let ports = LsofParser.parse([
            "p9",
            "cpython",
            "n[::1]:8000",
            "n127.0.0.1:3000 (LISTEN)",
        ].joined(separator: "\n"))

        XCTAssertEqual(ports.map(\.host), ["::1", "127.0.0.1"])
        XCTAssertEqual(ports.map(\.port), [8000, 3000])
    }

    func testSkipsMalformedAndUnknownTags() {
        let ports = LsofParser.parse([
            "pnot-a-pid",
            "f4",
            "n",
            "nno-port-here",
            "p42",
            "cgo",
            "n127.0.0.1:0",
            "n127.0.0.1:70000",
            "n127.0.0.1:8080",
        ].joined(separator: "\n"))

        XCTAssertEqual(ports, [
            RawListeningPort(host: "127.0.0.1", port: 8080, pid: 42, processName: "go"),
        ])
    }

    func testDedupesSameHostPortPidAndCapsCount() {
        let duplicate = LsofParser.parse([
            "p1", "cnode", "n127.0.0.1:80",
            "p1", "cnode", "n127.0.0.1:80",
            "p1", "cnode", "n*:80",
            "p1", "cnode", "n0.0.0.0:80",
        ].joined(separator: "\n"))
        XCTAssertEqual(duplicate.map(\.host), ["127.0.0.1", "*"])

        var lines: [String] = []
        for i in 1...250 {
            lines.append("p\(i)")
            lines.append("cproc")
            lines.append("n127.0.0.1:\(1000 + i)")
        }
        XCTAssertEqual(LsofParser.parse(lines.joined(separator: "\n")).count, LsofParser.maxPorts)
    }

    func testConnectHostNormalizesWildcards() {
        XCTAssertEqual(LsofParser.connectHost(forBindHost: "*"), "localhost")
        XCTAssertEqual(LsofParser.connectHost(forBindHost: "0.0.0.0"), "localhost")
        XCTAssertEqual(LsofParser.connectHost(forBindHost: "::"), "localhost")
        XCTAssertEqual(LsofParser.connectHost(forBindHost: "127.0.0.1"), "127.0.0.1")
    }
}
