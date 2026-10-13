# `image-container-screening` — Connection Guide

Canonical connection documentation for the Pocket Network `image-container-screening` service managed by `PNYX`.
This document is pinned by the service's on-chain card (`specs[0]`).

| | |
|---|---|
| Service ID | `image-container-screening` |
| Transport | `REST` (HTTP/1.1 and HTTP/2) |
| Expected endpoints | `POST /v1/screen`, `GET /readyz` |
| Response determinism | **Deterministic per rule table** — no model is involved |

> This service screens the image **file** for hidden payloads: text in metadata, smuggled Unicode,
> and bytes appended after the image data. It **never looks at the pixels**. An image with
> instructions painted across it comes back `clean` here — use `image-prompt-injection-detection`
> for that.

---

## The API contract

`image-container-screening` speaks the **image-forensics `/v1/screen` API**. Request and
response shapes, field names and error envelopes are defined by its OpenAPI 3.1 document, pinned
by this service's card (`specs[1]`) — we deliberately do not restate all of it here:

- <https://github.com/RawthiL/image-forensics-service/blob/main/docs/openapi.json>

### What is expected

Two endpoints:

```
POST /v1/screen   # screen one image file
GET  /readyz      # readiness probe
```

`POST /v1/screen` accepts `multipart/form-data` with **exactly one** of:

| Field | Type | Notes |
|---|---|---|
| `media` | file | Image upload. JPEG, PNG, WebP, BMP, TIFF, MPO. **Send the original bytes** — the container is the evidence. |
| `media_base64` | string | Alternative to `media`: base64 string or `data:` URI. |
| `url` | string | `http(s)` URL to fetch. **Off by default** on suppliers; do not depend on it. |

What it looks for:

| Class | Carrier |
|---|---|
| Metadata payload | EXIF, XMP, IPTC, PNG `tEXt`/`iTXt`/`zTXt`, JPEG `COM`, ICC description |
| Unicode smuggling | Tags block `U+E0000–E007F`, zero-width, bidi overrides, variation selectors |
| Polyglot file | Bytes after the image's logical end |

A successful response:

```json
{
  "scope": "container",
  "verdict": "malicious",
  "injection": 1.0,
  "severity": "high",
  "findings": [
    {"kind": "unicode_tag_block", "severity": "high", "score": 1.0,
     "where": "exif:UserComment", "detail": "…", "excerpt": null}
  ],
  "upstreams": {},
  "views_rendered": 0,
  "pipeline_fingerprint": "screen/rules@<digest>",
  "elapsed_ms": 3.1
}
```

- `verdict` is `clean`, `suspicious` or `malicious`. `malicious` is reserved for deterministic
  attack signatures (e.g. a Tags-block payload, a bidi override); `suspicious` covers medium
  findings or a score at or above the supplier's threshold.
- `scope` is always `container`: the pixels were not examined, so `clean` is a weak statement.
- `findings[]` say **what** was found and **where** (`exif:UserComment`, `png:tEXt:…`, …).
  `excerpt` is present only if the supplier enables `include_text`; do not depend on it.
- Every error is `{"status": "failure", "error": {"type": "…", "message": "…"}}` with a fitting
  HTTP status.

### What is not

Everything else. Any request outside the two endpoints above can fail, 404, or 
behave differently from one supplier to the next, and that is not a fault — it 
is the contract.

Note that "expected" is exactly as strong as it sounds. It is the service owner's stated
intention, enforced by no layer of the protocol: nothing checks it at stake time, nothing
checks it at relay time, and a supplier serving only `POST /v1/screen` is a valid supplier
who will be paid normally. Handle a 404 on `GET /readyz` gracefully rather than treating
it as a broken supplier.


---

## For applications

### Example

```bash
curl -sS "<GATEWAY_URL>/v1/screen" \
  -H "Authorization: Bearer <GATEWAY_API_KEY>" \
  -F "media=@image.png"
```

Use the Pocket application client to talk to the network:

- **<https://github.com/pokt-network/pocket-ap>**

### Results are comparable across suppliers running the same rules

No model is involved: the answer is a deterministic function of the file and the rule table.
Two suppliers reporting the same `pipeline_fingerprint` (`screen/rules@<digest>`) must return the
same verdict and findings for the same bytes. Suppliers on different releases may run different
rule tables, so compare fingerprints before comparing answers.

The card still declares `results` as `variable`: nothing on chain forces suppliers onto the same
rule table, and `excerpt` / `elapsed_ms` differ anyway. The only assurance layer is Pocket
Network's crypto-economic incentive, which secures *service delivery*, not the rules behind the
answer.

### When it matters

Most pixel pipelines decode to RGB and drop metadata, so a payload in EXIF often never reaches a
model at all. It matters when application code lifts metadata into a prompt — a captioning tool,
a document parser, an agent shelling out to `exiftool`, an indexer treating metadata as text.

It is cheap, so it also works as a pre-filter in front of `image-prompt-injection-detection`.

**A detector is a filter, not a defense.** Use it alongside system-level controls —
least-privilege tools, confirmation of sensitive actions — never as the only one.

---

## For suppliers

### Choose a backend

The recommended backend is the PNYX image-forensics service, with `endpoints.screen` enabled:

- **<https://github.com/RawthiL/image-forensics-service>**

Screening needs **no model, no GPU, no sibling service and no network**. A screening-only
deployment needs no `detector` section, downloads nothing, and is ready as soon as it is
listening — a supplier can serve it from a small box:

```yaml
endpoints:
  detect:  {enabled: false}
  screen:  {enabled: true, api_keys: ["<key-for-this-stake>"]}
  inspect: {enabled: false}
```

You are free to use any other server, provided it honors the same request and response shape
defined by the OpenAPI document in `specs[1]`.

### No model, no license

No weights are served, so there is no model license to hold. The recommended backend's code is
MIT-licensed.

### Keep URL fetching off

Leave `limits.allow_url_fetch: false` (the default). Fetching image URLs lets any caller make
your node issue requests from its own network position, costs egress, and makes answers depend
on content that can change between suppliers.

### Front it with the HA RelayMiner

Use the high-availability RelayMiner:

- **<https://github.com/pokt-network/pocket-relay-miner>**

### RelayMiner configuration

`image-container-screening` declares `REST` in its card, which maps directly onto the
RelayMiner config key by lower-casing the on-chain `RPCType` enum name:

```yaml
suppliers:
  - service_id: image-container-screening
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
curl -sS "http://localhost:8000/readyz" | jq '.endpoints.screen'
# expect HTTP 200 and {"pipeline": "screen/rules@<digest>"}
```

Then confirm screening works through the RelayMiner, not just against the
service directly:

```bash
curl -sS "<GATEWAY_URL>/v1/screen" \
  -H "Authorization: Bearer <INFERENCE_API_KEY>" \
  -F "media=@image.png" | jq '{scope, verdict, pipeline_fingerprint}'
```

Check that you receive a JSON response with `scope: "container"` and a `verdict` before staking.
