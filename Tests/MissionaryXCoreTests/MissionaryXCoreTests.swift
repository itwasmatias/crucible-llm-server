import Foundation
import Dispatch
import XCTest
@testable import MissionaryXCore

final class MissionaryXCoreTests: XCTestCase {
    private final class LeaseCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var leases: [WorkerOperationLease] = []

        func append(_ lease: WorkerOperationLease) {
            lock.lock()
            leases.append(lease)
            lock.unlock()
        }

        func snapshot() -> [WorkerOperationLease] {
            lock.lock()
            defer { lock.unlock() }
            return leases
        }
    }

    private let validKey = "unit-test-credential-not-a-secret"

    private func body(
        role: String = "user",
        content: String = "Return MX-OK",
        maxTokens: String = "8",
        model: String? = "local",
        stream: String? = "false",
        extra: String = ""
    ) -> Data {
        var fields = [
            #""messages":[{"role":"\#(role)","content":"\#(content)"}]"#,
            #""max_tokens":\#(maxTokens)"#,
        ]
        if let model {
            fields.append(#""model":"\#(model)""#)
        }
        if let stream {
            fields.append(#""stream":\#(stream)"#)
        }
        if !extra.isEmpty {
            fields.append(extra)
        }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    private func assertAPIError(
        _ expected: MissionaryXAPIError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? MissionaryXAPIError, expected, file: file, line: line)
        }
    }

    func testNoModelErrorIsNonSuccess() {
        XCTAssertEqual(MissionaryXAPIError.modelNotLoaded.statusCode, 503)
        let response = String(decoding: APIJSON.encodeError(.modelNotLoaded), as: UTF8.self)
        XCTAssertTrue(response.contains(#""type":"model_not_loaded""#))
        XCTAssertFalse(response.contains(#""role":"assistant""#))
    }

    func testModelsResponseIsEmptyWhenNoModelIsLoaded() {
        let response = ModelsResponse(
            model: nil,
            operation: WorkerOperationSnapshot(activeKind: nil)
        )
        XCTAssertTrue(response.data.isEmpty)
        XCTAssertFalse(response.state.ready)
        XCTAssertFalse(response.state.loading)
    }

    func testModelsResponseUsesLiveMetadataAndReportsInferenceActivity() {
        let model = LoadedModelMetadata(
            filename: "test-model.gguf",
            description: "test description",
            ready: true
        )
        let busy = ModelsResponse(
            model: model,
            operation: WorkerOperationSnapshot(activeKind: .inference)
        )
        XCTAssertEqual(busy.data.map(\.filename), ["test-model.gguf"])
        XCTAssertFalse(busy.data[0].ready)
        XCTAssertFalse(busy.state.ready)
        XCTAssertTrue(busy.state.inferenceActive)

        let idle = ModelsResponse(
            model: model,
            operation: WorkerOperationSnapshot(activeKind: nil)
        )
        XCTAssertTrue(idle.data[0].ready)
        XCTAssertTrue(idle.state.ready)
    }

    func testMalformedJSONIsRejected() {
        assertAPIError(.malformedJSON) {
            _ = try ChatRequestValidator.validate(body: Data(#"{"messages":"#.utf8))
        }
    }

    func testMissingMessagesIsRejected() {
        assertAPIError(.missingMessages) {
            _ = try ChatRequestValidator.validate(
                body: Data(#"{"model":"local","max_tokens":8}"#.utf8)
            )
        }
    }

    func testEmptyAndTooManyMessagesAreRejected() {
        assertAPIError(.invalidMessages) {
            _ = try ChatRequestValidator.validate(
                body: Data(#"{"messages":[],"max_tokens":8}"#.utf8)
            )
        }

        let nineMessages = Array(
            repeating: #"{"role":"user","content":"x"}"#,
            count: 9
        ).joined(separator: ",")
        assertAPIError(.invalidMessages) {
            _ = try ChatRequestValidator.validate(
                body: Data(#"{"messages":[\#(nineMessages)],"max_tokens":8}"#.utf8)
            )
        }
    }

    func testExactlyEightMessagesAreAccepted() throws {
        let eightMessages = Array(
            repeating: #"{"role":"user","content":"x"}"#,
            count: 8
        ).joined(separator: ",")
        let request = try ChatRequestValidator.validate(
            body: Data(#"{"messages":[\#(eightMessages)],"max_tokens":1}"#.utf8)
        )
        XCTAssertEqual(request.messages.count, 8)
    }

    func testInvalidRoleIsRejected() {
        assertAPIError(.invalidRole) {
            _ = try ChatRequestValidator.validate(body: body(role: "assistant"))
        }
    }

    func testSystemMessageMustBeFirstAndUnique() {
        let misplaced = Data(
            #"{"messages":[{"role":"user","content":"x"},{"role":"system","content":"y"}],"max_tokens":8}"#.utf8
        )
        assertAPIError(.invalidSystemPlacement) {
            _ = try ChatRequestValidator.validate(body: misplaced)
        }
    }

    func testChatMLDelimitersAreRejected() {
        for delimiter in ["<|im_start|>", "<|im_end|>"] {
            assertAPIError(.unsafeMessageContent) {
                _ = try ChatRequestValidator.validate(body: body(content: delimiter))
            }
        }
    }

    func testNULIsRejected() {
        let request = Data(
            #"{"messages":[{"role":"user","content":"before\u0000after"}],"max_tokens":8}"#.utf8
        )
        assertAPIError(.unsafeMessageContent) {
            _ = try ChatRequestValidator.validate(body: request)
        }
    }

    func testInvalidMaxTokensAreRejected() {
        for value in [
            "0", "-1", "129", #""8""#, "8.0", "1e0", "true", "null",
            "18446744073709551617",
        ] {
            assertAPIError(.invalidMaxTokens) {
                _ = try ChatRequestValidator.validate(body: body(maxTokens: value))
            }
        }

        assertAPIError(.invalidMaxTokens) {
            _ = try ChatRequestValidator.validate(
                body: Data(#"{"messages":[{"role":"user","content":"x"}]}"#.utf8)
            )
        }
    }

    func testUnsupportedModelIsRejectedAndOmittedModelIsAccepted() throws {
        assertAPIError(.invalidModel) {
            _ = try ChatRequestValidator.validate(body: body(model: "qwen"))
        }

        let request = try ChatRequestValidator.validate(body: body(model: nil))
        XCTAssertEqual(request.maxTokens, 8)
    }

    func testStreamingTrueIsRejectedAndFalseIsAccepted() throws {
        assertAPIError(.streamingUnsupported) {
            _ = try ChatRequestValidator.validate(body: body(stream: "true"))
        }
        XCTAssertNoThrow(try ChatRequestValidator.validate(body: body(stream: "false")))
    }

    func testUnknownCapabilitiesAreRejected() {
        assertAPIError(.unsupportedField) {
            _ = try ChatRequestValidator.validate(
                body: body(extra: #""tools":[],"temperature":0.1"#)
            )
        }
    }

    func testMessageContentMustBeString() {
        let request = Data(
            #"{"messages":[{"role":"user","content":42}],"max_tokens":8}"#.utf8
        )
        assertAPIError(.invalidMessage) {
            _ = try ChatRequestValidator.validate(body: request)
        }
    }

    func testMessageContentByteLimitIsEnforced() throws {
        let acceptedObject: [String: Any] = [
            "messages": [["role": "user", "content": String(repeating: "x", count: 4096)]],
            "max_tokens": 1,
        ]
        let acceptedData = try JSONSerialization.data(withJSONObject: acceptedObject)
        XCTAssertNoThrow(try ChatRequestValidator.validate(body: acceptedData))

        let rejectedObject: [String: Any] = [
            "messages": [["role": "user", "content": String(repeating: "x", count: 4097)]],
            "max_tokens": 1,
        ]
        let rejectedData = try JSONSerialization.data(withJSONObject: rejectedObject)
        assertAPIError(.messageTooLarge) {
            _ = try ChatRequestValidator.validate(body: rejectedData)
        }
    }

    func testPromptTokenLimitAndCombinedBudget() throws {
        XCTAssertNoThrow(
            try TokenBudget.validate(promptTokens: 384, requestedOutputTokens: 128)
        )
        assertAPIError(.promptTooLarge) {
            try TokenBudget.validate(promptTokens: 385, requestedOutputTokens: 1)
        }
        assertAPIError(.invalidMaxTokens) {
            try TokenBudget.validate(promptTokens: 384, requestedOutputTokens: 129)
        }
    }

    func testBatchCapacityBoundaryCannotOverflow() throws {
        XCTAssertNoThrow(try BatchCapacityGuard.validate(nextIndex: 511, capacity: 512))
        assertAPIError(.batchCapacityExceeded) {
            try BatchCapacityGuard.validate(nextIndex: 512, capacity: 512)
        }
        assertAPIError(.batchCapacityExceeded) {
            try BatchCapacityGuard.validate(nextIndex: -1, capacity: 512)
        }
    }

    func testOnlyOneOperationLeaseCanBeActive() {
        let gate = WorkerOperationGate()
        let collector = LeaseCollector()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if let lease = gate.tryAcquire(.inference) {
                collector.append(lease)
            }
        }

        let acquired = collector.snapshot()
        XCTAssertEqual(acquired.count, 1)
        XCTAssertTrue(gate.snapshot().isInferenceActive)
        XCTAssertTrue(gate.release(acquired[0]))
        XCTAssertFalse(gate.snapshot().isBusy)
    }

    func testModelReloadIsRejectedDuringInference() {
        let gate = WorkerOperationGate()
        let inference = gate.tryAcquire(.inference)
        XCTAssertNotNil(inference)
        XCTAssertNil(gate.tryAcquire(.modelLoad))
        XCTAssertTrue(gate.release(inference!))
        XCTAssertNotNil(gate.tryAcquire(.modelLoad))
    }

    func testFinishReasonDistinguishesLengthAndStop() {
        XCTAssertEqual(
            CompletionTermination.endOfGeneration.finishReason,
            .stop
        )
        XCTAssertEqual(
            CompletionTermination.maximumTokens.finishReason,
            .length
        )
        XCTAssertEqual(
            CompletionTermination.contextLimit.finishReason,
            .length
        )
    }

    func testReasoningBlocksAreRemovedWithoutLeakingContent() throws {
        XCTAssertEqual(
            try ModelOutputSanitizer.sanitize("<think>private reasoning</think>MX-OK"),
            "MX-OK"
        )
        assertAPIError(.incompleteReasoning) {
            _ = try ModelOutputSanitizer.sanitize("<think>unfinished")
        }
        assertAPIError(.emptyModelOutput) {
            _ = try ModelOutputSanitizer.sanitize("<think>private</think>   ")
        }
    }

    func testAuthenticationMissingAndInvalidAreRejected() {
        XCTAssertEqual(
            BearerAuthenticator.validate(headers: [:], expectedKey: validKey),
            .unauthorized
        )
        XCTAssertEqual(
            BearerAuthenticator.validate(
                headers: ["authorization": "Bearer \(validKey)"],
                expectedKey: ""
            ),
            .unauthorized
        )
        XCTAssertEqual(
            BearerAuthenticator.validate(
                headers: ["authorization": "Bearer incorrect-test-value"],
                expectedKey: validKey
            ),
            .unauthorized
        )
    }

    func testValidCredentialReachesRequestValidation() throws {
        XCTAssertNil(
            BearerAuthenticator.validate(
                headers: ["authorization": "Bearer \(validKey)"],
                expectedKey: validKey
            )
        )
        XCTAssertNoThrow(try ChatRequestValidator.validate(body: body()))
    }

    func testCredentialNeverAppearsInErrorResponse() {
        let response = String(decoding: APIJSON.encodeError(.unauthorized), as: UTF8.self)
        XCTAssertFalse(response.contains(validKey))
        XCTAssertTrue(response.contains(#""type":"unauthorized""#))
    }

    func testFragmentedHTTPBodyIsAssembledUsingContentLength() {
        let requestBody = body()
        let head = Data(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: phone\r\nContent-Type: application/json\r\nContent-Length: \(requestBody.count)\r\nAuthorization: Bearer \(validKey)\r\n\r\n".utf8
        )
        let accumulator = HTTPRequestAccumulator()

        var firstFragment = head
        firstFragment.append(Data(requestBody.prefix(3)))
        switch accumulator.append(firstFragment, streamEnded: false) {
        case .needMoreData:
            break
        default:
            XCTFail("Expected the parser to wait for the remaining body")
        }

        switch accumulator.append(Data(requestBody.dropFirst(3)), streamEnded: false) {
        case .complete(let request):
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/v1/chat/completions")
            XCTAssertEqual(request.body, requestBody)
            XCTAssertEqual(request.headers["authorization"], "Bearer \(validKey)")
        default:
            XCTFail("Expected a complete parsed request")
        }
    }

    func testIncompleteBodyAndChunkedEncodingFailClosed() {
        let incomplete = HTTPRequestAccumulator()
        let incompleteData = Data(
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8
        )
        switch incomplete.append(incompleteData, streamEnded: true) {
        case .failure(let error):
            XCTAssertEqual(error, .incompleteBody)
        default:
            XCTFail("Expected incomplete_body")
        }

        let chunked = HTTPRequestAccumulator()
        let chunkedData = Data(
            "POST /v1/chat/completions HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
        )
        switch chunked.append(chunkedData, streamEnded: false) {
        case .failure(let error):
            XCTAssertEqual(error, .unsupportedTransferEncoding)
        default:
            XCTFail("Expected unsupported_transfer_encoding")
        }
    }

    func testBodyLargerThanLimitIsRejectedBeforeAccumulation() {
        let accumulator = HTTPRequestAccumulator()
        let data = Data(
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: \(MissionaryXLimits.maximumBodyBytes + 1)\r\n\r\n".utf8
        )
        switch accumulator.append(data, streamEnded: false) {
        case .failure(let error):
            XCTAssertEqual(error, .payloadTooLarge)
        default:
            XCTFail("Expected payload_too_large")
        }
    }

    func testOversizedFirstFragmentFailsWithoutArithmeticUnderflow() {
        let accumulator = HTTPRequestAccumulator()
        let fragment = Data(
            repeating: 0x41,
            count: MissionaryXLimits.maximumRequestBytes + 1
        )
        switch accumulator.append(fragment, streamEnded: false) {
        case .failure(let error):
            XCTAssertEqual(error, .payloadTooLarge)
        default:
            XCTFail("Expected payload_too_large")
        }
    }

    func testDuplicateContentLengthAndExtraBodyBytesFailClosed() {
        let duplicate = HTTPRequestAccumulator()
        let duplicateData = Data(
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\n{}".utf8
        )
        switch duplicate.append(duplicateData, streamEnded: false) {
        case .failure(let error):
            XCTAssertEqual(error, .malformedRequest)
        default:
            XCTFail("Expected malformed_request")
        }

        let extra = HTTPRequestAccumulator()
        let extraData = Data(
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}x".utf8
        )
        switch extra.append(extraData, streamEnded: false) {
        case .failure(let error):
            XCTAssertEqual(error, .unexpectedBodyData)
        default:
            XCTFail("Expected unexpected_body_data")
        }

        let malformedLength = HTTPRequestAccumulator()
        let malformedLengthData = Data(
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: +2\r\n\r\n{}".utf8
        )
        switch malformedLength.append(malformedLengthData, streamEnded: false) {
        case .failure(let error):
            XCTAssertEqual(error, .malformedRequest)
        default:
            XCTFail("Expected malformed_request")
        }
    }

    // MARK: - Local GGUF import

    func testLocalImportAcceptsGGUFFilenames() {
        XCTAssertTrue(LocalModelImport.isAcceptedModelFilename("tinyllama-1.1b-chat-v1.0.Q8_0.gguf"))
        XCTAssertTrue(LocalModelImport.isAcceptedModelFilename("a.gguf"))
        XCTAssertTrue(LocalModelImport.isAcceptedModelFilename("model.GGUF"))
        XCTAssertTrue(LocalModelImport.isAcceptedModelFilename("model with spaces.GgUf"))
        XCTAssertTrue(LocalModelImport.isAcceptedModelFilename("model.bin.gguf"))
        XCTAssertNoThrow(try LocalModelImport.validate(filename: "phi-2-q4_0.gguf"))
    }

    func testLocalImportRejectsNonGGUFFilenames() {
        let rejected = [
            "",
            ".gguf",
            "model",
            "model.bin",
            "model.gguf.bin",
            "model.ggufx",
            "gguf",
            "models/model.gguf",
            "model.gguf\u{0}",
            "model\u{0}.gguf",
        ]

        for filename in rejected {
            XCTAssertFalse(
                LocalModelImport.isAcceptedModelFilename(filename),
                "Expected \(filename) to be rejected"
            )
            assertAPIError(.unsupportedModelFile) {
                try LocalModelImport.validate(filename: filename)
            }
        }
    }

    func testLocalImportErrorsAreDistinctAndNonSuccess() {
        XCTAssertEqual(MissionaryXAPIError.unsupportedModelFile.statusCode, 400)
        XCTAssertEqual(MissionaryXAPIError.unsupportedModelFile.type, "unsupported_model_file")
        XCTAssertEqual(MissionaryXAPIError.modelFileAccessDenied.statusCode, 403)
        XCTAssertEqual(MissionaryXAPIError.modelFileAccessDenied.type, "model_file_access_denied")
        XCTAssertNotEqual(
            MissionaryXAPIError.unsupportedModelFile,
            MissionaryXAPIError.modelFileAccessDenied
        )
        XCTAssertEqual(
            MissionaryXAPIError.unsupportedModelFile.errorDescription,
            "Only .gguf model files can be imported"
        )
        XCTAssertEqual(LocalModelImport.allowedFileExtension, "gguf")
    }
}
