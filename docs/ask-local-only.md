# Ask Your Notes: how "local only" is enforced (Vikunja #2948)

Ask sends your question and note excerpts to a model. For Ollama that is an HTTP request,
so the endpoint is checked every time (`AskEndpoint.swift`, `NetworkScope.swift`):

- The URL host is parsed once from the percent-encoded host. A `%` is accepted only as a
  zone id (`%25<zone>`) on a bracketed link-local IPv6 literal; any other host containing
  `%`, any userinfo, and a bracketed non-IPv6 host are rejected.
- Numeric hosts are read the way the socket layer reads them (`getaddrinfo`, so `2130706433`,
  `0x7f.1` are normalised) and judged by the real address. Names are resolved once and EVERY
  address must be loopback, RFC1918, link-local or ULA. Bare names and `*.local` are not
  trusted by shape; a name that does not resolve is refused. Unspecified, NAT64, 6to4,
  IPv4-compatible IPv6 and public space are refused. `100.64.0.0/10` (Tailscale/CGNAT) was
  never treated as local by `NetworkScope` and still is not.
- http: the request is sent to the validated IP itself (`Host` header = original host:port),
  so there is no second DNS lookup to rebind.
- The Ask session never follows redirects and never uses a system/PAC proxy; it keeps no
  cookies, cache or credentials.

**Residual risk (https with a hostname).** The hostname must stay in the URL so the
certificate can be validated, so URLSession resolves it again at connect time. Only the
check-time validation applies to that second lookup; TLS binds the name (a rebound public
address would have to present a valid certificate for that name). Use http to an IP or
name on the LAN, or an https IP literal, if this matters to you.
