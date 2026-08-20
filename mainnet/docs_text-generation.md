# `text-generation` — Connection Guide

Canonical connection documentation for the Pocket Network `text-generation` service managed by `PNYX`.
This document is pinned by the service's on-chain card (`specs[0]`).

| | |
|---|---|
| Service ID | `text-generation` |
| Transport | `REST` (HTTP/1.1 and HTTP/2) |
| Expected endpoints | `POST /v1/chat/completions`, `GET /v1/models`|
| Model name | `pocket_network` |
| Response determinism | **Variable** — suppliers run different models |

---

## The API contract

`text-generation` speaks the **OpenAI Chat Completions API**. Request and response shapes,
field names, error envelopes and streaming semantics all follow the OpenAI specification —
we deliberately do not restate them here. Refer to the upstream reference:

- <https://platform.openai.com/docs/api-reference/chat>

### What is expected

Two endpoints:

```
POST /v1/chat/completions     # inference
GET  /v1/models               # discovery
```

`/v1/models` exists so that OpenAI SDKs and gateways which probe for capability at startup
do not fail outright. It will report at least one entry, `pocket_network`. Do not read it as a
menu — there should be nothing to choose between, and the name it returns tells you nothing about
which weights are behind it (none can enforce them).

### What is not

Everything else. A supplier **MAY** expose `/v1/completions`, `/v1/responses` or any other part of the OpenAI surface
related to `text-generation`, and some will. Consumers **MUST NOT** depend on it.
Any request outside the two endpoints above can fail, 404, or behave differently from one
supplier to the next, and that is not a fault — it is the contract.

Note that "expected" is exactly as strong as it sounds. It is the service owner's stated
intention, enforced by no layer of the protocol: nothing checks it at stake time, nothing
checks it at relay time, and a supplier serving only `/v1/chat/completions` is a valid
supplier who will be paid normally. Handle a 404 on `/v1/models` gracefully rather than
treating it as a broken supplier.

Practical consequences:

- Do not rely on the legacy `/v1/completions` endpoint.
- Do not branch application logic on the contents of `/v1/models`.

### The model name

Address the model as **`pocket_network`**, always:

```json
{"model": "pocket_network", "messages": [{"role": "user", "content": "Hello"}]}
```

This is a stable alias, not a model identifier. It does **not** tell you which weights answered
your request — a single logical service name is what makes suppliers interchangeable at the
routing layer. Naming a specific upstream model (`llama-3.1-70b`, `gpt-4o`, …) is not portable
and suppliers are free to ignore it.

---

## For applications

### Streaming

Streaming is standard OpenAI SSE: set `"stream": true` on the same `POST`, and read
`data:` frames terminated by `data: [DONE]`. It is **not** a separate transport, and there is
no websocket endpoint.

Relaying SSE through a decentralized network is the part that needs help. Use the
Pocket application client, which handles streamed responses end to end:

- **<https://github.com/pokt-network/pocket-ap>**

Rolling your own HTTP path works for non-streaming calls, but you will have to solve
chunk-boundary handling, mid-stream supplier failure and partial-response accounting
yourself. Start with `pocket-ap`.

### Non-streaming example

```bash
curl -sS "<GATEWAY_URL>/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <GATEWAY_API_KEY>" \
  -d '{
    "model": "pocket_network",
    "messages": [{"role": "user", "content": "Explain Pocket Network in one sentence."}],
    "max_tokens": 256,
    "temperature": 0.7
  }'
```

### Streaming example

```bash
curl -sSN "<GATEWAY_URL>/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <GATEWAY_API_KEY>" \
  -d '{
    "model": "pocket_network",
    "messages": [{"role": "user", "content": "Count to five."}],
    "stream": true
  }'
```

### Model quality is not guaranteed

This is the single most important thing for an application developer to internalise.

The only assurance layer on this service is Pocket Network's **crypto-economic incentive**:
suppliers post stake, are paid for provably served relays, and are slashed for provable
protocol faults. That secures *service delivery* — that someone answered, in the right wire
format, and can be held accountable for failing to. It says nothing whatsoever about the
model behind the answer.

There is no attestation registry, no model whitelist, no minimum benchmark to stake, no
on-chain quality check, and no penalty for serving a small or badly-tuned model. `results`
is `variable` on this service's card for exactly this reason:

- Two suppliers can return materially different answers to the same prompt. Both are valid.
- You cannot retry across suppliers expecting an equivalent response.
- You cannot cache one supplier's response as another's.
- You cannot cross-check suppliers against each other to detect faults.

Nothing in the card changes this, and you should be suspicious of any card field that
appears to promise otherwise — per the card rules, no field is chain-verified and every
value is the owner's assertion.

If your application needs a known quality floor, you must measure it yourself or select
suppliers deliberately. For independent evaluation of the models currently staked on this
service, see:

- **<https://pnyxai.com/leaderboard>**

Treat that as the starting point for supplier selection, not as a protocol guarantee.

---

## For suppliers

### Choose an inference server with continuous batching

Serve with a backend that handles **many simultaneous generations on one model instance**.
Relay traffic is concurrent and bursty; a server that processes one prompt at a time will
queue, blow past gateway latency budgets, and earn you far less than the hardware allows.

Recommended, in order:

| Server | Notes |
|---|---|
| **[vLLM](https://github.com/vllm-project/vllm)** | Recommended default. Continuous batching, paged attention, OpenAI-compatible server built in. |
| [SGLang](https://github.com/sgl-project/sglang) | Comparable throughput, strong on structured output. |
| [TGI](https://github.com/huggingface/text-generation-inference)  | Viable alternative. |

Single-stream servers (`ollama`, a bare `llama.cpp` server) will technically answer relays
and are a reasonable way to smoke-test your setup, but they are not appropriate for
production staking on this service.

### Alias your model as `pocket_network`

Requests arrive with `"model": "pocket_network"`. Your server must accept that name
regardless of which weights you actually run. With vLLM:

```bash
vllm serve <YOUR_MODEL_REPO_OR_PATH> \
  --served-model-name pocket_network \
  --host 0.0.0.0 --port 8000
```

A server that rejects `pocket_network` fails every relay it receives.

### Isolate the model behind the ML sidecar

Do not expose your inference server to relay traffic directly. Put it behind the ML sidecar,
which isolates the model from the relay path:

- **<https://github.com/pnyxai/pokt-ml-sidecar>**

This is optional but covers some friction in exposing the model to the internet and through the Pocket Network.

### Serve SSE through the HA RelayMiner

Streaming responses need a RelayMiner build that supports SSE. Use the high-availability
RelayMiner:

- **<https://github.com/pokt-network/pocket-relay-miner>**

A RelayMiner without SSE support will fail or truncate every `"stream": true` request, which
is a large fraction of real traffic on this service.

### RelayMiner configuration

`text-generation` declares `REST` in its card, which maps directly onto the RelayMiner config
key by lower-casing the on-chain `RPCType` enum name:

```yaml
suppliers:
  - service_id: text-generation
    listen_url: http://0.0.0.0:8545
    service_config:
      backend_url: http://pokt-ml-sidecar:9000    # sidecar, not vLLM directly
    rpc_type_service_configs:
      rest:                                       # card: {"type": "REST", "intent": "expected"}
        backend_url: http://pokt-ml-sidecar:9000
```

Point `backend_url` at the sidecar. The sidecar owns the connection to your inference server.

### Verify before you stake

The card ships a healthcheck probe. Run its equivalent against your own stack first — a
failing backend discovered from missed relays is an expensive way to learn:

```bash
curl -sS "http://localhost:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"pocket_network",
       "messages":[{"role":"user","content":"Reply with the single word: pong"}],
       "temperature":0}' \
  | jq -r '.choices[0].message.content'
# expect: pong
```

Then repeat it with `"stream": true` and confirm you receive incremental `data:` frames
followed by `data: [DONE]`, through the sidecar and the RelayMiner — not just against vLLM.

