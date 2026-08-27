import Foundation
import Network

enum HTTPServerLifecycleState: Equatable {
    case starting
    case ready
    case stopped
    case failed(String)
}

/// Bounded HTTP/1.1 server for controlled MissionaryX device testing.
///
/// This intentionally supports one request per connection, no chunked transfer,
/// no streaming responses, and no persistent connections.
final class HTTPServer {
    private struct ChatCompletionResponse: Encodable {
        struct Choice: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }

            let index: Int
            let message: Message
            let finishReason: String

            enum CodingKeys: String, CodingKey {
                case index
                case message
                case finishReason = "finish_reason"
            }
        }

        let id: String
        let object: String
        let created: Int
        let model: String
        let choices: [Choice]
    }

    private var listener: NWListener?
    private let port: UInt16
    private let configurationLock = NSLock()
    private weak var llamaState: LlamaState?
    private var apiKey: String?
    private var listenerID: UUID?
    private var lifecycleHandler: ((HTTPServerLifecycleState) -> Void)?

    var isRunning: Bool {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return listener != nil
    }

    init(port: UInt16 = 8080) {
        self.port = port
    }

    func start(
        llamaState: LlamaState,
        apiKey: String,
        lifecycleHandler: @escaping (HTTPServerLifecycleState) -> Void
    ) throws {
        guard !isRunning, !apiKey.isEmpty else {
            throw MissionaryXAPIError.workerNotReady
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let newListener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: port)!
        )
        let newListenerID = UUID()
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        newListener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state, listenerID: newListenerID)
        }
        setConfiguration(
            listener: newListener,
            listenerID: newListenerID,
            llamaState: llamaState,
            apiKey: apiKey,
            lifecycleHandler: lifecycleHandler
        )
        lifecycleHandler(.starting)
        newListener.start(queue: .global(qos: .userInitiated))
        print("HTTP server starting on port \(port)")
    }

    func stop() {
        configurationLock.lock()
        let oldListener = listener
        let handler = lifecycleHandler
        listener = nil
        listenerID = nil
        llamaState = nil
        apiKey = nil
        lifecycleHandler = nil
        configurationLock.unlock()

        oldListener?.cancel()
        handler?(.stopped)
        print("HTTP server stopped")
    }

    private func handleListenerState(
        _ state: NWListener.State,
        listenerID reportedID: UUID
    ) {
        switch state {
        case .ready:
            configurationLock.lock()
            let handler = listenerID == reportedID ? lifecycleHandler : nil
            configurationLock.unlock()
            handler?(.ready)
            if handler != nil {
                print("HTTP server listener ready")
            }
        case .failed(let error):
            configurationLock.lock()
            guard listenerID == reportedID else {
                configurationLock.unlock()
                return
            }
            let handler = lifecycleHandler
            listener = nil
            listenerID = nil
            llamaState = nil
            apiKey = nil
            lifecycleHandler = nil
            configurationLock.unlock()
            handler?(.failed(error.localizedDescription))
            print("HTTP server listener failed: \(error.localizedDescription)")
        default:
            break
        }
    }

    func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var pointer = ifaddr
            while pointer != nil {
                defer { pointer = pointer?.pointee.ifa_next }
                guard let interface = pointer?.pointee else { continue }
                let addressFamily = interface.ifa_addr.pointee.sa_family
                if addressFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" {
                        var hostname = [CChar](
                            repeating: 0,
                            count: Int(NI_MAXHOST)
                        )
                        getnameinfo(
                            interface.ifa_addr,
                            socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname,
                            socklen_t(hostname.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        )
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private func handleConnection(_ connection: NWConnection) {
        let accumulator = HTTPRequestAccumulator()
        connection.start(queue: .global(qos: .userInitiated))
        receiveNext(on: connection, accumulator: accumulator)
    }

    private func receiveNext(
        on connection: NWConnection,
        accumulator: HTTPRequestAccumulator
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8 * 1024
        ) { [weak self] data, _, streamEnded, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            let result = accumulator.append(
                data ?? Data(),
                streamEnded: streamEnded
            )
            switch result {
            case .needMoreData:
                self.receiveNext(
                    on: connection,
                    accumulator: accumulator
                )
            case .failure(let apiError):
                self.sendError(
                    connection: connection,
                    error: apiError
                )
            case .complete(let request):
                self.routeRequest(
                    request,
                    connection: connection
                )
            }
        }
    }

    private func routeRequest(
        _ request: ParsedHTTPRequest,
        connection: NWConnection
    ) {
        if request.method == "OPTIONS" {
            sendResponse(
                connection: connection,
                statusCode: 204,
                body: Data(),
                contentType: "text/plain",
                extraHeaders: ["Allow": "GET, POST, OPTIONS"]
            )
            return
        }

        let configuration = configurationSnapshot()
        guard let apiKey = configuration.apiKey,
              BearerAuthenticator.validate(
                headers: request.headers,
                expectedKey: apiKey
              ) == nil else {
            sendError(
                connection: connection,
                error: .unauthorized,
                extraHeaders: ["WWW-Authenticate": "Bearer"]
            )
            return
        }

        switch request.path {
        case "/":
            guard request.method == "GET" else {
                sendError(connection: connection, error: .methodNotAllowed)
                return
            }
            sendResponse(
                connection: connection,
                statusCode: 200,
                body: Data("Crucible LLM Server is running".utf8),
                contentType: "text/plain"
            )

        case "/health":
            guard request.method == "GET" else {
                sendError(connection: connection, error: .methodNotAllowed)
                return
            }
            sendJSON(
                connection: connection,
                statusCode: 200,
                value: HealthResponse(status: "ok")
            )

        case "/ready":
            guard request.method == "GET" else {
                sendError(connection: connection, error: .methodNotAllowed)
                return
            }
            guard let llamaState = configuration.llamaState else {
                sendError(connection: connection, error: .workerNotReady)
                return
            }
            handleReadiness(
                llamaState: llamaState,
                connection: connection
            )

        case "/v1/models":
            guard request.method == "GET" else {
                sendError(connection: connection, error: .methodNotAllowed)
                return
            }
            guard let llamaState = configuration.llamaState else {
                sendError(connection: connection, error: .workerNotReady)
                return
            }
            handleModels(
                llamaState: llamaState,
                connection: connection
            )

        case "/v1/chat/completions":
            guard request.method == "POST" else {
                sendError(connection: connection, error: .methodNotAllowed)
                return
            }
            guard isJSONContentType(request.headers["content-type"]) else {
                sendError(
                    connection: connection,
                    error: MissionaryXAPIError(
                        statusCode: 415,
                        type: "unsupported_media_type",
                        message: "Content-Type must be application/json"
                    )
                )
                return
            }
            guard let llamaState = configuration.llamaState else {
                sendError(connection: connection, error: .workerNotReady)
                return
            }
            handleChatCompletion(
                body: request.body,
                llamaState: llamaState,
                connection: connection
            )

        default:
            sendError(connection: connection, error: .notFound)
        }
    }

    private func handleModels(
        llamaState: LlamaState,
        connection: NWConnection
    ) {
        Task { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            let response = await llamaState.modelsResponse()
            self.sendJSON(
                connection: connection,
                statusCode: 200,
                value: response
            )
        }
    }

    private func handleReadiness(
        llamaState: LlamaState,
        connection: NWConnection
    ) {
        Task { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            let snapshot = await llamaState.readinessSnapshot()
            self.sendJSON(
                connection: connection,
                statusCode: snapshot.httpStatusCode,
                value: ReadyResponse(snapshot: snapshot)
            )
        }
    }

    private func handleChatCompletion(
        body: Data,
        llamaState: LlamaState,
        connection: NWConnection
    ) {
        let validatedRequest: ValidatedChatRequest
        do {
            validatedRequest = try ChatRequestValidator.validate(body: body)
        } catch let apiError as MissionaryXAPIError {
            sendError(connection: connection, error: apiError)
            return
        } catch {
            sendError(connection: connection, error: .malformedJSON)
            return
        }

        Task { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            do {
                let result = try await llamaState.completeForAPI(
                    text: validatedRequest.renderedPrompt,
                    maxTokens: validatedRequest.maxTokens
                )

                let response = ChatCompletionResponse(
                    id: "chatcmpl-\(UUID().uuidString.prefix(8))",
                    object: "chat.completion",
                    created: Int(Date().timeIntervalSince1970),
                    model: "local",
                    choices: [
                        ChatCompletionResponse.Choice(
                            index: 0,
                            message: .init(
                                role: "assistant",
                                content: result.content
                            ),
                            finishReason: result.finishReason.rawValue
                        ),
                    ]
                )
                self.sendJSON(
                    connection: connection,
                    statusCode: 200,
                    value: response
                )
            } catch let apiError as MissionaryXAPIError {
                self.sendError(
                    connection: connection,
                    error: apiError
                )
            } catch {
                self.sendError(
                    connection: connection,
                    error: .inferenceFailed
                )
            }
        }
    }

    private func setConfiguration(
        listener: NWListener,
        listenerID: UUID,
        llamaState: LlamaState,
        apiKey: String,
        lifecycleHandler: @escaping (HTTPServerLifecycleState) -> Void
    ) {
        configurationLock.lock()
        self.listener = listener
        self.listenerID = listenerID
        self.llamaState = llamaState
        self.apiKey = apiKey
        self.lifecycleHandler = lifecycleHandler
        configurationLock.unlock()
    }

    private func isJSONContentType(_ value: String?) -> Bool {
        guard let value,
              let mediaType = value.split(
                  separator: ";",
                  maxSplits: 1,
                  omittingEmptySubsequences: false
              ).first else {
            return false
        }
        return String(mediaType)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "application/json"
    }

    private func configurationSnapshot() -> (
        llamaState: LlamaState?,
        apiKey: String?
    ) {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return (llamaState, apiKey)
    }

    private func sendJSON<T: Encodable>(
        connection: NWConnection,
        statusCode: Int,
        value: T
    ) {
        do {
            sendResponse(
                connection: connection,
                statusCode: statusCode,
                body: try APIJSON.encode(value),
                contentType: "application/json"
            )
        } catch {
            sendError(
                connection: connection,
                error: MissionaryXAPIError(
                    statusCode: 500,
                    type: "serialization_failed",
                    message: "Response serialization failed"
                )
            )
        }
    }

    private func sendError(
        connection: NWConnection,
        error: MissionaryXAPIError,
        extraHeaders: [String: String] = [:]
    ) {
        sendResponse(
            connection: connection,
            statusCode: error.statusCode,
            body: APIJSON.encodeError(error),
            contentType: "application/json",
            extraHeaders: extraHeaders
        )
    }

    private func sendResponse(
        connection: NWConnection,
        statusCode: Int,
        body: Data,
        contentType: String,
        extraHeaders: [String: String] = [:]
    ) {
        var header = "HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        for name in extraHeaders.keys.sorted() {
            if let value = extraHeaders[name] {
                header += "\(name): \(value)\r\n"
            }
        }
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
