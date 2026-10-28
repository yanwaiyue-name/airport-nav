<div align="center">

# 🛫 airport-nav · Proxy Service Directory

**Low-cost proxy services, client tools, and beginner pitfalls — one page.**

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Weekly](https://img.shields.io/badge/health--check-weekly-blue)](.github/workflows/weekly-check.yml)

**🌐 Live**: https://yanwaiyue-name.github.io/airport-nav/
**中文**: [README.md](README.md)

</div>

---

## What this is

A curated directory of low-cost proxy (机场) services in mainland China, with **automated weekly availability checks**.

Each entry records: tier, price, traffic quota, line type, backup domains, and a risk note.

## The check is three-layered

Most directories only check "can the homepage open." That's not enough — a homepage can return 200 while the service is dead, or while the domain has been resold to a different brand.

| Layer | Script | What it catches |
|---|---|---|
| **Entry reachability** | `check_links.ps1` | Direct + proxy channel. Distinguishes "reachable" from "reachable only outside mainland" |
| **Brand identity** | `check_brand.ps1` | Fetches the landing page and checks whether the brand name still matches. Catches domain resale |
| **Node liveness** | `check_nodes.ps1` | TCP handshake against actual nodes from a local Clash subscription |

**Status semantics are deliberately conservative.** A single failed check does not mark a service dead — the rule is "two strikes": first failure downgrades to unknown, only two consecutive failures mark it dead. This prevents a transient network hiccup from branding a live service as dead for a week.

## What the status column means

| Badge | Meaning |
|---|---|
| ✅ 存活 | Server responded on the last check |
| ❓ 未验证 | Environment could not determine (DNS pollution / blocked) — **not necessarily dead** |
| ❌ 失效 | Two consecutive CI checks got no response |
| 🌐 仅墙外可达 | Direct connection failed, but reachable through a proxy — likely DNS-polluted, **you'll need a working proxy first** |
| → domain | The entry redirects to a different domain (rebranding, resale, or parked page) — verify the brand before paying |

## Architecture

```
data/*.json  ──render.ps1──▶  README.md (markdown tables)
             └──────────────▶  docs/data.js ──▶ docs/index.html (searchable)
        ▲
        └── check_links.ps1 / check_brand.ps1 / check_nodes.ps1
                    ▲
        GitHub Actions, every Saturday 11:00 Beijing time
```

**Data is the source**. README and the web page are both generated. Never edit README.md directly.

## Notable engineering details

- **Byte-identical output across PowerShell 5.1 and 7.** Local runs use 5.1, CI uses 7 — different JSON formatting would produce a false diff every week. Solved with a custom serializer (`scripts/lib-json.ps1`).
- **Locale-independent sorting.** `Sort-Object` uses culture-aware comparison; Chinese sorting differs between zh-CN and en-US, so the table row order would churn. Solved by expanding strings to UTF-16 code points as ASCII sort keys.

## Contributing

All content lives in `data/*.json`. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

Listing ≠ recommendation. Cheap proxy services carry high exit-scam risk — always start with the minimum billing period. This project has no affiliation with any listed service.
