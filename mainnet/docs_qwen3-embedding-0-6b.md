# `qwen3-embedding-0-6b` — Connection Guide

| | |
|---|---|
| Service ID | `qwen3-embedding-0-6b` |
| Transport | `REST` (HTTP/1.1 and HTTP/2) |
| Expected endpoints | `POST /v1/embeddings`, `GET /v1/models`|
| Model name (wire) | `pocket_network` |
| Model (weights) | [`Qwen/Qwen3-Embedding-0.6B`](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B) |
| Response determinism | **Variable** — same weights, but not bit-identical |

> Embedding dimensions and maximum input length are properties of the model, not of this
> service. Take them from the model card linked above rather than from this document.

---

## The API contract

`qwen3-embedding-0-6b` speaks the **OpenAI Embeddings API**. Request and response shapes,
field names and error envelopes follow the OpenAI specification — we deliberately do not
restate them here. Refer to the upstream reference:

- <https://platform.openai.com/docs/api-reference/embeddings>

### What is expected

Two endpoints:

```
POST /v1/embeddings     # inference
GET  /v1/models         # discovery
```

`/v1/models` exists so that OpenAI SDKs and gateways which probe for capability at startup
do not fail outright. It will report exactly one entry, `pocket_network`.

### What is not

Everything else. A supplier **MAY** expose `/v1/rerank` or any other
part of the OpenAI surface, and some will. Consumers **MUST NOT** depend on it. Any request
outside the two endpoints above can fail, 404, or behave differently from one supplier to the
next, and that is not a fault — it is the contract.

Note that "expected" is exactly as strong as it sounds. It is the service owner's stated
intention, enforced by no layer of the protocol: nothing checks it at stake time, nothing
checks it at relay time, and a supplier serving only `/v1/embeddings` is a valid supplier who
will be paid normally. Handle a 404 on `/v1/models` gracefully rather than treating it as a
broken supplier.

### The model name

Address the model as **`pocket_network`** on the wire, always:

```json
{"model": "pocket_network", "input": "the quick brown fox"}
```

This is the same stable alias used across Pocket services, and it is a *routing* name, not a
model identifier. What makes this service different from an open-model service is that the
weights behind the alias **are** specified: `Qwen/Qwen3-Embedding-0.6B`, for every supplier.
Naming the upstream model directly (`qwen3-embedding-0.6b`, `Qwen/Qwen3-Embedding-0.6B`) is
not portable and suppliers are free to reject it.

---

## For applications

### Vectors are comparable across suppliers — but not identical

This is the single most important thing for an application developer to internalise, and it
is the opposite of the usual warning about open-model services.

Because every supplier serves the same specified weights, two suppliers embedding the same
text return vectors that mean the same thing: cosine similarity between them will be very
close to 1, and mixing them in one index is *viable*. That is the whole point of pinning the
model for this service.

What you do **not** get is bit-identical output. Floating-point results vary with GPU vs CPU,
`fp16` vs `bf16` vs `fp32`, kernel and library versions, and batch composition. So:

- **Do not** treat an embedding as a cache key, or compare vectors for exact equality.
- **Do not** assume a vector you stored last month reproduces byte-for-byte today, even from
  the same supplier.
- **Do** expect tiny cosine drift between suppliers. Measure it before you rely on it: embed
  a fixed probe set through several suppliers and look at the spread.
- **Do** re-embed a whole corpus with one consistent path if you need exactness — for example
  for deduplication by vector identity, which this service cannot support.

`results` is `variable` on this service's card for precisely this reason. It is a weaker claim
than the reality (same model, close vectors) because the card vocabulary has no value for
"same weights, different arithmetic", and overclaiming `deterministic` would license exact
caching and cross-checking that will break.

### Batch warning

`compute_units_per_relay` for this service is **10000**, charged per *relay*, not per input.
A request carrying 64 inputs costs the same as a request carrying 1:

```json
{"model": "pocket_network", "input": ["first text", "second text", "third text"]}
```

Batching is therefore the single biggest lever on your cost per embedded document. The limits
are practical rather than protocol-level: request body size, backend memory, and gateway
timeouts. 

Some providers can choose to refuse your request if the batch is too big, in practice the only
**expected batch size is 1**, but suppliers MIGHT allow for more. 

### Client

Use the Pocket application client to talk to the network:

- **<https://github.com/pokt-network/pocket-ap>**

### Example

```bash
curl -sS "<GATEWAY_URL>/v1/embeddings" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <GATEWAY_API_KEY>" \
  -d '{
    "model": "pocket_network",
    "input": ["Pocket Network is a decentralized API layer."]
  }' | jq '.data | length, .data[0].embedding | length'
```

### What the protocol does and does not assure

The only assurance layer on this service is Pocket Network's **crypto-economic incentive**:
suppliers post stake, are paid for provably served relays, and are slashed for provable
protocol faults. That secures *service delivery* — that someone answered, in the right wire
format, and can be held accountable for failing to.

It does **not** verify which model produced a vector. A supplier serving a different embedding
model, a quantized variant, or a different pooling strategy will still be paid, and nothing on
chain detects it. The specified weights are an owner assertion, like every other field on the
card — per the card rules, no field is chain-verified.

Practically, that means a misconfigured supplier degrades your retrieval quality silently.
Probe for it: embed a fixed text set periodically and alert on cosine drift against a known
baseline. 

---

## For suppliers

### Choose an embeddings server with dynamic batching

Serve with a backend that coalesces many concurrent requests, and many inputs per request,
into efficient batches. Embedding traffic is high-volume and small-payload so batching 
throughput matters more than per-request latency.

Recommended, in order:

| Server | Notes |
|---|---|
| **[Text Embeddings Inference (TEI)](https://github.com/huggingface/text-embeddings-inference)** | Recommended default. Purpose-built for embedding models, dynamic batching, OpenAI-compatible `/v1/embeddings`. |
| [vLLM](https://github.com/vllm-project/vllm) | Run with `--task embed`. Good if you already operate vLLM for other Pocket services. |

### Serve the specified weights, unmodified

This service names its model. Do not substitute another embedding model, and be conservative
with anything that changes the numerics:

- No swapping in a different or fine-tuned model.
- No aggressive quantization. `fp16`/`bf16` is normal; int8 and below shift vectors enough to
  matter for retrieval.
- No changing the pooling strategy or normalization from the model's default.

Nothing on chain checks any of this, which is exactly why it matters: a supplier who drifts
from the specified weights is silently degrading every index built on this service, and will
keep being paid while doing it.

### Alias your model as `pocket_network`

Requests arrive with `"model": "pocket_network"`. Your server must accept that name. With TEI:

```bash
text-embeddings-router \
  --model-id Qwen/Qwen3-Embedding-0.6B \
  --served-model-name pocket_network \
  --hostname 0.0.0.0 --port 8080
```

With vLLM:

```bash
vllm serve Qwen/Qwen3-Embedding-0.6B \
  --task embed \
  --served-model-name pocket_network \
  --host 0.0.0.0 --port 8000
```

A server that rejects `pocket_network` fails every relay it receives.

### Isolate the model behind the ML sidecar

Do not expose your inference server to relay traffic directly. Put it behind the ML sidecar,
which isolates the model from the relay path:

- **<https://github.com/pnyxai/pokt-ml-sidecar>**

### Front it with the HA RelayMiner

The high-availability RelayMiner is still the right
front end for a high-request-rate service like this one:

- **<https://github.com/pokt-network/pocket-relay-miner>**

### RelayMiner configuration

`qwen3-embedding-0-6b` declares `REST` in its card, which maps directly onto the RelayMiner
config key by lower-casing the on-chain `RPCType` enum name:

```yaml
suppliers:
  - service_id: qwen3-embedding-0-6b
    listen_url: http://0.0.0.0:8545
    service_config:
      backend_url: http://pokt-ml-sidecar:9000    # sidecar, not TEI/vLLM directly
    rpc_type_service_configs:
      rest:                                       # card: {"type": "REST", "intent": "expected"}
        backend_url: http://pokt-ml-sidecar:9000
```

Point `backend_url` at the sidecar. The sidecar owns the connection to your inference server.

### Verify before you stake

The card ships a healthcheck probe. Run its equivalent against your own stack first — a
failing backend discovered from missed relays is an expensive way to learn:

```bash
curl -sS "http://localhost:8080/v1/embeddings" \
  -H "Content-Type: application/json" \
  -d '{"model":"pocket_network","input":"pocket network embedding healthcheck"}' \
  | jq -r '.data[0].object'
# expect: embedding
```

Then confirm the vector length matches the model card, and repeat the call with a batch of
inputs through the sidecar and the RelayMiner — not just against TEI — checking that you get
one entry back per input, in order.
