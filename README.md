# Orim

A glorious demonstration of how Ice Node shall serve the traffic deployed in dual origin mode.

## Architecture: Boring Edge Classifier

```


           ┌─────────┐                             TLS
           │         │                             any
  ─────────┤┌────────┼─►┌─────────────────────────┐
  ─────────┼┼──────┐ │  │ hidden.example.com      │     ┌────────────┐
  ─────────┤│      │ │  └─────────────────────────◄────►│            │
           ││melira│ │                                  │  Let's     │
           ││      │ │                                  │   Encrypt  │
  ─────────┤│      │ │  ┌─────────────────────────◄────►│            │
  ─────────┼┘      └─┼─►│ hidden.geosurge.ai LB   │     └────────────┘
  ─────────┼─────────┼─►└─────────────────────────┘│
  ─────────┤         │   └────────( MIG )──────────┘
           └─────────┘



```

## Architecture: Fascinating Full Reverse Proxy

In this mode there is no CDN edge classifier. ICENODE sits directly in the
request path, terminates TLS for the customer's public domain, classifies
traffic itself, and proxies human requests to the customer's origin via a
pocket subdomain. The two TLS lifecycles never interfere.

```

                          ┌──────────────────┐
      A record            │  Let's Encrypt   │
   www.customer.com ──►   │                  │
         │                └────┬────────┬────┘
         │           ALPN-01   │        │  HTTP-01 or ALPN-01
         │          (for us)   │        │  (for them, independently)
         ▼                     ▼        ▼
  ┌────────────────────────────────┐  ┌───────────────────────────┐
  │  ICENODE node                  │  │  Customer origin           │
  │                                │  │  origin.customer.com       │
  │  ┌──────────┐                  │  │  (pocket subdomain)        │
  │  │  Caddy   │ TLS termination  │  │                            │
  │  │  :443    │ for public domain│  │  Own cert, own lifecycle   │
  │  │  :80     │                  │  │  Only ICENODE talks to it  │
  │  └────┬─────┘                  │  │                            │
  │       │                        │  └──────────▲────────────────┘
  │  ┌────▼─────┐                  │             │
  │  │classifier│                  │             │
  │  │ :4000    │                  │             │
  │  └────┬─────┘                  │             │
  │       │                        │             │
  │  human? ──► reverse_proxy ─────┼─────────────┘
  │       │     to origin.customer │
  │  scraper? ─► serve corpus      │
  │              from GCS bucket   │
  │                                │
  └────────────────────────────────┘

  Key properties:
  - ICENODE procures certs for www.customer.com via TLS-ALPN-01
  - Customer origin procures certs for origin.customer.com independently
  - No HTTP-01 challenge multiplexing hack
  - If one cert expires, the other is unaffected
  - Customer only needs to: create a pocket subdomain, point A record to us

```

### How it differs from Boring Edge Classifier

| Aspect | Boring (CN) | Fascinating (FRP) |
|--------|-------------|-------------------|
| Who classifies | CloudFront function (melira.js) | Rust classifier on ICENODE node |
| TLS termination | CloudFront for public domain | Caddy on ICENODE node |
| Origin access | CloudFront → origin directly | Caddy → pocket subdomain |
| Cert lifecycle | Customer manages via CloudFront | ICENODE and origin independent |
| Rule changes | Customer must redeploy JS | Control train picks up YAML, no customer action |
| Customer setup | Deploy CloudFront function, configure origins | Create pocket subdomain, point A record |

### What the customer does

1. Create a pocket subdomain: `origin.customer.com` pointing to their real server
2. Ensure origin serves on the pocket subdomain with valid TLS
3. Point the public domain's A record to the ICENODE load balancer IP
4. Done. ICENODE handles everything else.

### What ICENODE does

1. Caddy terminates TLS for the public domain (TLS-ALPN-01, cert stored in GCS via caddy-s3)
2. Every request is forwarded to the classifier on localhost
3. Classifier returns `X-Traffic-Class: human` or `X-Traffic-Class: scraper` (or live-llm, etc.)
4. Human traffic: Caddy reverse-proxies to `origin.customer.com` (the pocket subdomain)
5. Scraper traffic: Caddy serves corpus from GCS bucket

## PoC Implementation Plan

Minimal proof of concept demonstrating the Fascinating FRP architecture works.
Reuses patterns from melira's `machines/dark-proxy/deploy.sh` for DNS and GCP automation.

### What the PoC proves

1. Caddy can terminate TLS for a public domain and reverse-proxy to a pocket subdomain origin, each managing certs independently
2. The HTTP-01 multiplexing hack is not needed
3. Classification routing works (human → origin, scraper → corpus)
4. Cert renewal on either side does not affect the other

### Components

```
orim/
├── README.md                   # This file
├── flake.nix                   # Nix dev shell with gcloud, aws, curl, jq, dig
├── machines/
│   ├── proxy/
│   │   ├── configuration.nix   # NixOS config for the PoC VM
│   │   ├── caddy.nix           # Caddyfile with dual-origin pattern
│   │   └── gcp.nix             # VM spec (e2-micro is enough for PoC)
│   └── origin/
│       └── configuration.nix   # Minimal static site as mock origin
├── scripts/
│   ├── deploy.sh               # Adapted from melira: provision → deploy → dns → verify
│   ├── dns.sh                  # Porkbun API: set A record for public domain + pocket subdomain
│   └── verify.sh               # curl tests: human UA → origin, scraper UA → corpus
├── corpus/
│   └── index.html              # Minimal test corpus (one HTML page)
└── docs/
    └── PROOF.md                # Test log showing independent cert lifecycle
```

### Step-by-step

**Step 1: DNS setup** (adapt from melira `deploy.sh` step 3)
- Public domain: `orim.fere.me` → A record → PoC VM IP
- Pocket subdomain: `origin.orim.fere.me` → A record → same VM or different IP
- Uses Porkbun API (passveil for credentials, same as melira)

**Step 2: GCP VM** (adapt from melira `deploy.sh` step 1)
- Single `e2-micro` or `e2-small` is enough
- Run via `gcp-colmena` or manual `gcloud compute instances create`
- NixOS with Caddy + mock classifier

**Step 3: Caddy config** (new, the core of the PoC)
- Port 443: terminate TLS for `orim.fere.me` via TLS-ALPN-01
- Classify: forward to mock classifier on localhost:4000
- Human → `reverse_proxy https://origin.orim.fere.me`
- Scraper → `file_server` from `/var/www/corpus/` (or reverse_proxy to GCS)
- No HTTP-01 passthrough needed — origin manages its own certs

**Step 4: Mock classifier** (minimal)
- Can be as simple as a shell script HTTP server or a Caddy `respond` block
- Check User-Agent header, return `X-Traffic-Class: human` or `X-Traffic-Class: scraper`
- Or: use Ilona's actual iceout binary from grim-monolith if available

**Step 5: Mock origin** (minimal)
- Caddy or nginx on the same VM listening as `origin.orim.fere.me`
- Serves a static page: "This is the real origin"
- Has its own TLS cert (Let's Encrypt via ALPN-01 or HTTP-01)

**Step 6: Verify** (adapt from melira `deploy.sh` step 7)
- `curl -H "User-Agent: Mozilla/5.0" https://orim.fere.me/` → "This is the real origin"
- `curl -H "User-Agent: GPTBot/1.0" https://orim.fere.me/` → corpus HTML
- `curl -H "User-Agent: ChatGPT-User" https://orim.fere.me/` → "This is the real origin" (live agent passthrough)
- Check both certs: `echo | openssl s_client -connect orim.fere.me:443` and `echo | openssl s_client -connect origin.orim.fere.me:443` show different issuers/serials
- Wait for cert renewal window, confirm both renew independently

### What to contribute back to darksteel-forge

Once the PoC proves the architecture:

1. A `mkDualOriginProxy` function for `machines/proxy/lib.nix` — takes public domain + pocket subdomain, eliminates `http01Upstream`
2. An updated copier template (`templates/proxy/copier.yaml`) with `origin_domain` variable
3. Updated `how_to_deploy.md` with the dual-origin customer setup instructions
4. Test recipes for the new pattern
