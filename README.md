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

Key properties:

  - melira is a CloudFront Function (viewer-request) classifying at the edge
  - Cascade: ai.robots.txt patterns → thief, missing Sec-Fetch-Mode → garbage, blocklist → garbage, default → human
  - Thief/garbage traffic → Valki origin serving engineered corpus (never cached, `no-store`)
  - Human traffic → customer's real origin (cached per origin's `Cache-Control`)
  - `x-traffic-class` header in cache key separates bot from human cache entries
  - Customer deploys the function, configures two CloudFront origins (human + bot)

## Architecture: Fascinating Full Reverse Proxy

In this mode there is no CDN edge classifier. ICENODE sits directly in the
request path, terminates TLS for the customer's public domain, classifies
traffic itself, and proxies human requests to the customer's origin via a
pocket subdomain. The two TLS lifecycles never interfere.

```




           ┌─────────┐                             TLS
           │         │                             ALPN-01
  ─────────┤┌────────┼─►┌─────────────────────────┐
  ─────────┼┼──────┐ │  │ origin.customer.com     │     ┌────────────┐
  ─────────┤│Caddy │ │  └─────────────────────────◄────►│            │
           ││  ▼   │ │                                  │  Let's     │
           ││iceout│ │                                  │   Encrypt  │
  ─────────┤│  ▲   │ │  ┌─────────────────────────┐     │            │
  ─────────┼┘      └─┼─►│ GCS corpus bucket       │     └────────────┘
  ─────────┤         │  └─────────────────────────┘
           └─────────┘
             ICENODE




```

Key properties:

  - ICENODE procures certs for www.customer.com via TLS-ALPN-01
  - Customer origin procures certs for origin.customer.com independently
  - No HTTP-01 challenge multiplexing hack
  - If one cert expires, the other is unaffected
  - Customer only needs to: create a pocket subdomain, point A record to us


### How it differs from Boring Edge Classifier

| Aspect | Boring (CN) | Fascinating (FRP) |
|--------|-------------|-------------------|
| Who classifies | CloudFront function (melira.js) | Rust classifier on ICENODE node |
| TLS termination | CloudFront for public domain | Caddy on ICENODE node |
| Origin access | CloudFront → origin directly | Caddy → pocket subdomain |
| Cert lifecycle | Customer manages via CloudFront | ICENODE and origin independent |
| Rule changes | Customer must redeploy JS | Control train picks up YAML, no customer action |
| Customer setup | Deploy CloudFront function, configure origins | Create pocket subdomain, point A record |
