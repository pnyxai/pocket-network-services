# `image-prompt-injection-detection` — Connection Guide

Canonical connection documentation for the Pocket Network `image-prompt-injection-detection` service managed by `PNYX`.
This document is pinned by the service's on-chain card (`specs[0]`).

| | |
|---|---|
| Service ID | `image-prompt-injection-detection` |
| Transport | `REST` (HTTP/1.1 and HTTP/2) |
| Expected endpoints | `POST /v1/inspect`, `GET /readyz` |
| Response determinism | **Variable** — suppliers run different OCR and classifier models |

> This service asks whether an image carries **instructions aimed at the next model that reads it**:
> text painted into the pixels, hidden text (alpha channel, near-white-on-white, low bit plane),
> image-scaling attacks, plus everything `image-container-screening` finds. Adversarial-perturbation
> attacks (optimised noise against a specific vision model) are **not** covered.

---

## The API contract

`image-prompt-injection-detection` speaks the **image-forensics `/v1/inspect` API**. Request and
response shapes, field names and error envelopes are defined by its OpenAPI 3.1 document, pinned
by this service's card (`specs[1]`) — we deliberately do not restate all of it here:

- <https://github.com/RawthiL/image-forensics-service/blob/main/docs/openapi.json>

### What is expected

Two endpoints:

```
POST /v1/inspect   # inspect one image
GET  /readyz       # readiness probe
```

`POST /v1/inspect` accepts `multipart/form-data` with **exactly one** of:

| Field | Type | Notes |
|---|---|---|
| `media` | file | Image upload. JPEG, PNG, WebP, BMP, TIFF, MPO. Send the original bytes. |
| `media_base64` | string | Alternative to `media`: base64 string or `data:` URI. |
| `url` | string | `http(s)` URL to fetch. **Off by default** on suppliers; do not depend on it. |

A successful response:

```json
{
  "scope": "image",
  "verdict": "malicious",
  "injection": 1.0,
  "severity": "high",
  "findings": [
    {"kind": "scaling_attack", "severity": "high", "score": 1.0,
     "where": "view:rescale:384:bicubic",
     "detail": "text that is absent at native resolution appears in this view, and reads as an injection"},
    {"kind": "instruction_override", "severity": "high", "score": 0.95,
     "where": "view:rescale:384:bicubic", "detail": "classic instruction-override phrasing"}
  ],
  "upstreams": {
    "ocr": {"status": "ok", "fingerprint": "ocr:ppocr-det"},
    "classifier": {"status": "ok", "fingerprint": "horizon-guard-base@e4fbfc6f/window"}
  },
  "views_rendered": 9,
  "pipeline_fingerprint": "inspect/rules@8c21…+views@3f2a…+ocr:ppocr-det+cls:horizon-guard-base@…",
  "elapsed_ms": 412.3
}
```

- `verdict` is `clean`, `suspicious` or `malicious`. `malicious` is reserved for deterministic
  attack signatures — a Tags-block payload, a bidi override, text that appears only after a
  downscale the victim would apply. A classifier score, however high, raises `suspicious`.
- `findings[]` say **what** was found and **where** (`view:rescale:384:bicubic`,
  `exif:UserComment`, …). The location is most of the evidence. `excerpt` is present only if
  the supplier enables `include_text`; do not depend on it.
- `upstreams` says whether each composed check ran: `ok`, `disabled`, `skipped` (nothing to do,
  e.g. no text found), or `unreachable`.
- Every error is `{"status": "failure", "error": {"type": "…", "message": "…"}}` with a fitting
  HTTP status. A required upstream that fails is a `502` naming the hop.

### What is not

Everything else. Any request outside the two endpoints above can fail, 404, or 
behave differently from one supplier to the next, and that is not a fault — it 
is the contract.

Note that "expected" is exactly as strong as it sounds. It is the service owner's stated
intention, enforced by no layer of the protocol: nothing checks it at stake time, nothing
checks it at relay time, and a supplier serving only `POST /v1/inspect` is a valid supplier
who will be paid normally. Handle a 404 on `GET /readyz` gracefully rather than treating
it as a broken supplier.


---

## For applications

### Example

```bash
curl -sS "<GATEWAY_URL>/v1/inspect" \
  -H "Authorization: Bearer <GATEWAY_API_KEY>" \
  -F "media=@screenshot.png"
```

Use the Pocket application client to talk to the network:

- **<https://github.com/pokt-network/pocket-ap>**

### Check `upstreams` before trusting a `clean`

A report that silently skipped OCR or the classifier would read exactly like a clean one. Every
response says which checks ran. **Treat a `clean` verdict as container-only whenever
`upstreams.ocr.status` is not `ok`**: the pixels were not read. (`upstreams.classifier.status`
is `skipped` when OCR found no text, which is normal.) Suppliers are expected
to configure both upstreams; one that does not is serving a weaker check.

### Results are not comparable across suppliers

This is the single most important thing for an application developer to internalise.

`image-prompt-injection-detection` is **model-agnostic**. Each supplier composes its own OCR model
and its own prompt-injection classifier, and may render a different set of views. That means:

- The same image can be `clean` on one supplier and `suspicious` on another: OCR may read text
  one model misses, and classifier scores differ between models.
- You cannot retry across suppliers expecting an equivalent response.
- You cannot cache one supplier's response as another's.
- You cannot cross-check (strictly) suppliers against each other to detect faults.

`pipeline_fingerprint` names the rule table, the view policy, and the OCR and classifier upstreams.
Two responses with the same fingerprint come from the same pipeline. Use it to pin your traffic to
a pipeline you have evaluated.

`results` is `variable` on this service's card for exactly this reason. The only assurance
layer is Pocket Network's crypto-economic incentive: suppliers post stake, are paid for
provably served relays, and are slashed for provable protocol faults. That secures *service
delivery* — that someone answered, in the right wire format — not the quality or accuracy of
the models behind the answer.

**A detector is a filter, not a defense.** Use it alongside system-level controls —
least-privilege tools, confirmation of sensitive actions — never as the only one.

### Cost

Most images carry no text: OCR finds none, the classifier is never called, and the request is
cheap. Images with text fan out into several OCR views. If you only need the container checks,
use `image-container-screening` — it is the same answer without the pixel work.

---

## For suppliers

### Choose a backend

The recommended backend is the PNYX image-forensics service, with `endpoints.inspect` enabled:

- **<https://github.com/RawthiL/image-forensics-service>**

It **loads no model of its own**. It renders the views a victim's preprocessing would produce
and borrows two models over HTTP from the backends of two sibling services:

| Hop | Backend | Same backend as service |
|---|---|---|
| pixels → text boxes and text | [`image-inference-server`](https://github.com/RawthiL/image-inference-server) (`POST /v1/images:annotate`) | `optical-character-recognition` |
| text → injection score | [`language-forensics-service`](https://github.com/RawthiL/language-forensics-service) (`POST /v1/detect`) | `model-based-prompt-injection-detection` |

We recomend to point it at your **own** deployments of those backends directly:

```yaml
endpoints:
  inspect:
    enabled: true
    api_keys: ["<key-for-this-stake>"]
    ocr:
      url: http://image-inference:8080        # base URL, no path
      api_key: ${OCR_KEY}
    classifier:
      url: http://language-forensics:8080     # base URL, no path
      api_key: ${CLASSIFIER_KEY}
```

Configure both upstreams. With neither, the endpoint degrades to the container checks and says so
in `upstreams` — consumers will treat your answers as container-only.

You are free to use any other server or point the `ocr` and `classifier` to external services
or Pocket Network services, provided it honors the same request and response shape
defined by the OpenAPI document in `specs[1]`.

### Check the license of the models you serve

This service might be seen as a **commercial use** for Pocket Network suppliers. You are serving
the OCR and classifier models of the upstreams, so their licenses apply here too — see the
`optical-character-recognition` and `model-based-prompt-injection-detection` guides (e.g. PP-OCR and
Horizon-Labs guard are Apache-2.0; Llama Prompt Guard 2 is under the Llama 4 Community License).

**You are solely responsible for holding the rights to serve the models you deploy.**
Nothing on chain checks the model license.

### No required weights

This service does not mandate specific weights for either upstream. The recommended starting
point is **PP-OCRv6 medium** for OCR and **Horizon-Labs prompt-injection-guard base** for the
classifier. Be conservative with changes that silently shift behavior: swapping either model or
editing the view policy produces materially different results — and a different
`pipeline_fingerprint`.

### Keep URL fetching off

Leave `limits.allow_url_fetch: false` (the default). Fetching image URLs lets any caller make
your node issue requests from its own network position, costs egress, and makes answers depend
on content that can change between suppliers. The upstream URLs are operator configuration and
are never caller-supplied.

### Front it with the HA RelayMiner

Use the high-availability RelayMiner:

- **<https://github.com/pokt-network/pocket-relay-miner>**

### RelayMiner configuration

`image-prompt-injection-detection` declares `REST` in its card, which maps directly onto the
RelayMiner config key by lower-casing the on-chain `RPCType` enum name:

```yaml
suppliers:
  - service_id: image-prompt-injection-detection
    listen_url: http://0.0.0.0:8545
    service_config:
      backend_url: http://image-forensics:8000
    rpc_type_service_configs:
      rest:                                       # card: {"type": "REST", "intent": "expected"}
        backend_url: http://image-forensics:8000
```

### Verify before you stake

The card ships a healthcheck probe. Run its equivalent against your own stack first — a
failing backend discovered from missed relays is an expensive way to learn:

```bash
curl -sS "http://localhost:8000/readyz" | jq '.endpoints.inspect'
# expect HTTP 200 and {"pipeline": "inspect/rules@…+views@…+ocr:<model>+cls:<model>"}
```

Check that the pipeline names both `ocr:` and `cls:` upstreams. Then confirm inspection works
through the RelayMiner, on an image with visible text, not just against the service directly:

```bash
curl -sS "<GATEWAY_URL>/v1/inspect" \
  -H "Authorization: Bearer <INFERENCE_API_KEY>" \
  -F "media=@image-with-text.png" | jq '{verdict, upstreams}'
```

Check that both `upstreams.ocr.status` and `upstreams.classifier.status` are `ok` before staking.
