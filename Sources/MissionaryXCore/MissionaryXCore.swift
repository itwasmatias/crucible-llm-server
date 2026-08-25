import Foundation

public enum MissionaryXLimits {
    public static let maximumHeaderBytes = 8 * 1024
    public static let maximumBodyBytes = 16 * 1024
    public static let maximumRequestBytes = maximumHeaderBytes + maximumBodyBytes + 4
    public static let maximumMessages = 8
    public static let maximumMessageBytes = 4 * 1024
    public static let minimumCredentialBytes = 16
    public static let maximumCredentialBytes = 256
    public static let promptBatchCapacity = 512
    public static let maximumPromptTokens = 384
    public static let maximumOutputTokens = 128
}

public struct MissionaryXAPIError: Error, LocalizedError, Equatable, Sendable {
    public let statusCode: Int
    public let type: String
    public let message: String

    public init(statusCode: Int, type: String, message: String) {
        self.statusCode = statusCode
        self.type = type
        self.message = message
    }

    public var errorDescription: String? { message }

    public static let malformedRequest = MissionaryXAPIError(
        statusCode: 400,
        type: "malformed_request",
        message: "The HTTP request is malformed"
    )

    public static let malformedJSON = MissionaryXAPIError(
        statusCode: 400,
        type: "malformed_json",
        message: "The request body must be a valid JSON object"
    )

    public static let missingMessages = MissionaryXAPIError(
        statusCode: 400,
        type: "missing_messages",
        message: "messages is required"
    )

    public static let invalidMessages = MissionaryXAPIError(
        statusCode: 400,
        type: "invalid_messages",
        message: "messages must contain between 1 and 8 items"
    )

    public static let invalidMessage = MissionaryXAPIError(
        statusCode: 400,
        type: "invalid_message",
        message: "Each message must contain String role and content values"
    )

    public static let invalidRole = MissionaryXAPIError(
        statusCode: 400,
        type: "unsupported_role",
        message: "Only system and user roles are supported"
    )

    public static let invalidSystemPlacement = MissionaryXAPIError(
        statusCode: 400,
        type: "invalid_system_message",
        message: "At most one system message is allowed and it must be first"
    )

    public static let unsafeMessageContent = MissionaryXAPIError(
        statusCode: 400,
        type: "unsafe_message_content",
        message: "Message content contains a reserved delimiter or NUL"
    )

    public static let messageTooLarge = MissionaryXAPIError(
        statusCode: 413,
        type: "message_too_large",
        message: "A message exceeds the 4 KiB limit"
    )

    public static let invalidMaxTokens = MissionaryXAPIError(
        statusCode: 400,
        type: "invalid_max_tokens",
        message: "max_tokens must be an integer from 1 through 128"
    )

    public static let invalidModel = MissionaryXAPIError(
        statusCode: 400,
        type: "unsupported_model",
        message: "model must be omitted or equal to local"
    )

    public static let streamingUnsupported = MissionaryXAPIError(
        statusCode: 400,
        type: "unsupported_feature",
        message: "Streaming is not supported"
    )

    public static let unsupportedField = MissionaryXAPIError(
        statusCode: 400,
        type: "unsupported_field",
        message: "The request contains an unsupported field"
    )

    public static let unauthorized = MissionaryXAPIError(
        statusCode: 401,
        type: "unauthorized",
        message: "A valid bearer credential is required"
    )

    public static let modelNotLoaded = MissionaryXAPIError(
        statusCode: 503,
        type: "model_not_loaded",
        message: "No model is loaded"
    )

    public static let workerBusy = MissionaryXAPIError(
        statusCode: 409,
        type: "worker_busy",
        message: "An inference request or model operation is already active"
    )

    public static let workerNotReady = MissionaryXAPIError(
        statusCode: 503,
        type: "worker_not_ready",
        message: "The worker is not ready"
    )

    public static let promptTooLarge = MissionaryXAPIError(
        statusCode: 422,
        type: "prompt_too_large",
        message: "The rendered prompt exceeds the 384-token limit"
    )

    public static let tokenBudgetExceeded = MissionaryXAPIError(
        statusCode: 422,
        type: "token_budget_exceeded",
        message: "Rendered prompt tokens plus max_tokens must not exceed 512"
    )

    public static let batchCapacityExceeded = MissionaryXAPIError(
        statusCode: 422,
        type: "batch_capacity_exceeded",
        message: "The prompt cannot fit in the llama batch"
    )

    public static let incompleteReasoning = MissionaryXAPIError(
        statusCode: 422,
        type: "model_output_unusable",
        message: "The model produced an incomplete hidden reasoning block"
    )

    public static let emptyModelOutput = MissionaryXAPIError(
        statusCode: 422,
        type: "model_output_unusable",
        message: "The model produced no usable assistant output"
    )

    public static let inferenceFailed = MissionaryXAPIError(
        statusCode: 500,
        type: "inference_failed",
        message: "Inference failed"
    )

    public static let payloadTooLarge = MissionaryXAPIError(
        statusCode: 413,
        type: "payload_too_large",
        message: "The request exceeds the configured size limit"
    )

    public static let headersTooLarge = MissionaryXAPIError(
        statusCode: 431,
        type: "headers_too_large",
        message: "The HTTP headers exceed the configured size limit"
    )

    public static let lengthRequired = MissionaryXAPIError(
        statusCode: 411,
        type: "length_required",
        message: "Content-Length is required for this request"
    )

    public static let incompleteBody = MissionaryXAPIError(
        statusCode: 400,
        type: "incomplete_body",
        message: "The request body is incomplete"
    )

    public static let unexpectedBodyData = MissionaryXAPIError(
        statusCode: 400,
        type: "unexpected_body_data",
        message: "The request contains bytes beyond Content-Length"
    )

    public static let unsupportedTransferEncoding = MissionaryXAPIError(
        statusCode: 400,
        type: "unsupported_transfer_encoding",
        message: "Transfer-Encoding is not supported"
    )

    public static let methodNotAllowed = MissionaryXAPIError(
        statusCode: 405,
        type: "method_not_allowed",
        message: "The HTTP method is not allowed for this endpoint"
    )

    public static let notFound = MissionaryXAPIError(
        statusCode: 404,
        type: "not_found",
        message: "The requested endpoint does not exist"
    )
}

public struct APIErrorEnvelope: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public let type: String
        public let message: String
    }

    public let error: Detail

    public init(_ error: MissionaryXAPIError) {
        self.error = Detail(type: error.type, message: error.message)
    }
}

public enum APIJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func encodeError(_ error: MissionaryXAPIError) -> Data {
        (try? encode(APIErrorEnvelope(error))) ?? Data(
            #"{"error":{"message":"Response serialization failed","type":"serialization_failed"}}"#.utf8
        )
    }
}

public struct ParsedHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let version: String
    public let headers: [String: String]
    public let body: Data

    public init(
        method: String,
        path: String,
        version: String,
        headers: [String: String],
        body: Data
    ) {
        self.method = method
        self.path = path
        self.version = version
        self.headers = headers
        self.body = body
    }
}

public enum HTTPRequestAccumulatorResult {
    case needMoreData
    case complete(ParsedHTTPRequest)
    case failure(MissionaryXAPIError)
}

public final class HTTPRequestAccumulator {
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private var buffer = Data()
    private var parsedHead: (
        method: String,
        path: String,
        version: String,
        headers: [String: String],
        bodyStart: Int,
        contentLength: Int
    )?
    private var terminal = false

    public init() {}

    public func append(_ data: Data, streamEnded: Bool) -> HTTPRequestAccumulatorResult {
        guard !terminal else {
            return .failure(.malformedRequest)
        }

        guard data.count <= MissionaryXLimits.maximumRequestBytes,
              buffer.count <= MissionaryXLimits.maximumRequestBytes - data.count else {
            terminal = true
            return .failure(.payloadTooLarge)
        }

        buffer.append(data)

        if parsedHead == nil {
            switch parseHeadIfAvailable() {
            case .some(.failure(let error)):
                terminal = true
                return .failure(error)
            case .some(.success(let head)):
                parsedHead = head
            case .none:
                if streamEnded {
                    terminal = true
                    return .failure(.malformedRequest)
                }
                return .needMoreData
            }
        }

        guard let head = parsedHead else {
            terminal = true
            return .failure(.malformedRequest)
        }

        let receivedBodyBytes = buffer.count - head.bodyStart
        if receivedBodyBytes > head.contentLength {
            terminal = true
            return .failure(.unexpectedBodyData)
        }

        if receivedBodyBytes < head.contentLength {
            if streamEnded {
                terminal = true
                return .failure(.incompleteBody)
            }
            return .needMoreData
        }

        terminal = true
        return .complete(
            ParsedHTTPRequest(
                method: head.method,
                path: head.path,
                version: head.version,
                headers: head.headers,
                body: buffer.subdata(in: head.bodyStart..<buffer.count)
            )
        )
    }

    private func parseHeadIfAvailable() -> Result<(
        method: String,
        path: String,
        version: String,
        headers: [String: String],
        bodyStart: Int,
        contentLength: Int
    ), MissionaryXAPIError>? {
        guard let separator = buffer.range(of: Self.headerTerminator) else {
            if buffer.count > MissionaryXLimits.maximumHeaderBytes {
                return .failure(.headersTooLarge)
            }
            return nil
        }

        guard separator.lowerBound <= MissionaryXLimits.maximumHeaderBytes else {
            return .failure(.headersTooLarge)
        }

        let headerData = buffer.subdata(in: 0..<separator.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(.malformedRequest)
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(.malformedRequest)
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.1",
              !requestParts[0].isEmpty,
              !requestParts[1].isEmpty else {
            return .failure(.malformedRequest)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(.malformedRequest)
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, headers[name] == nil else {
                return .failure(.malformedRequest)
            }
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            return .failure(.unsupportedTransferEncoding)
        }

        let method = String(requestParts[0])
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty,
                  rawLength.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let parsedLength = Int(rawLength),
                  parsedLength >= 0 else {
                return .failure(.malformedRequest)
            }
            contentLength = parsedLength
        } else if method == "POST" {
            return .failure(.lengthRequired)
        } else {
            contentLength = 0
        }

        guard contentLength <= MissionaryXLimits.maximumBodyBytes else {
            return .failure(.payloadTooLarge)
        }

        return .success(
            (
                method: method,
                path: String(requestParts[1]),
                version: String(requestParts[2]),
                headers: headers,
                bodyStart: separator.upperBound,
                contentLength: contentLength
            )
        )
    }
}

public enum BearerAuthenticator {
    public static func validate(headers: [String: String], expectedKey: String) -> MissionaryXAPIError? {
        guard expectedKey.utf8.count >= MissionaryXLimits.minimumCredentialBytes,
              expectedKey.utf8.count <= MissionaryXLimits.maximumCredentialBytes,
              let authorization = headers["authorization"] else {
            return .unauthorized
        }

        let parts = authorization.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard parts.count == 2,
              String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame,
              constantTimeEqual(String(parts[1]), expectedKey) else {
            return .unauthorized
        }

        return nil
    }

    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        var difference = leftBytes.count ^ rightBytes.count
        if leftBytes.count > MissionaryXLimits.maximumCredentialBytes
            || rightBytes.count > MissionaryXLimits.maximumCredentialBytes {
            difference |= 1
        }

        for index in 0..<MissionaryXLimits.maximumCredentialBytes {
            let leftByte = index < leftBytes.count ? Int(leftBytes[index]) : 0
            let rightByte = index < rightBytes.count ? Int(rightBytes[index]) : 0
            difference |= leftByte ^ rightByte
        }

        return difference == 0
    }
}

public struct ValidatedChatMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ValidatedChatRequest: Equatable, Sendable {
    public let messages: [ValidatedChatMessage]
    public let maxTokens: Int
    public let renderedPrompt: String
}

public enum ChatRequestValidator {
    private static let allowedTopLevelFields: Set<String> = [
        "model", "messages", "max_tokens", "stream",
    ]
    private static let allowedMessageFields: Set<String> = ["role", "content"]
    private static let forbiddenContent = ["<|im_start|>", "<|im_end|>", "\0"]

    public static func validate(body: Data) throws -> ValidatedChatRequest {
        guard !body.isEmpty,
              body.count <= MissionaryXLimits.maximumBodyBytes,
              let rawObject = try? JSONSerialization.jsonObject(with: body),
              let rawDictionary = rawObject as? [String: Any] else {
            throw MissionaryXAPIError.malformedJSON
        }

        guard rawDictionary["messages"] != nil else {
            throw MissionaryXAPIError.missingMessages
        }

        let unknownFields = Set(rawDictionary.keys).subtracting(allowedTopLevelFields)
        guard unknownFields.isEmpty else {
            throw MissionaryXAPIError.unsupportedField
        }

        if let rawStream = rawDictionary["stream"] {
            guard let stream = rawStream as? Bool else {
                throw MissionaryXAPIError.unsupportedField
            }
            if stream {
                throw MissionaryXAPIError.streamingUnsupported
            }
        }

        guard let rawMaxTokens = rawDictionary["max_tokens"],
              let maxTokens = strictInteger(rawMaxTokens),
              maxTokens >= 1,
              maxTokens <= MissionaryXLimits.maximumOutputTokens else {
            throw MissionaryXAPIError.invalidMaxTokens
        }

        if let rawModel = rawDictionary["model"] {
            guard let model = rawModel as? String, model == "local" else {
                throw MissionaryXAPIError.invalidModel
            }
        }

        guard let rawMessages = rawDictionary["messages"] as? [[String: Any]],
              !rawMessages.isEmpty,
              rawMessages.count <= MissionaryXLimits.maximumMessages else {
            throw MissionaryXAPIError.invalidMessages
        }

        var systemCount = 0
        var validatedMessages: [ValidatedChatMessage] = []
        for (index, rawMessage) in rawMessages.enumerated() {
            let unknownMessageFields = Set(rawMessage.keys).subtracting(allowedMessageFields)
            guard unknownMessageFields.isEmpty else {
                throw MissionaryXAPIError.invalidMessage
            }

            guard let role = rawMessage["role"] as? String,
                  let content = rawMessage["content"] as? String else {
                throw MissionaryXAPIError.invalidMessage
            }

            guard role == "system" || role == "user" else {
                throw MissionaryXAPIError.invalidRole
            }

            if role == "system" {
                systemCount += 1
                guard index == 0, systemCount == 1 else {
                    throw MissionaryXAPIError.invalidSystemPlacement
                }
            }

            guard content.utf8.count <= MissionaryXLimits.maximumMessageBytes else {
                throw MissionaryXAPIError.messageTooLarge
            }

            guard !forbiddenContent.contains(where: { content.contains($0) }) else {
                throw MissionaryXAPIError.unsafeMessageContent
            }

            validatedMessages.append(ValidatedChatMessage(role: role, content: content))
        }

        return ValidatedChatRequest(
            messages: validatedMessages,
            maxTokens: maxTokens,
            renderedPrompt: renderPrompt(messages: validatedMessages)
        )
    }

    private static func strictInteger(_ value: Any) -> Int? {
        guard !(value is Bool), let number = value as? NSNumber else {
            return nil
        }
        let typeCode = String(cString: number.objCType)
        guard typeCode != "f", typeCode != "d" else {
            return nil
        }
        let integer = number.int64Value
        guard number.compare(NSNumber(value: integer)) == .orderedSame,
              integer >= Int64(Int.min),
              integer <= Int64(Int.max) else {
            return nil
        }
        return Int(integer)
    }

    public static func renderPrompt(messages: [ValidatedChatMessage]) -> String {
        var prompt = ""
        if messages.first?.role != "system" {
            prompt += "<|im_start|>system\n/no_think\nBe concise and helpful.<|im_end|>\n"
        }
        for message in messages {
            prompt += "<|im_start|>\(message.role)\n\(message.content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }
}

public enum TokenBudget {
    public static func validate(promptTokens: Int, requestedOutputTokens: Int) throws {
        guard promptTokens >= 1,
              promptTokens <= MissionaryXLimits.maximumPromptTokens else {
            throw MissionaryXAPIError.promptTooLarge
        }
        guard requestedOutputTokens >= 1,
              requestedOutputTokens <= MissionaryXLimits.maximumOutputTokens else {
            throw MissionaryXAPIError.invalidMaxTokens
        }
        guard promptTokens <= MissionaryXLimits.promptBatchCapacity - requestedOutputTokens else {
            throw MissionaryXAPIError.tokenBudgetExceeded
        }
    }
}

public enum BatchCapacityGuard {
    public static func validate(nextIndex: Int, capacity: Int = MissionaryXLimits.promptBatchCapacity) throws {
        guard capacity > 0, nextIndex >= 0, nextIndex < capacity else {
            throw MissionaryXAPIError.batchCapacityExceeded
        }
    }
}

public enum WorkerOperationKind: String, Sendable {
    case inference
    case modelLoad
    case benchmark
    case maintenance
}

public struct WorkerOperationLease: Equatable, Sendable {
    fileprivate let id: UUID
    public let kind: WorkerOperationKind
}

public struct WorkerOperationSnapshot: Equatable, Sendable {
    public let activeKind: WorkerOperationKind?

    public var isBusy: Bool { activeKind != nil }
    public var isInferenceActive: Bool { activeKind == .inference }
    public var isModelLoading: Bool { activeKind == .modelLoad }
}

public final class WorkerOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeLease: WorkerOperationLease?

    public init() {}

    public func tryAcquire(_ kind: WorkerOperationKind) -> WorkerOperationLease? {
        lock.lock()
        defer { lock.unlock() }
        guard activeLease == nil else {
            return nil
        }
        let lease = WorkerOperationLease(id: UUID(), kind: kind)
        activeLease = lease
        return lease
    }

    @discardableResult
    public func release(_ lease: WorkerOperationLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeLease == lease else {
            return false
        }
        activeLease = nil
        return true
    }

    public func snapshot() -> WorkerOperationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return WorkerOperationSnapshot(activeKind: activeLease?.kind)
    }

    public func owns(_ lease: WorkerOperationLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeLease == lease
    }
}

public enum CompletionFinishReason: String, Codable, Equatable, Sendable {
    case stop
    case length
}

public enum CompletionTermination: Equatable, Sendable {
    case endOfGeneration
    case maximumTokens
    case contextLimit

    public var finishReason: CompletionFinishReason {
        switch self {
        case .endOfGeneration:
            return .stop
        case .maximumTokens, .contextLimit:
            return .length
        }
    }
}

public struct CompletionResult: Equatable, Sendable {
    public let content: String
    public let finishReason: CompletionFinishReason

    public init(content: String, finishReason: CompletionFinishReason) {
        self.content = content
        self.finishReason = finishReason
    }
}

public enum ModelOutputSanitizer {
    public static func sanitize(_ rawOutput: String) throws -> String {
        var output = rawOutput

        if let thinkStart = output.range(of: "<think>") {
            guard let thinkEnd = output.range(
                of: "</think>",
                range: thinkStart.upperBound..<output.endIndex
            ) else {
                throw MissionaryXAPIError.incompleteReasoning
            }
            output = String(output[thinkEnd.upperBound...])
        }

        if output.contains("<think>") || output.contains("</think>") {
            throw MissionaryXAPIError.incompleteReasoning
        }

        if let endTag = output.range(of: "<|im_end|>") {
            output = String(output[..<endTag.lowerBound])
        }

        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw MissionaryXAPIError.emptyModelOutput
        }
        return cleaned
    }
}

public struct LoadedModelMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let ownedBy: String
    public let filename: String
    public let description: String
    public let ready: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case ownedBy = "owned_by"
        case filename
        case description
        case ready
    }

    public init(filename: String, description: String, ready: Bool) {
        self.id = "local"
        self.object = "model"
        self.created = 0
        self.ownedBy = "local"
        self.filename = filename
        self.description = description
        self.ready = ready
    }
}

public struct ModelsResponse: Codable, Equatable, Sendable {
    public struct State: Codable, Equatable, Sendable {
        public let ready: Bool
        public let loading: Bool
        public let inferenceActive: Bool

        enum CodingKeys: String, CodingKey {
            case ready
            case loading
            case inferenceActive = "inference_active"
        }
    }

    public let object: String
    public let data: [LoadedModelMetadata]
    public let state: State

    public init(model: LoadedModelMetadata?, operation: WorkerOperationSnapshot) {
        let ready = model != nil && !operation.isBusy
        self.object = "list"
        self.data = model.map {
            [
                LoadedModelMetadata(
                    filename: $0.filename,
                    description: $0.description,
                    ready: ready
                ),
            ]
        } ?? []
        self.state = State(
            ready: ready,
            loading: operation.isModelLoading,
            inferenceActive: operation.isInferenceActive
        )
    }
}

public struct HealthResponse: Codable, Equatable, Sendable {
    public let status: String

    public init(status: String) {
        self.status = status
    }
}

public struct ReadyResponse: Codable, Equatable, Sendable {
    public let status: String
    public let model: String

    public init() {
        self.status = "ready"
        self.model = "local"
    }
}
