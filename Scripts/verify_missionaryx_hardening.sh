#!/usr/bin/env bash
set -euo pipefail

readonly FEATURE_BRANCH="feature/crucible-reliability-hardening-v0-2"
readonly READINESS_FIX_BRANCH="feature/crucible-readiness-device-fix-v0-2-1"
readonly REQUIRED_ANCESTOR="db7c040250e62bec1a5ef2717163999595ee71be"
readonly REQUIRED_LLAMA="4d828bd1ab52773ba9570cc008cf209eb4a8b2f5"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

failures=0

pass() {
    printf 'PASS: %s\n' "$1"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

require_fixed() {
    local needle="$1"
    local file="$2"
    local description="$3"
    if grep -Fq -- "$needle" "$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

reject_fixed() {
    local needle="$1"
    local path="$2"
    local description="$3"
    if grep -R -Fq --exclude-dir=.git -- "$needle" "$path"; then
        fail "$description"
    else
        pass "$description"
    fi
}

actual_branch="${GITHUB_REF_NAME:-$(git branch --show-current)}"
if [[ "$actual_branch" == "$FEATURE_BRANCH"
    || "$actual_branch" == "$READINESS_FIX_BRANCH"
    || "$actual_branch" == "master" ]]; then
    pass "supported validation branch"
else
    fail "supported validation branch"
fi

if git merge-base --is-ancestor "$REQUIRED_ANCESTOR" HEAD; then
    pass "required starting commit remains an ancestor"
else
    fail "required starting commit remains an ancestor"
fi

actual_llama="$(git -C llama.cpp rev-parse HEAD)"
if [[ "$actual_llama" == "$REQUIRED_LLAMA" ]]; then
    pass "llama.cpp submodule revision is pinned"
else
    fail "llama.cpp submodule revision is pinned"
fi

if git diff --check; then
    pass "git diff has no whitespace errors"
else
    fail "git diff has no whitespace errors"
fi

if git diff "$REQUIRED_ANCESTOR"...HEAD --check; then
    pass "committed feature diff has no whitespace errors"
else
    fail "committed feature diff has no whitespace errors"
fi

readonly core="Sources/MissionaryXCore/MissionaryXCore.swift"
readonly llama="llama.cpp.swift/LibLlama.swift"
readonly server="llama.swiftui/HTTPServer.swift"
readonly state="llama.swiftui/Models/LlamaState.swift"

require_fixed "public static let promptBatchCapacity = 512" "$core" \
    "batch capacity is explicit"
require_fixed "public static let maximumPromptTokens = 384" "$core" \
    "prompt-token hard limit is 384"
require_fixed "public static let maximumOutputTokens = 128" "$core" \
    "output-token hard limit is 128"
require_fixed "try TokenBudget.validate(" "$llama" \
    "exact tokenizer output is budget-checked"
require_fixed "case modelFileLoadFailed" "$llama" \
    "model-file load failure has a distinct error case"
require_fixed "case contextInitializationFailed" "$llama" \
    "context initialization failure has a distinct error case"
require_fixed "MODEL_FILE_LOAD_FAILED: llama_model_load_from_file returned nil" "$llama" \
    "model-file load failure has a deterministic diagnostic"
require_fixed "CONTEXT_INITIALIZATION_FAILED: llama_init_from_model returned nil" "$llama" \
    "context initialization failure has a deterministic diagnostic"
reject_fixed "couldNotInitializeContext" "$llama" \
    "ambiguous model/context initialization error is absent"
require_fixed "parseSpecialTokens: true" "$state" \
    "API ChatML delimiters are parsed as model special tokens"
require_fixed "modelUrl.path(percentEncoded: false)" "$state" \
    "local model URL is converted to a decoded filesystem path"
reject_fixed "let modelPath = modelUrl.path()" "$state" \
    "percent-encoded filesystem path conversion is absent"
require_fixed "try BatchCapacityGuard.validate(" "$llama" \
    "every llama_batch_add starts with a defensive index guard"

guard_line="$(grep -n -F 'try BatchCapacityGuard.validate(' "$llama" | head -1 | cut -d: -f1)"
write_line="$(grep -n -F 'batch.token[nextIndex] = id' "$llama" | head -1 | cut -d: -f1)"
if [[ -n "$guard_line" && -n "$write_line" && "$guard_line" -lt "$write_line" ]]; then
    pass "batch capacity guard precedes the first batch write"
else
    fail "batch capacity guard precedes the first batch write"
fi

direct_token_writes="$(grep -R -F 'batch.token[' --exclude-dir=llama.cpp --include='*.swift' . | wc -l | tr -d ' ')"
if [[ "$direct_token_writes" == "1" ]]; then
    pass "all Swift token-array writes use the guarded helper"
else
    fail "all Swift token-array writes use the guarded helper"
fi

reject_fixed "llama_backend_free" "llama.cpp.swift" \
    "per-context destruction cannot free the process backend"
backend_init_count="$(grep -R -F 'llama_backend_init()' --include='*.swift' llama.cpp.swift | wc -l | tr -d ' ')"
if [[ "$backend_init_count" == "1" ]]; then
    pass "llama backend initialization has one process owner"
else
    fail "llama backend initialization has one process owner"
fi

require_fixed "llama_sampler_init_temp(0.4)" "$llama" \
    "sampler temperature remains 0.4"
require_fixed "llama_sampler_init_dist(1234)" "$llama" \
    "sampler seed remains 1234"
sampler_reset_count="$(grep -F 'resetSampler()' "$llama" | wc -l | tr -d ' ')"
if [[ "$sampler_reset_count" -ge 3 ]]; then
    pass "sampler is reset for initialization and cleanup"
else
    fail "sampler is reset for initialization and cleanup"
fi

require_fixed "private let operationGate = WorkerOperationGate()" "$state" \
    "one explicit whole-worker operation gate exists"
require_fixed "operationGate.owns(lease)" "$state" \
    "API inference requires ownership of the exact lease"
require_fixed "try await operationGate.withLease(.inference)" "$state" \
    "API inference acquires and automatically releases the gate"
require_fixed "guard let lease = operationGate.tryAcquire(.modelLoad)" "$state" \
    "model replacement must acquire the same gate"
require_fixed "public func withLease<T>(" "$core" \
    "single-flight execution seam releases ownership on every exit"

require_fixed "public static let modelNotLoaded" "$core" \
    "no-model error has structured API semantics"
require_fixed "statusCode: 503," "$core" \
    "service-unavailable status is represented"
reject_fixed "Error: No model loaded" "llama.swiftui" \
    "no-model state cannot become assistant text"
require_fixed "self.data = model.map" "$core" \
    "models list is derived from optional live metadata"
require_fixed 'case "/health":' "$server" \
    "liveness endpoint exists"
require_fixed 'case "/ready":' "$server" \
    "readiness endpoint exists"
require_fixed "WorkerReadinessSnapshot(" "$state" \
    "readiness is derived from model and live operation state"
require_fixed "HTTPServerActiveConfiguration<LlamaState>()" "$server" \
    "active listener configuration strongly owns its live worker"
reject_fixed "private weak var llamaState" "$server" \
    "active listener worker cannot disappear through weak zeroing"
require_fixed "ReadinessEndpointResult(snapshot: snapshot)" "$server" \
    "live readiness route uses the tested endpoint projection"
require_fixed 'case modelLoading = "model_loading"' "$core" \
    "readiness distinguishes model loading"
require_fixed 'case busy' "$core" \
    "readiness distinguishes busy operation state"

require_fixed "BearerAuthenticator.validate(" "$server" \
    "bearer authentication gates routed endpoints"
require_fixed "kSecAttrAccessibleWhenUnlockedThisDeviceOnly" \
    "llama.swiftui/APIKeyStore.swift" \
    "the configured credential is device-only in Keychain"
reject_fixed "Access-Control-Allow-Origin" "llama.swiftui" \
    "wildcard CORS is absent"
reject_fixed "Authorization:" "llama.swiftui" \
    "source contains no logged or reflected Authorization header"

require_fixed "maximumBodyBytes = 16 * 1024" "$core" \
    "HTTP body maximum is 16 KiB"
require_fixed 'headers["transfer-encoding"] != nil' "$core" \
    "Transfer-Encoding fails closed"
require_fixed "receivedBodyBytes < head.contentLength" "$core" \
    "fragmented bodies wait for complete Content-Length"
require_fixed 'header += "Connection: close' "$server" \
    "responses explicitly close connections"

require_fixed 'rawDictionary["messages"] != nil' "$core" \
    "messages is mandatory"
require_fixed 'role == "system" || role == "user"' "$core" \
    "only bounded roles are accepted"
require_fixed 'private static let forbiddenContent' "$core" \
    "reserved content has an explicit denylist"
require_fixed '"<|im_start|>"' "$core" \
    "ChatML start delimiter is rejected"
require_fixed '"<|im_end|>"' "$core" \
    "ChatML end delimiter is rejected"
require_fixed '"\0"' "$core" \
    "NUL is rejected"
require_fixed "if stream {" "$core" \
    "stream true is explicitly rejected"
require_fixed 'model == "local"' "$core" \
    "model routing is constrained to local"

require_fixed "case .endOfGeneration:" "$core" \
    "EOG maps separately from bounded termination"
require_fixed "case .maximumTokens, .contextLimit:" "$core" \
    "token and context exhaustion map to length"
require_fixed "throw MissionaryXAPIError.incompleteReasoning" "$core" \
    "incomplete think blocks fail explicitly"

reject_fixed 'print("Prompt' "llama.swiftui" \
    "full prompts are not printed"
reject_fixed 'print(newToken' "llama.swiftui" \
    "generated token pieces are not printed"
reject_fixed 'print(result)' "llama.cpp.swift" \
    "generated completions are not printed by the llama wrapper"

require_fixed "INFOPLIST_KEY_NSLocalNetworkUsageDescription" \
    "llama.swiftui.xcodeproj/project.pbxproj" \
    "local-network privacy usage text is configured"
reject_fixed "UIBackgroundModes" "llama.swiftui.xcodeproj" \
    "no background mode was added"

if [[ "$failures" -ne 0 ]]; then
    printf '%s source verification check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'All MissionaryX hardening source checks passed\n'
