# PNYX AI Owned Services in the Pocket Network

This repository contains the cards templates and documentation for PNYX-owned services in the [Pocket Network](https://pocket.network/).

Currently we (actively) manage:
- [text-generation](https://network-analytics.vercel.app/?tab=services&service=text-generation)
- [qwen3-embedding-0-6b](https://network-analytics.vercel.app/?tab=services&service=qwen3-embedding-0-6b)

### What does it mean to manage/own a service?

We are the care-takers of these services, if you have trouble providing or consuming relays, or want to get in touch about the service rules and parameter (like `CUPR`), you can get in touch with us through our discord or our [portal](https://pnyxai.com).

We are not responsible for the **content** you are consuming from them. The Pocket Network is a **permission-less service**, anyone can join as a supplier or consumer.

### How to check docs?

We generate the on-chain `sha256` using the [provided script](./card-spec-sha.sh):

```sh
./card-spec-sha.sh https://github.com/pnyxai/pocket-network-services/blob/main/<some>.md
```

This produces a the SHA value and the link to the `raw` content, you can re-check the staked value by simply doing:

```sh
curl -sSL https://raw.githubusercontent.com/... | shasum -a 256 | awk '{print $1}'
```