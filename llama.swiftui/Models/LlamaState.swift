import Foundation

struct Model: Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var filename: String
    var status: String?
}

@MainActor
class LlamaState: ObservableObject {
    @Published var messageLog = ""
    @Published var cacheCleared = false
    @Published var downloadedModels: [Model] = []
    @Published var undownloadedModels: [Model] = []
    let NS_PER_S = 1_000_000_000.0

    @Published var serverRunning = false
    @Published var serverAddress = ""
    @Published private(set) var apiKeyConfigured = false
    let httpServer = HTTPServer(port: 8080)

    private var llamaContext: LlamaContext?
    private var loadedModel: LoadedModelMetadata?
    private var importedModelScope: URL?
    private let operationGate = WorkerOperationGate()
    private let apiKeyStore = APIKeyStore()

    init() {
        do {
            apiKeyConfigured = try apiKeyStore.load() != nil
        } catch {
            apiKeyConfigured = false
            messageLog += "Secure API key storage is unavailable\n"
        }
        loadModelsFromDisk()
        loadDefaultModels()
    }

    private func loadModelsFromDisk() {
        do {
            let documentsURL = getDocumentsDirectory()
            let modelURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            for modelURL in modelURLs {
                let modelName = modelURL.deletingPathExtension().lastPathComponent
                downloadedModels.append(Model(name: modelName, url: "", filename: modelURL.lastPathComponent, status: "downloaded"))
            }
        } catch {
            print("Error loading models from disk: \(error)")
        }
    }

    private func loadDefaultModels() {
        for model in defaultModels {
            let fileURL = getDocumentsDirectory().appendingPathComponent(model.filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {

            } else {
                var undownloadedModel = model
                undownloadedModel.status = "download"
                undownloadedModels.append(undownloadedModel)
            }
        }
    }

    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    private let defaultModels: [Model] = [
        Model(
            name: "Gemma-3-4B-IT (Q4_K_M, 2.9 GiB)",
            url: "https://huggingface.co/bartowski/google_gemma-3-4b-it-GGUF/resolve/main/google_gemma-3-4b-it-Q4_K_M.gguf?download=true",
            filename: "gemma-3-4b-it-Q4_K_M.gguf", status: "download"
        ),
        Model(
            name: "Qwen-3.5-4B (Q4_K_M, 2.7 GiB)",
            url: "https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/main/Qwen_Qwen3.5-4B-Q4_K_M.gguf?download=true",
            filename: "qwen3.5-4b-Q4_K_M.gguf", status: "download"
        ),
        Model(name: "TinyLlama-1.1B (Q4_0, 0.6 GiB)",url: "https://huggingface.co/TheBloke/TinyLlama-1.1B-1T-OpenOrca-GGUF/resolve/main/tinyllama-1.1b-1t-openorca.Q4_0.gguf?download=true",filename: "tinyllama-1.1b-1t-openorca.Q4_0.gguf", status: "download"),
        Model(
            name: "TinyLlama-1.1B Chat (Q8_0, 1.1 GiB)",
            url: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q8_0.gguf?download=true",
            filename: "tinyllama-1.1b-chat-v1.0.Q8_0.gguf", status: "download"
        ),

        Model(
            name: "TinyLlama-1.1B (F16, 2.2 GiB)",
            url: "https://huggingface.co/ggml-org/models/resolve/main/tinyllama-1.1b/ggml-model-f16.gguf?download=true",
            filename: "tinyllama-1.1b-f16.gguf", status: "download"
        ),

        Model(
            name: "Phi-2.7B (Q4_0, 1.6 GiB)",
            url: "https://huggingface.co/ggml-org/models/resolve/main/phi-2/ggml-model-q4_0.gguf?download=true",
            filename: "phi-2-q4_0.gguf", status: "download"
        ),

        Model(
            name: "Phi-2.7B (Q8_0, 2.8 GiB)",
            url: "https://huggingface.co/ggml-org/models/resolve/main/phi-2/ggml-model-q8_0.gguf?download=true",
            filename: "phi-2-q8_0.gguf", status: "download"
        ),

        Model(
            name: "Mistral-7B-v0.1 (Q4_0, 3.8 GiB)",
            url: "https://huggingface.co/TheBloke/Mistral-7B-v0.1-GGUF/resolve/main/mistral-7b-v0.1.Q4_0.gguf?download=true",
            filename: "mistral-7b-v0.1.Q4_0.gguf", status: "download"
        ),
        Model(
            name: "OpenHermes-2.5-Mistral-7B (Q3_K_M, 3.52 GiB)",
            url: "https://huggingface.co/TheBloke/OpenHermes-2.5-Mistral-7B-GGUF/resolve/main/openhermes-2.5-mistral-7b.Q3_K_M.gguf?download=true",
            filename: "openhermes-2.5-mistral-7b.Q3_K_M.gguf", status: "download"
        )
    ]

    func loadModel(modelUrl: URL?) async throws {
        guard let modelUrl else {
            messageLog += "Load a model from the list below\n"
            return
        }
        guard let lease = operationGate.tryAcquire(.modelLoad) else {
            throw MissionaryXAPIError.workerBusy
        }
        defer { _ = operationGate.release(lease) }

        messageLog += "Loading model...\n"
        let modelPath = modelUrl.path()
        let newContext = try await Task.detached(priority: .userInitiated) {
            try LlamaContext.create_context(path: modelPath)
        }.value
        let description = await newContext.model_info()

        // Replace only after the new context is fully initialized. Llama backend
        // lifetime is process-owned, so destroying the old context cannot tear
        // down global backend state beneath the new context.
        llamaContext = newContext

        // The replaced context was the only thing that could still have the
        // previously imported file mapped, so its security scope is now safe
        // to close. A file imported by this call re-opens its own scope after
        // loadModel returns.
        releaseImportedModelScope()

        loadedModel = LoadedModelMetadata(
            filename: modelUrl.lastPathComponent,
            description: description,
            ready: true
        )
        messageLog += "Loaded model \(modelUrl.lastPathComponent)\n"
        updateDownloadedModels(modelName: modelUrl.lastPathComponent)
    }

    // Loads a .gguf file the user picked from the Files app in place, without
    // copying it into the app sandbox. The picked URL is security scoped and
    // llama.cpp keeps the file mapped for as long as the model is loaded, so
    // the scope is held open past the load and closed only when the model is
    // replaced.
    func loadLocalModel(at fileURL: URL) async throws {
        try LocalModelImport.validate(filename: fileURL.lastPathComponent)

        guard fileURL.startAccessingSecurityScopedResource() else {
            throw MissionaryXAPIError.modelFileAccessDenied
        }

        var scopeRetained = false
        defer {
            if !scopeRetained {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        try await loadModel(modelUrl: fileURL)

        importedModelScope = fileURL
        scopeRetained = true
    }

    private func releaseImportedModelScope() {
        guard let scope = importedModelScope else { return }
        importedModelScope = nil
        scope.stopAccessingSecurityScopedResource()
    }

    private func updateDownloadedModels(modelName: String) {
        undownloadedModels.removeAll {
            $0.filename == modelName
        }
    }

    func complete(text: String) async {
        guard let lease = operationGate.tryAcquire(.inference) else {
            messageLog += "Worker busy\n"
            return
        }
        defer { _ = operationGate.release(lease) }

        guard let llamaContext else {
            messageLog += "No model loaded\n"
            return
        }

        let maximumTokens = MissionaryXLimits.maximumOutputTokens
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try await llamaContext.completion_init(
                text: text,
                maxTokens: maximumTokens
            )
            let initialized = DispatchTime.now().uptimeNanoseconds
            var rawOutput = ""
            var generatedTokens = 0

            generationLoop: while generatedTokens < maximumTokens {
                switch try await llamaContext.completion_loop() {
                case .token(let piece):
                    rawOutput += piece
                    generatedTokens += 1
                case .finished(_, let trailingText):
                    rawOutput += trailingText
                    break generationLoop
                }
            }

            await llamaContext.clear()
            let cleaned = try ModelOutputSanitizer.sanitize(rawOutput)
            let end = DispatchTime.now().uptimeNanoseconds
            let warmup = Double(initialized - start) / NS_PER_S
            let generation = max(Double(end - initialized) / NS_PER_S, 0.001)
            let tokensPerSecond = Double(generatedTokens) / generation

            messageLog += "\(text)\(cleaned)\n"
            messageLog += "Done\n"
            messageLog += "Heat up took \(warmup)s\n"
            messageLog += "Generated \(tokensPerSecond) t/s\n"
        } catch {
            await llamaContext.clear()
            messageLog += "Completion failed: \(error.localizedDescription)\n"
        }
    }

    func bench() async {
        guard let lease = operationGate.tryAcquire(.benchmark) else {
            messageLog += "Worker busy\n"
            return
        }
        defer { _ = operationGate.release(lease) }

        guard let llamaContext else {
            messageLog += "No model loaded\n"
            return
        }

        do {
            messageLog += "\nRunning benchmark...\nModel info: "
            messageLog += await llamaContext.model_info() + "\n"

            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await llamaContext.bench(pp: 8, tg: 4, pl: 1)
            let end = DispatchTime.now().uptimeNanoseconds
            let warmup = Double(end - start) / NS_PER_S
            messageLog += "Heat up time: \(warmup) seconds\n"

            if warmup > 5.0 {
                messageLog += "Heat up time is too long, aborting benchmark\n"
                return
            }

            messageLog += try await llamaContext.bench(
                pp: 512,
                tg: 128,
                pl: 1,
                nr: 3
            )
            messageLog += "\n"
        } catch {
            messageLog += "Benchmark failed: \(error.localizedDescription)\n"
        }
    }

    func clear() async {
        guard let lease = operationGate.tryAcquire(.maintenance) else {
            messageLog += "Worker busy\n"
            return
        }
        defer { _ = operationGate.release(lease) }

        if let llamaContext {
            await llamaContext.clear()
        }
        messageLog = ""
    }

    // MARK: - Authentication

    func saveAPIKey(_ key: String) throws {
        guard !serverRunning else {
            throw MissionaryXAPIError.workerBusy
        }
        try apiKeyStore.save(key)
        apiKeyConfigured = true
        messageLog += "API key saved securely\n"
    }

    func clearAPIKey() throws {
        guard !serverRunning else {
            throw MissionaryXAPIError.workerBusy
        }
        try apiKeyStore.delete()
        apiKeyConfigured = false
        messageLog += "API key removed\n"
    }

    // MARK: - Worker state

    func tryBeginInference() -> WorkerOperationLease? {
        operationGate.tryAcquire(.inference)
    }

    func endOperation(_ lease: WorkerOperationLease) {
        if !operationGate.release(lease) {
            print("Worker operation lease release mismatch")
        }
    }

    func modelsResponse() -> ModelsResponse {
        ModelsResponse(
            model: loadedModel,
            operation: operationGate.snapshot()
        )
    }

    func isReadyForInference() -> Bool {
        llamaContext != nil
            && loadedModel != nil
            && !operationGate.snapshot().isBusy
    }

    // MARK: - HTTP Server

    func toggleServer() {
        if serverRunning {
            httpServer.stop()
            serverRunning = false
            serverAddress = ""
            messageLog += "Server stopped\n"
            return
        }

        do {
            guard let apiKey = try apiKeyStore.load(), !apiKey.isEmpty else {
                apiKeyConfigured = false
                messageLog += "Configure an API key before starting the server\n"
                return
            }
            try httpServer.start(llamaState: self, apiKey: apiKey)
            apiKeyConfigured = true
            serverRunning = true
            let ip = httpServer.getLocalIP()
            serverAddress = "http://\(ip):8080"
            messageLog += "Server started at \(serverAddress)\n"
        } catch {
            messageLog += "Failed to start server: \(error.localizedDescription)\n"
        }
    }

    // The caller must hold the exact inference lease for the entire operation.
    func completeForAPI(
        text: String,
        maxTokens: Int,
        lease: WorkerOperationLease
    ) async throws -> CompletionResult {
        guard lease.kind == .inference, operationGate.owns(lease) else {
            throw MissionaryXAPIError.workerBusy
        }
        guard let llamaContext else {
            throw MissionaryXAPIError.modelNotLoaded
        }

        var rawOutput = ""
        var generatedTokens = 0
        var termination = CompletionTermination.maximumTokens

        do {
            try await llamaContext.completion_init(
                text: text,
                maxTokens: maxTokens,
                parseSpecialTokens: true
            )

            generationLoop: while generatedTokens < maxTokens {
                switch try await llamaContext.completion_loop() {
                case .token(let piece):
                    rawOutput += piece
                    generatedTokens += 1
                case .finished(let reason, let trailingText):
                    rawOutput += trailingText
                    termination = reason
                    break generationLoop
                }
            }
            await llamaContext.clear()
        } catch let apiError as MissionaryXAPIError {
            await llamaContext.clear()
            throw apiError
        } catch {
            await llamaContext.clear()
            throw MissionaryXAPIError.inferenceFailed
        }

        return CompletionResult(
            content: try ModelOutputSanitizer.sanitize(rawOutput),
            finishReason: termination.finishReason
        )
    }
}
