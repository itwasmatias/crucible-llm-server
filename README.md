# CrucibleLLM

Run custom GGUF language models locally on iPad and iPhone. Serve them through an OpenAI-compatible HTTP API. No cloud, no subscription, no data leaves your device.

## Features

- **Local inference** — runs GGUF models on-device with Metal GPU acceleration via llama.cpp
- **OpenAI-compatible API** — serves `/v1/chat/completions` so any client that speaks OpenAI can talk to your iPad
- **HuggingFace downloads** — browse and download models directly in the app
- **Server mode** — toggle the HTTP server on/off, see your IP and port in the UI
- **Default models** — ships with Gemma 3 4B and Qwen 3.5 4B in the download list
- **Zero cloud** — your model, your device, your data

## Quick Start

1. Sideload `CrucibleLLM.ipa` via [AltStore](https://altstore.io/) or [AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux)
2. Open the app, go to **View Models**, download a model (or paste a HuggingFace GGUF URL)
3. Tap the model to load it
4. Configure a 16–256 byte API key in the app
5. Tap **Start Server**
6. Wait for the UI status to change from `starting` to `listening`; only then is
   the address accepting connections

## API Usage

```bash
curl http://YOUR_IPAD_IP:8080/v1/chat/completions \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [
      {"role": "system", "content": "Be concise."},
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "max_tokens": 100
  }'
```

Point an OpenAI-compatible client at `http://YOUR_IPAD_IP:8080` as the base URL
and configure the same bearer key. Crucible implements the bounded subset below;
clients that require streaming, tools, sampling controls, or assistant messages
in request history are not compatible with this milestone.

## Reliability Contract

All routes except `OPTIONS` require `Authorization: Bearer YOUR_API_KEY`.

- `GET /health` is liveness only. A `200 {"status":"ok"}` means the listener
  accepted and routed the request; it does not mean a model is loaded.
- `GET /ready` is inference readiness. It returns `200` with `status: ready`
  only when a model/context exists and no model operation owns the worker.
  `model_not_loaded` and `model_loading` return `503`; `busy` returns `409` and
  identifies the active operation.
- At most one inference, model load, benchmark, or maintenance operation owns
  the llama.cpp model/context at once. There is no request queue. A competing
  chat request receives `409 worker_busy` immediately, and a later request may
  proceed after ownership is released. Ownership is released on both success
  and inference failure.
- The server accepts one HTTP/1.1 request per connection and always closes the
  connection. POST requests require one valid `Content-Length`. Headers and
  bodies may arrive in multiple receives. Duplicate framing, premature EOF,
  bytes beyond `Content-Length`, and malformed header syntax are rejected.
  `Transfer-Encoding`, including chunked encoding, is unsupported and rejected.
- The maximum header section is 8 KiB (not including the final `\r\n\r\n`).
  The maximum body is 16 KiB. The exact limits are accepted; one byte over is
  rejected without truncation. Rejected requests do not enter inference.
- `/v1/chat/completions` accepts 1–8 `system`/`user` messages, at most one
  leading system message, and string content up to 4 KiB per message. Reserved
  ChatML delimiters and NUL are rejected. `max_tokens` is a required integer
  from 1–128; `model`, if supplied, must be `local`.
- The rendered ChatML prompt is tokenized by the loaded llama.cpp vocabulary
  before decode. Prompts are limited to 384 actual tokens and prompt plus output
  budget to 512 tokens, matching the 512-token prompt batch. No content is
  silently truncated. The llama context remains 1,024 tokens; the smaller
  server budget is intentional headroom.
- Streaming is not implemented. `stream: true` returns a deterministic client
  error; `stream: false` and omission use a single JSON response.

The Network.framework listener uses the device's interfaces and is reachable on
the local network at the address shown by the app. Crucible does not add TLS,
internet exposure, tunneling, or an authentication platform. Treat the local
network and bearer key as the trust boundary; do not port-forward this listener.

## Building from Source

The app builds on GitHub Actions using a macOS runner with Xcode:

1. Fork this repo
2. Push to trigger the `Build iOS IPA` workflow
3. Download the IPA artifact from the Actions run
4. Sideload to your device via AltStore

The workflow builds the llama.cpp xcframework from source, then compiles the iOS app. No local macOS machine needed.

## Known Limitations

- **Memory pressure** — iPads with 8GB RAM can crash on long prompts with large models. Use Q4_K_M quantization and keep context sizes reasonable.
- **Foreground only** — iOS suspends background apps. Crucible deliberately
  stops the listener when the app enters the background; return to the app and
  tap **Start Server** again. The loaded model is not deliberately unloaded by
  that transition.
- **Single flight** — concurrent operations are rejected; they do not queue.
- **No streaming or persistent HTTP** — responses are complete JSON documents,
  one request per connection.
- **No cloud/device claim from unit tests** — Swift package tests cover parsing,
  validation, readiness projection, and ownership. Xcode compilation, Metal,
  memory stability, signing, installation, and actual iPhone lifecycle behavior
  require the device procedure below.

## Real iPhone Acceptance — v0.2

Run this after producing and installing an IPA with Apple/Xcode tooling. It is a
manual device gate, not something Linux Swift tests can satisfy. Keep the iPhone
awake, on the same trusted Wi-Fi as the client machine, and substitute the three
shell variables:

```bash
CRUCIBLE_URL=http://YOUR_IPHONE_IP:8080
CRUCIBLE_KEY='YOUR_API_KEY'
AUTH="Authorization: Bearer $CRUCIBLE_KEY"
```

1. Open Crucible, configure the key, and start the server before loading a
   model. Wait for `listening`. Verify liveness succeeds and readiness is
   unavailable:

   ```bash
   curl -i -H "$AUTH" "$CRUCIBLE_URL/health"
   curl -i -H "$AUTH" "$CRUCIBLE_URL/ready"
   ```

   Expect `200 status=ok`, then `503 status=model_not_loaded`.

2. Load the known-working GGUF model. During loading, `/ready` may report
   `503 status=model_loading`; after the UI reports the model loaded, require
   `200 status=ready`.

3. Send a normal request and require a `200` assistant response:

   ```bash
   curl -i "$CRUCIBLE_URL/v1/chat/completions" \
     -H "$AUTH" -H 'Content-Type: application/json' \
     --data '{"model":"local","messages":[{"role":"user","content":"Reply exactly DEVICE-OK"}],"max_tokens":16,"stream":false}'
   ```

4. Start a generation long enough to overlap, then poll `/ready` until it
   returns `409 status=busy`. While it is busy, send the same valid chat request
   from a second terminal. Require `409 worker_busy`; it must not wait in a
   queue. After the first request completes, require `/ready` to return `200`
   and send a third request; it must succeed.

5. Send malformed JSON, then immediately repeat the valid request from step 3:

   ```bash
   curl -i "$CRUCIBLE_URL/v1/chat/completions" \
     -H "$AUTH" -H 'Content-Type: application/json' \
     --data-binary '{"messages":'
   ```

   Require a `400 malformed_json`; the following valid request must still work.

6. From a client with Python 3, send a body one byte over the 16 KiB limit and
   require `413 payload_too_large`, then verify another normal request succeeds:

   ```bash
   python3 -c 'import sys; sys.stdout.write("x" * (16 * 1024 + 1))' | \
     curl -i "$CRUCIBLE_URL/v1/chat/completions" \
     -H "$AUTH" -H 'Content-Type: application/json' --data-binary @-
   ```

7. With the server listening, background Crucible. Confirm the UI no longer
   advertises a listener and the old URL is unreachable. Foreground the app,
   confirm the model state is truthful, restart the server, require `/ready` to
   return `200`, and run one more inference.

8. Run **Bench** and inspect the device/Xcode console for the repository's
   existing llama.cpp/Metal runtime diagnostics. Observe memory pressure,
   thermal behavior, and app stability through the overlapping, malformed,
   oversized, and background/foreground checks. Record the device model, iOS
   version, GGUF filename/hash, IPA commit, and results; do not infer a Metal or
   stability pass merely from a successful HTTP response.

## Architecture

- Swift + SwiftUI frontend
- llama.cpp via xcframework for inference (Metal-accelerated)
- Network.framework HTTP server (no external dependencies)
- ChatML prompt formatting with `/no_think` support for reasoning models

## Created By

[Crucible](https://github.com/vidaliya) — built on a Tuesday because we needed an iOS Ollama and nobody had made one.

## License

MIT
