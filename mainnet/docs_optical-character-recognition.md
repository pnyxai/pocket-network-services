# `optical-character-recognition` — Connection Guide

Canonical connection documentation for the Pocket Network `optical-character-recognition` service managed by `PNYX`.
This document is pinned by the service's on-chain card (`specs[0]`).

| | |
|---|---|
| Service ID | `optical-character-recognition` |
| Transport | `REST` (HTTP/1.1 and HTTP/2) |
| Expected endpoints | `POST /v1/images:annotate`, `GET /health` |
| Response determinism | **Variable** — suppliers run different OCR models |

> Only text detection and recognition are served. Label, face, logo, landmark, object, safe-search
> and the other Cloud Vision features are **not** part of this service.

---

## The API contract

`optical-character-recognition` speaks the **Google Cloud Vision `images:annotate` API** (REST).
Request and response shapes, field names and error envelopes follow the Cloud Vision
specification — we deliberately do not restate them here. Refer to the upstream reference:

- <https://cloud.google.com/vision/docs/reference/rest/v1/images/annotate>

### What is expected

Two endpoints:

```
POST /v1/images:annotate   # run OCR on one or more images
GET  /health               # readiness probe
```

`POST /v1/images:annotate` takes the Cloud Vision JSON body:

```json
{
  "requests": [
    {
      "image": {"content": "<base64 image bytes>"},
      "features": [{"type": "TEXT_DETECTION"}]
    }
  ]
}
```

| Field | Notes |
|---|---|
| `requests[]` | One entry per image. Suppliers cap the number of images per call (recommended backend default: `16`). |
| `image.content` | Base64-encoded image bytes. JPEG, PNG, WebP, BMP, TIFF. |
| `image.source.imageUri` | `http(s)` URL. **Off by default** on suppliers; do not depend on it. `gcsImageUri` is not supported. |
| `features[].type` | `TEXT_DETECTION` or `DOCUMENT_TEXT_DETECTION`. Names or their enum numbers are accepted. |
| `imageContext` | Accepted and ignored (e.g. `languageHints`): the served model defines the languages. |

A successful response is the Cloud Vision `BatchAnnotateImagesResponse` shape:

```json
{
  "responses": [
    {
      "textAnnotations": [
        {
          "description": "Hello\nPocket Network\n",
          "boundingPoly": {"vertices": [{"x": 12, "y": 10}, {"x": 310, "y": 10}, {"x": 310, "y": 96}, {"x": 12, "y": 96}]}
        },
        {
          "description": "Hello",
          "boundingPoly": {"vertices": [{"x": 12, "y": 10}, {"x": 120, "y": 10}, {"x": 120, "y": 44}, {"x": 12, "y": 44}]}
        }
      ],
      "fullTextAnnotation": {
        "pages": [{"width": 640, "height": 480, "blocks": [...], "confidence": 0.97}],
        "text": "Hello\nPocket Network\n"
      }
    }
  ]
}
```

- `textAnnotations[0]` is the full text; the following entries are one per word.
- `fullTextAnnotation` holds pages → blocks → paragraphs → words → symbols, with `detectedBreak`s.
- Polygons are in original-image pixels, in reading order (vertex 0 is the top-left of the text as read).
- An image without text yields `{}`.
- A failure that concerns one image (bad base64, unsupported feature, backend error) is returned in
  `responses[i].error` with HTTP `200`, as Cloud Vision does. Request-level errors use the Google
  envelope `{"error": {"code", "message", "status"}}`.
- No `locale` is returned.

### What is not

Everything else. A supplier **MAY** expose other Cloud Vision features, other paths (e.g.
`POST /predict` for object detection, served by the same backend), or extensions such as
`TEXT_REGION_DETECTION` (text regions without recognition), and some will. Consumers **MUST NOT**
depend on them. Any request outside the two endpoints and the two feature types above can fail,
404, or behave differently from one supplier to the next, and that is not a fault — it is the
contract.

The API is the **REST** surface only. Google's gRPC transport is not served; configure Cloud
Vision client libraries with `transport="rest"`.

Note that "expected" is exactly as strong as it sounds. It is the service owner's stated
intention, enforced by no layer of the protocol: nothing checks it at stake time, nothing
checks it at relay time, and a supplier serving only `POST /v1/images:annotate` is a valid
supplier who will be paid normally. Handle a 404 on `GET /health` gracefully rather than
treating it as a broken supplier.


---

## For applications

### Example

```bash
curl -sS "<GATEWAY_URL>/v1/images:annotate" \
  -H "Authorization: Bearer <GATEWAY_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"requests": [{"image": {"content": "'"$(base64 < page.png | tr -d '\n')"'"},
                     "features": [{"type": "TEXT_DETECTION"}]}]}'
```

Existing Cloud Vision client code works by swapping the endpoint (REST transport):

```python
from google.api_core.client_options import ClientOptions
from google.cloud import vision

client = vision.ImageAnnotatorClient(
    transport="rest",   # REST only, not gRPC
    client_options=ClientOptions(api_endpoint="<GATEWAY_URL>",
                                 api_key="<GATEWAY_API_KEY>"))
r = client.text_detection(image=vision.Image(content=open("page.png", "rb").read()))
print(r.full_text_annotation.text)
```

Use the Pocket application client to talk to the network:

- **<https://github.com/pokt-network/pocket-ap>**

### Results are not comparable across suppliers

This is the single most important thing for an application developer to internalise.

`optical-character-recognition` is **model-agnostic**. Suppliers may run PP-OCR (any version or
tier) or any other OCR pipeline that exposes the same `images:annotate` wire format. That means:

- The recognized text, its segmentation into lines and words, and the polygons can differ for
  the same input image.
- Supported scripts and languages depend on the supplier's model and character set. A supplier
  may not recognize characters another one does.
- You cannot retry across suppliers expecting an equivalent response.
- You cannot cache one supplier's response as another's.
- You cannot cross-check (strictly) suppliers against each other to detect faults.

`results` is `variable` on this service's card for exactly this reason. The only assurance
layer is Pocket Network's crypto-economic incentive: suppliers post stake, are paid for
provably served relays, and are slashed for provable protocol faults. That secures *service
delivery* — that someone answered, in the right wire format — not the quality, language
coverage, or accuracy of the model behind the answer.

If your application needs a known quality floor or a specific language set, you must measure
it yourself or select suppliers deliberately.

---

## For suppliers

### Choose a backend

The recommended backend is the PNYX image inference server, with its `ocr` endpoint enabled:

- **<https://github.com/RawthiL/image-inference-server>**

It is a Rust gateway in front of NVIDIA Triton Inference Server. It is model-agnostic:
the request/response contract stays the same regardless of which model family you run.
OCR runs as two Triton models, a text detector and a recognizer; the gateway crops each
detected region and batches the recognizer calls.

The same deployment can also serve `object-detection` (`POST /predict`). Each endpoint has its
own model and API keys in `config.yaml`.

You are free to use any other Cloud Vision-compatible `images:annotate` server, provided it
honors the same request and response shape.

### Check the license of the model you serve

This service might be seen as a **commercial use** for Pocket Network suppliers. Model weights keep their
own license no matter which server runs them. The official PaddleOCR PP-OCR weights (and their
ONNX conversions) are **Apache-2.0**. Fine-tuned or third-party weights carry whatever license
their trainer gives them.

**You are solely responsible for holding the rights to serve the model you deploy.**
Nothing on chain checks the model license.

### No required weights

This service does not mandate specific weights. The recommended starting point is
**PP-OCRv6 medium** (det + rec, Apache-2.0) on a GPU, or PP-OCRv6 small on CPU-only hosts.
Avoid the tiny tier: its recognizer has a much smaller character set. Serve any OCR model that
produces `POST /v1/images:annotate` responses in the expected shape. Be conservative with
changes that silently shift behavior: swapping model families or tiers, a smaller character
set, or aggressive detector resizing will all produce materially different results for
consumers.

### Keep URL fetching off

Leave `limits.allow_url_sources: false` (the default). Fetching image URLs lets any caller make
your node download arbitrary content from its own IP, costs egress, and makes answers depend on
content that can change between suppliers.

### Front it with the HA RelayMiner

Use the high-availability RelayMiner:

- **<https://github.com/pokt-network/pocket-relay-miner>**

### RelayMiner configuration

`optical-character-recognition` declares `REST` in its card, which maps directly onto the
RelayMiner config key by lower-casing the on-chain `RPCType` enum name:

```yaml
suppliers:
  - service_id: optical-character-recognition
    listen_url: http://0.0.0.0:8545
    service_config:
      backend_url: http://image-inference-serve:8080
    rpc_type_service_configs:
      rest:                                       # card: {"type": "REST", "intent": "expected"}
        backend_url: http://image-inference-serve:8080
```

### Verify before you stake

The card ships a healthcheck probe. Run its equivalent against your own stack first — a
failing backend discovered from missed relays is an expensive way to learn:

```bash
curl -sS "http://localhost:8080/health"
# expect HTTP 200 and {"status":"healthy","endpoints":{"ocr":{...}}}
```

Make sure `endpoints.ocr` is present in the health response: an endpoint that is not enabled in
`config.yaml` is not mounted, and `/health` only reports enabled endpoints.

Then confirm inference works through the RelayMiner, not just against the
inference server directly:

```bash
curl -sS "<GATEWAY_URL>/v1/images:annotate" \
  -H "Authorization: Bearer <INFERENCE_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"requests": [{"image": {"content": "'"$(base64 < page.png | tr -d '\n')"'"},
                     "features": [{"type": "TEXT_DETECTION"}]}]}' \
  | jq -r '.responses[0].fullTextAnnotation.text'
```

Check that you receive the text of your test image, in the expected response shape, before staking.
