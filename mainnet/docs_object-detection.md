# `object-detection` — Connection Guide

Canonical connection documentation for the Pocket Network `object-detection` service managed by `PNYX`.
This document is pinned by the service's on-chain card (`specs[0]`).

| | |
|---|---|
| Service ID | `object-detection` |
| Transport | `REST` (HTTP/1.1 and HTTP/2) |
| Expected endpoints | `POST /predict`, `GET /health` |
| Response determinism | **Variable** — suppliers run different detection models |

> Only object detection is served. Segmentation, classification, depth, and other tasks are **not** part of this service.

---

## The API contract

`object-detection` speaks the **Ultralytics Predict API**. Request and response shapes,
field names and error envelopes follow the Ultralytics dedicated-endpoint specification —
we deliberately do not restate them here. Refer to the upstream reference:

- <https://docs.ultralytics.com/platform/deploy/inference>

### What is expected

Two endpoints:

```
POST /predict   # run detection on one image
GET  /health    # readiness probe
```

`POST /predict` accepts `multipart/form-data` or `application/x-www-form-urlencoded`:

| Field | Type | Default | Notes |
|---|---|---|---|
| `file` | file | — | Image upload. JPEG, PNG, WebP, BMP, TIFF. Required unless `source` is used. |
| `source` | string | — | Alternative to `file`: `http(s)` URL, base64 string, or `data:` URI. |
| `conf` | float | server config | Confidence threshold, `0.01` to `1.0`. |
| `iou` | float | server config | Accepted for API compatibility, `0.0` to `0.95`. Current recommended backends are NMS-free, so this is ignored. |
| `imgsz` | int | model native | Accepted for compatibility, `32` to `1280`. Inference runs at the model's native resolution and boxes are mapped back to original-image pixels. |
| `normalize` | bool | `false` | Return box coordinates normalized to `0`–`1`. |
| `decimals` | int | server config | Coordinate precision, `0` to `10`. |

Provide either `file` or `source`, not both.

A successful response is the Ultralytics `PredictResponse` shape:

```json
{
  "images": [
    {
      "shape": [480, 640],
      "results": [
        {
          "name": "person",
          "class": 0,
          "confidence": 0.92,
          "box": {"x1": 120, "y1": 80, "x2": 400, "y2": 460}
        }
      ],
      "speed": {
        "preprocess": 2.1,
        "inference": 8.4,
        "postprocess": 0.3
      }
    }
  ],
  "metadata": {
    "image_count": 1,
    "class_names": ["person", "bicycle", "car", ...],
    "model": "rfdetr-base",
    "task": "detect",
    "version": {"gateway": "...", "backend": "triton"}
  }
}
```

### What is not

Everything else. A supplier **MAY** expose `POST /api/deployments/{owner}/{deployment}/predict`
or other Ultralytics Platform paths, and some will. Consumers **MUST NOT** depend on it.
Any request outside the two endpoints above can fail, 404, or behave differently from one
supplier to the next, and that is not a fault — it is the contract.

Note that "expected" is exactly as strong as it sounds. It is the service owner's stated
intention, enforced by no layer of the protocol: nothing checks it at stake time, nothing
checks it at relay time, and a supplier serving only `POST /predict` is a valid supplier
who will be paid normally. Handle a 404 on `GET /health` gracefully rather than treating
it as a broken supplier.


---

## For applications

### Example

```bash
curl -sS "<GATEWAY_URL>/predict" \
  -H "Authorization: Bearer <GATEWAY_API_KEY>" \
  -F "file=@image.jpg" \
  -F "conf=0.25" \
  -F "iou=0.7" \
  -F "normalize=false" \
  -F "decimals=3"
```

With a `source` URL instead of a file upload:

```bash
curl -sS "<GATEWAY_URL>/predict" \
  -H "Authorization: Bearer <GATEWAY_API_KEY>" \
  -F "source=https://example.com/image.jpg" \
  -F "conf=0.25"
```

Use the Pocket application client to talk to the network:

- **<https://github.com/pokt-network/pocket-ap>**

### Results are not comparable across suppliers

This is the single most important thing for an application developer to internalise.

`object-detection` is **model-agnostic**. Suppliers may run YOLO, RF-DETR, or any other
detection model that exposes the same `/predict` wire format. That means:

- Class indices are **not** portable. One supplier's class `0` may be
  `person`; another's may be `car`. Class names are consistent with the same COCO classes.
- Box coordinates, confidences, and even the set of detected objects can differ for the
  same input image.
- You cannot retry across suppliers expecting an equivalent response.
- You cannot cache one supplier's response as another's.
- You cannot cross-check (strictly) suppliers against each other to detect faults.

`results` is `variable` on this service's card for exactly this reason. The only assurance
layer is Pocket Network's crypto-economic incentive: suppliers post stake, are paid for
provably served relays, and are slashed for provable protocol faults. That secures *service
delivery* — that someone answered, in the right wire format — not the quality, class set,
or accuracy of the model behind the answer.

If your application needs a known quality floor or a fixed class taxonomy, you must measure
it yourself or select suppliers deliberately.

---

## For suppliers

### Choose a backend

The recommended backend is the PNYX object-detection inference server:

- **<https://github.com/RawthiL/image-inference-server>**

It is a Rust gateway in front of NVIDIA Triton Inference Server. It is model-agnostic:
the request/response contract stays the same regardless of which model family you run.

You are free to use any other Ultralytics-compatible `/predict` server, provided it honors
the same request and response shape.

### Check the license of the model you serve

This service might be seen as a **commercial use** for Pocket Network suppliers. Model weights keep their
own license no matter which server runs them. Some common detection models are **not** free
for commercial use without a separate license.

**You are solely responsible for holding the rights to serve the model you deploy.**
Nothing on chain checks the model license.

### No required weights

This service does not mandate specific weights. Serve any detection model that produces
`POST /predict` responses in the expected shape. Be conservative with changes that silently
shift behavior: swapping model families, aggressive quantization, or different confidence
calibration will all produce materially different results for consumers.

### Front it with the HA RelayMiner

Use the high-availability RelayMiner:

- **<https://github.com/pokt-network/pocket-relay-miner>**

### RelayMiner configuration

`object-detection` declares `REST` in its card, which maps directly onto the RelayMiner
config key by lower-casing the on-chain `RPCType` enum name:

```yaml
suppliers:
  - service_id: object-detection
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
# expect HTTP 200 and {"status":"healthy",...}
```

Then confirm inference works through the RelayMiner, not just against the
inference server directly:

```bash
curl -sS "<GATEWAY_URL>/predict" \
  -H "Authorization: Bearer <INFERENCE_API_KEY>" \
  -F "file=@image.jpg" \
  -F "conf=0.25" | jq '.images[0].results | length'
```

Check that you receive a JSON response with `images[].results[]` entries in the expected
shape before staking.
