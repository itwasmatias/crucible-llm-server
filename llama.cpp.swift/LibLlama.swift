import Foundation
import llama

enum LlamaError: Error, LocalizedError {
    case modelFileLoadFailed
    case contextInitializationFailed
    case samplerInitializationFailed
    case tokenizationFailed
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .modelFileLoadFailed:
            return "MODEL_FILE_LOAD_FAILED: llama_model_load_from_file returned nil"
        case .contextInitializationFailed:
            return "CONTEXT_INITIALIZATION_FAILED: llama_init_from_model returned nil"
        case .samplerInitializationFailed:
            return "SAMPLER_INITIALIZATION_FAILED"
        case .tokenizationFailed:
            return "TOKENIZATION_FAILED"
        case .decodeFailed:
            return "DECODE_FAILED"
        }
    }
}

private func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func llama_batch_add(
    _ batch: inout llama_batch,
    _ id: llama_token,
    _ pos: llama_pos,
    _ seq_ids: [llama_seq_id],
    _ logits: Bool,
    capacity: Int
) throws {
    let nextIndex = Int(batch.n_tokens)
    try BatchCapacityGuard.validate(
        nextIndex: nextIndex,
        capacity: capacity
    )
    guard seq_ids.count <= 1 else {
        throw MissionaryXAPIError.batchCapacityExceeded
    }

    batch.token[nextIndex] = id
    batch.pos[nextIndex] = pos
    batch.n_seq_id[nextIndex] = Int32(seq_ids.count)
    for i in 0..<seq_ids.count {
        batch.seq_id[nextIndex]![i] = seq_ids[i]
    }
    batch.logits[nextIndex] = logits ? 1 : 0

    batch.n_tokens += 1
}

private enum LlamaBackendRuntime {
    private static let initialization: Void = {
        llama_backend_init()
    }()

    static func ensureInitialized() {
        _ = initialization
    }
}

private func makeSampler() throws -> UnsafeMutablePointer<llama_sampler> {
    let parameters = llama_sampler_chain_default_params()

    guard let sampler = llama_sampler_chain_init(parameters) else {
        throw LlamaError.samplerInitializationFailed
    }

    guard let temperatureSampler = llama_sampler_init_temp(0.4) else {
        llama_sampler_free(sampler)
        throw LlamaError.samplerInitializationFailed
    }
    llama_sampler_chain_add(sampler, temperatureSampler)

    guard let distributionSampler = llama_sampler_init_dist(1234) else {
        // The chain owns temperatureSampler after it was added.
        llama_sampler_free(sampler)
        throw LlamaError.samplerInitializationFailed
    }
    llama_sampler_chain_add(sampler, distributionSampler)

    return sampler
}

enum LlamaCompletionStep {
    case token(String)
    case finished(CompletionTermination, trailingText: String)
}

actor LlamaContext {
    private var model: OpaquePointer
    private var context: OpaquePointer
    private var vocab: OpaquePointer
    private var sampling: UnsafeMutablePointer<llama_sampler>
    private var batch: llama_batch
    private var tokens_list: [llama_token]
    var is_done: Bool = false

    /// This variable is used to store temporarily invalid cchars
    private var temporary_invalid_cchars: [CChar]

    var n_len: Int32 = 1024
    var n_cur: Int32 = 0

    var n_decode: Int32 = 0

    init(
        model: OpaquePointer,
        context: OpaquePointer,
        sampling: UnsafeMutablePointer<llama_sampler>
    ) {
        self.model = model
        self.context = context
        self.tokens_list = []
        self.batch = llama_batch_init(
            Int32(MissionaryXLimits.promptBatchCapacity),
            0,
            1
        )
        self.temporary_invalid_cchars = []
        self.sampling = sampling
        vocab = llama_model_get_vocab(model)
    }

    deinit {
        llama_sampler_free(sampling)
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    static func create_context(path: String) throws -> LlamaContext {
        // Backend ownership is process-wide. Individual model contexts must not
        // free global backend state while another context exists or is loading.
        LlamaBackendRuntime.ensureInitialized()
        var model_params = llama_model_default_params()

#if targetEnvironment(simulator)
        model_params.n_gpu_layers = 0
        print("Running on simulator, force use n_gpu_layers = 0")
#endif
        let model = llama_model_load_from_file(path, model_params)
        guard let model else {
            throw LlamaError.modelFileLoadFailed
        }

        let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        print("Using \(n_threads) threads")

        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = 1024  // reduced from 2048 to lower KV cache memory on iPad
        ctx_params.n_threads       = Int32(n_threads)
        ctx_params.n_threads_batch = Int32(n_threads)

        let context = llama_init_from_model(model, ctx_params)
        guard let context else {
            llama_model_free(model)
            print("Could not load context!")
            throw LlamaError.contextInitializationFailed
        }

        do {
            let sampling = try makeSampler()
            return LlamaContext(
                model: model,
                context: context,
                sampling: sampling
            )
        } catch {
            llama_free(context)
            llama_model_free(model)
            throw error
        }
    }

    func model_info() -> String {
        let capacity = 1025
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: capacity)
        result.initialize(repeating: Int8(0), count: capacity)
        defer {
            result.deallocate()
        }

        _ = llama_model_desc(model, result, capacity - 1)
        result[capacity - 1] = 0
        return String(cString: result)
    }

    func get_n_tokens() -> Int32 {
        return batch.n_tokens;
    }

    func completion_init(
        text: String,
        maxTokens: Int,
        parseSpecialTokens: Bool = false
    ) throws {
        is_done = false
        let promptTokens = try tokenize(
            text: text,
            add_bos: true,
            parseSpecial: parseSpecialTokens
        )
        try TokenBudget.validate(
            promptTokens: promptTokens.count,
            requestedOutputTokens: maxTokens
        )

        try resetSampler()
        tokens_list = promptTokens
        temporary_invalid_cchars = []
        n_decode = 0
        llama_memory_clear(llama_get_memory(context), true)

        llama_batch_clear(&batch)

        for index in tokens_list.indices {
            try llama_batch_add(
                &batch,
                tokens_list[index],
                Int32(index),
                [0],
                false,
                capacity: MissionaryXLimits.promptBatchCapacity
            )
        }
        guard batch.n_tokens > 0 else {
            throw LlamaError.tokenizationFailed
        }
        batch.logits[Int(batch.n_tokens) - 1] = 1

        if llama_decode(context, batch) != 0 {
            throw LlamaError.decodeFailed
        }

        n_cur = batch.n_tokens
    }

    func completion_loop() throws -> LlamaCompletionStep {
        guard batch.n_tokens > 0 else {
            throw LlamaError.decodeFailed
        }

        if n_cur >= n_len {
            is_done = true
            return .finished(
                .contextLimit,
                trailingText: drainPendingText()
            )
        }

        let newToken = llama_sampler_sample(
            sampling,
            context,
            batch.n_tokens - 1
        )

        if llama_vocab_is_eog(vocab, newToken) {
            is_done = true
            return .finished(
                .endOfGeneration,
                trailingText: drainPendingText()
            )
        }

        let newTokenCharacters = try token_to_piece(token: newToken)
        temporary_invalid_cchars.append(contentsOf: newTokenCharacters)
        let newTokenString: String
        if let string = String(validatingUTF8: temporary_invalid_cchars + [0]) {
            temporary_invalid_cchars.removeAll()
            newTokenString = string
        } else if (0 ..< temporary_invalid_cchars.count).contains(where: {$0 != 0 && String(validatingUTF8: Array(temporary_invalid_cchars.suffix($0)) + [0]) != nil}) {
            let string = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            newTokenString = string
        } else {
            newTokenString = ""
        }

        llama_batch_clear(&batch)
        try llama_batch_add(
            &batch,
            newToken,
            n_cur,
            [0],
            true,
            capacity: MissionaryXLimits.promptBatchCapacity
        )

        n_decode += 1
        n_cur    += 1

        if llama_decode(context, batch) != 0 {
            throw LlamaError.decodeFailed
        }

        return .token(newTokenString)
    }

    func bench(pp: Int, tg: Int, pl: Int, nr: Int = 1) throws -> String {
        guard pp >= 1,
              pp <= MissionaryXLimits.promptBatchCapacity,
              pl >= 1,
              pl <= 1,
              tg >= 1,
              nr >= 1 else {
            throw MissionaryXAPIError.batchCapacityExceeded
        }

        var pp_avg: Double = 0
        var tg_avg: Double = 0

        var pp_std: Double = 0
        var tg_std: Double = 0

        for _ in 0..<nr {
            // bench prompt processing

            llama_batch_clear(&batch)

            let n_tokens = pp

            for i in 0..<n_tokens {
                try llama_batch_add(
                    &batch,
                    0,
                    Int32(i),
                    [0],
                    false,
                    capacity: MissionaryXLimits.promptBatchCapacity
                )
            }
            batch.logits[Int(batch.n_tokens) - 1] = 1

            llama_memory_clear(llama_get_memory(context), false)

            let t_pp_start = DispatchTime.now().uptimeNanoseconds / 1000;

            if llama_decode(context, batch) != 0 {
                throw LlamaError.decodeFailed
            }
            llama_synchronize(context)

            let t_pp_end = DispatchTime.now().uptimeNanoseconds / 1000;

            // bench text generation

            llama_memory_clear(llama_get_memory(context), false)

            let t_tg_start = DispatchTime.now().uptimeNanoseconds / 1000;

            for i in 0..<tg {
                llama_batch_clear(&batch)

                for j in 0..<pl {
                    try llama_batch_add(
                        &batch,
                        0,
                        Int32(i),
                        [Int32(j)],
                        true,
                        capacity: MissionaryXLimits.promptBatchCapacity
                    )
                }

                if llama_decode(context, batch) != 0 {
                    throw LlamaError.decodeFailed
                }
                llama_synchronize(context)
            }

            let t_tg_end = DispatchTime.now().uptimeNanoseconds / 1000;

            llama_memory_clear(llama_get_memory(context), false)

            let t_pp = Double(t_pp_end - t_pp_start) / 1000000.0
            let t_tg = Double(t_tg_end - t_tg_start) / 1000000.0

            let speed_pp = Double(pp)    / t_pp
            let speed_tg = Double(pl*tg) / t_tg

            pp_avg += speed_pp
            tg_avg += speed_tg

            pp_std += speed_pp * speed_pp
            tg_std += speed_tg * speed_tg

            print("pp \(speed_pp) t/s, tg \(speed_tg) t/s")
        }

        pp_avg /= Double(nr)
        tg_avg /= Double(nr)

        if nr > 1 {
            pp_std = sqrt(pp_std / Double(nr - 1) - pp_avg * pp_avg * Double(nr) / Double(nr - 1))
            tg_std = sqrt(tg_std / Double(nr - 1) - tg_avg * tg_avg * Double(nr) / Double(nr - 1))
        } else {
            pp_std = 0
            tg_std = 0
        }

        let model_desc     = model_info();
        let model_size     = String(format: "%.2f GiB", Double(llama_model_size(model)) / 1024.0 / 1024.0 / 1024.0);
        let model_n_params = String(format: "%.2f B", Double(llama_model_n_params(model)) / 1e9);
        let backend        = "Metal";
        let pp_avg_str     = String(format: "%.2f", pp_avg);
        let tg_avg_str     = String(format: "%.2f", tg_avg);
        let pp_std_str     = String(format: "%.2f", pp_std);
        let tg_std_str     = String(format: "%.2f", tg_std);

        var result = ""

        result += String("| model | size | params | backend | test | t/s |\n")
        result += String("| --- | --- | --- | --- | --- | --- |\n")
        result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | pp \(pp) | \(pp_avg_str) ± \(pp_std_str) |\n")
        result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | tg \(tg) | \(tg_avg_str) ± \(tg_std_str) |\n")

        return result;
    }

    func clear() {
        tokens_list.removeAll()
        temporary_invalid_cchars.removeAll()
        is_done = true
        n_cur = 0
        n_decode = 0
        llama_batch_clear(&batch)
        // Preserve the existing valid sampler if replacement allocation fails.
        try? resetSampler()
        llama_memory_clear(llama_get_memory(context), true)
    }

    private func resetSampler() throws {
        // Construct the replacement before releasing the current valid sampler.
        let replacement = try makeSampler()
        llama_sampler_free(sampling)
        sampling = replacement
    }

    private func drainPendingText() -> String {
        guard !temporary_invalid_cchars.isEmpty else {
            return ""
        }
        let text = String(
            validatingUTF8: temporary_invalid_cchars + [0]
        ) ?? ""
        temporary_invalid_cchars.removeAll()
        return text
    }

    private func tokenize(
        text: String,
        add_bos: Bool,
        parseSpecial: Bool
    ) throws -> [llama_token] {
        let utf8Count = text.utf8.count
        guard utf8Count <= Int(Int32.max) - 2 else {
            throw LlamaError.tokenizationFailed
        }
        var capacity = max(utf8Count + (add_bos ? 1 : 0) + 1, 8)

        while true {
            guard capacity <= Int(Int32.max) else {
                throw LlamaError.tokenizationFailed
            }
            let tokens = UnsafeMutablePointer<llama_token>.allocate(
                capacity: capacity
            )
            defer { tokens.deallocate() }

            let tokenCount = llama_tokenize(
                vocab,
                text,
                Int32(utf8Count),
                tokens,
                Int32(capacity),
                add_bos,
                parseSpecial
            )

            if tokenCount >= 0 {
                return (0..<Int(tokenCount)).map { tokens[$0] }
            }

            guard tokenCount != Int32.min else {
                throw LlamaError.tokenizationFailed
            }
            let requiredCapacity = -Int(tokenCount)
            guard requiredCapacity > capacity,
                  requiredCapacity <= Int(Int32.max) else {
                throw LlamaError.tokenizationFailed
            }
            capacity = requiredCapacity
        }
    }

    /// - note: The result does not contain null-terminator
    private func token_to_piece(token: llama_token) throws -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer {
            result.deallocate()
        }
        let nTokens = llama_token_to_piece(vocab, token, result, 8, 0, false)

        if nTokens < 0 {
            guard nTokens != Int32.min else {
                throw LlamaError.tokenizationFailed
            }
            let requiredCapacity = -Int(nTokens)
            let newResult = UnsafeMutablePointer<Int8>.allocate(
                capacity: requiredCapacity
            )
            newResult.initialize(
                repeating: Int8(0),
                count: requiredCapacity
            )
            defer {
                newResult.deallocate()
            }
            let nNewTokens = llama_token_to_piece(
                vocab,
                token,
                newResult,
                Int32(requiredCapacity),
                0,
                false
            )
            guard nNewTokens >= 0,
                  Int(nNewTokens) <= requiredCapacity else {
                throw LlamaError.tokenizationFailed
            }
            let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            guard nTokens <= 8 else {
                throw LlamaError.tokenizationFailed
            }
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
}
