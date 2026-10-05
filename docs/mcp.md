# Read-only MCP server (Vikunja #2955)

**Direct edition only; off by default.** Settings -> Connections -> **MCP server**. The App Store and Setapp
builds contain no server code.

It lets an MCP-capable app (Claude Desktop, an editor, a script) list and read your meeting notes. It is
**read-only**: no tool writes, deletes, records or runs anything, and nothing returns audio or file paths.

## Tools

| Tool | Does |
|---|---|
| `list_notes {limit?}` | Newest first (1-100, default 20): `id`, `title`, `date`, `modified`. |
| `get_note {id}` | The note as Markdown, frontmatter included. Notes over 400 000 bytes are refused. |
| `search_notes {query, limit?}` | Uses the search index **only if you already enabled it** (open Search Notes once); otherwise a clear tool error. Returns note ids and snippets, never transcripts. |

Ids are opaque (16 hex digits). There are no path parameters. `.prev-` regenerate backups, hidden files,
sub-folders, symlinks and hard-linked files are invisible and unreachable.

## Connect a client

Turn the toggle on and **Save**. Then **Copy client config** (it contains the URL and the token), e.g.:

```json
{ "mcpServers": { "distavo": {
    "type": "http",
    "url": "http://127.0.0.1:52817/mcp",
    "headers": { "Authorization": "Bearer <64 hex characters>" } } } }
```

The URL is `http://127.0.0.1:<port>/mcp`. With the default (automatic) port it changes every time the server
starts, and **a new token is generated every time the server starts**, so copy the config again after
re-enabling or re-launching. A fixed port is optional; if another program already holds it the server stays OFF
and Settings says why (it never switches ports silently). Protocol: JSON-RPC 2.0 over HTTP POST, JSON replies
(no SSE), methods `initialize`, `ping`, `tools/list`, `tools/call`; batches are refused.

## Threat model

A localhost server is reachable by any local process and, through the browser, by any web page you visit.

| Threat | Defence |
|---|---|
| Reachable from the network | Bound to **127.0.0.1 only** (`requiredLocalEndpoint`, loopback interface, `acceptLocalOnly`), exclusive bind, no Bonjour; each accepted peer is re-checked as loopback. Starts only when enabled, stops synchronously when disabled or on quit. |
| Web page in your browser (CSRF) | **Any `Origin` header is refused (403)**; only `POST`; `OPTIONS` is 403; no CORS header is ever sent, so a page cannot read a reply. |
| DNS rebinding | `Host` must be exactly `127.0.0.1:<port>` or `localhost:<port>`. |
| Another local process | Every request needs `Authorization: Bearer <token>`: 256 random bits, kept in the **Keychain** (never in the config, defaults or logs), compared in constant time after hashing both sides. Checks run on the request head, before any body is read; an unauthenticated request never reaches a note, a search or the JSON parser. |
| Token leakage | Fresh token on every start; "Regenerate token" stops the listener first, so the old token stops working at once. If the Keychain fails the server stays off. The clipboard copy is marked concealed/transient and cleared after 60 s if untouched. |
| Port squatting | A token is only as safe as the port it is sent to. Another local process that binds the port while Distavo is off could receive whatever token a client sends. Because every start issues a new token, a squatter only ever sees a token that is already dead. Prefer the automatic port; regenerate the token if you suspect a problem. |
| Parser attacks / DoS | Own strict HTTP/1.1 parser (`MiniHTTP.swift`): Content-Length only (Transfer-Encoding refused), duplicate or malformed headers refused, 1 MiB body, 8 KiB headers, 32 headers, length checked before buffering, 10 s whole-request deadline, 8 connections, 120 requests per minute, one request per connection. Fuzz-tested. |
| Echo / injection | Error replies are fixed strings that never contain request content. |
| Path traversal | Opaque ids resolved by listing the folder; notes are opened with `openat(O_NOFOLLOW)` on a directory descriptor and the descriptor is verified (regular file, one link, size cap), so a symlink swapped in after listing is not followed. |

**Prompt injection is the client's risk.** Note text is data written from recorded speech; whoever spoke in a
meeting (or any text that ended up in a note) could try to instruct an AI model that reads it. Distavo returns it
inside tool results and tells the client to treat it as untrusted, but it cannot make a client's model obey that.
Only connect clients you trust with your notes, and prefer clients that ask before acting on tool output.
Whatever app you connect receives the note text you let it read.
