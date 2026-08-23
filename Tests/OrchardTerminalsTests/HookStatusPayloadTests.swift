import XCTest
@testable import OrchardTerminals

final class HookStatusPayloadTests: XCTestCase {

    func testParsesClaudeSnakeCaseAssistantAndPrompt() {
        let json = Data(#"""
        {"hook_event_name":"Stop","prompt":"ship it","last_assistant_message":"Shipped.","session_id":"claude-session-1"}
        """#.utf8)
        let fields = HookStatusFields.parse(json: json)
        XCTAssertEqual(fields.prompt, "ship it")
        XCTAssertEqual(fields.lastAssistantMessage, "Shipped.")
        XCTAssertEqual(fields.providerSessionID, "claude-session-1")
    }

    func testParsesCamelCaseOrcaShape() {
        let fields = HookStatusFields.parse(jsonString:
            #"{"lastAssistantMessage":"Here is the edit.","toolName":"Edit"}"#)
        XCTAssertEqual(fields.lastAssistantMessage, "Here is the edit.")
        XCTAssertEqual(fields.toolName, "Edit")
        XCTAssertNil(fields.prompt)
    }

    func testEmptyOrMalformedYieldsNoValues() {
        XCTAssertFalse(HookStatusFields.parse(json: Data()).hasValues)
        XCTAssertFalse(HookStatusFields.parse(jsonString: "not-json").hasValues)
        XCTAssertFalse(HookStatusFields.parse(jsonString: "[]").hasValues)
        XCTAssertFalse(HookStatusFields.parse(jsonString: #"{"lastAssistantMessage":"   "}"#).hasValues)
    }

    func testOmissionDoesNotClearOnMerge() {
        var fields = HookStatusFields(prompt: "keep me", lastAssistantMessage: "old")
        fields.merge(HookStatusFields(toolName: "Bash"))
        XCTAssertEqual(fields.prompt, "keep me")
        XCTAssertEqual(fields.lastAssistantMessage, "old")
        XCTAssertEqual(fields.toolName, "Bash")
        XCTAssertNil(fields.providerSessionID)
    }

    func testNormalizesNewlinesAndCapsAssistantLength() {
        let fields = HookStatusFields.parse(jsonString:
            #"{"lastAssistantMessage":"a\r\nb\n\n\n\nc"}"#)
        XCTAssertEqual(fields.lastAssistantMessage, "a\nb\n\nc")

        let huge = String(repeating: "x", count: agentStatusAssistantMessageMax + 50)
        let clipped = HookStatusFields.parse(object: ["last_assistant_message": huge])
        XCTAssertEqual(clipped.lastAssistantMessage?.count, agentStatusAssistantMessageMax)
    }
}
