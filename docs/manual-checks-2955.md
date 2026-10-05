# Manual checks for #2955 (Direct-only power features; NOT part of 1.17)

None of this could be exercised without launching the app. Use a **Direct** build. Back up
`~/Library/Application Support/Distavo/watcher-config.json` first (shared by every edition).

## CLI (`docs/cli.md`)

1. `Distavo transcribe sample.m4a` prints valid SRT to stdout (open it in a subtitle player or `ffmpeg -i x.srt out.vtt`).
2. `-f vtt`, `-f json | jq .`, `-f md` look right; `-o out.srt` creates the file, a second run refuses, `--force` replaces it.
3. `-o link.srt` where `link.srt` is a symlink to another file: refused without `--force`; with `--force` the symlink is replaced and the target untouched.
4. While the menu-bar app is running: run the CLI; no second menu-bar icon, no notification, no new file in work/notes folders, config file mtime unchanged.
5. `echo $?` gives 2 for a bad flag, 3 for a missing file, 4 with the engine unavailable (stop WhisperX / rename the model folder).
6. Launch the normal app normally and via `open -a Distavo --args -ApplePersistenceIgnoreState YES`: starts as usual (not CLI mode).
7. Ctrl-C mid-run: `ls $TMPDIR | grep distavo-cli-` is empty.
8. A recording whose speech contains terminal escape text: on a terminal it is shown as visible symbols; `| cat -v` shows it faithfully.

## MCP (`docs/mcp.md`)

1. Off by default: `lsof -nP -iTCP -sTCP:LISTEN | grep Distavo` shows nothing. Enable + Save: one listener on `127.0.0.1` only.
2. With the printed URL and token: `curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' $URL`.
3. Refusals: no token 401; wrong token 401; `-H 'Origin: http://x'` 403; `-H 'Host: evil.test:PORT'` 403; `-X OPTIONS` 403; GET 405; text/plain 415.
4. A real MCP client (Claude Desktop or `npx @modelcontextprotocol/inspector`): initialize, list_notes, get_note, search_notes (with and without the search index enabled).
5. Regenerate token: the old token is refused at once; toggle off + Save: the port closes at once; quit the app: the port closes.
6. Take the port with `nc -l 127.0.0.1 PORT` first, set it as a fixed port: server stays OFF with a message.
7. Replace a note with a symlink to a file outside the notes folder while the server runs: `get_note` says no such note.
8. The pasteboard after "Copy client config" is flagged concealed (Maccy/Paste skip it) and clears after 60 s.
9. Keychain: Keychain Access shows `uk.co.riera.distavo.mcp`; grep the config, `defaults read uk.co.riera.distavo` and `~/Library/Logs/Distavo/distavo.log` for the token: absent.

## Import from URL (`docs/import-url.md`)

1. Menu -> Import from URL...: paste a direct `https` mp3; it downloads, is queued, the temp folder is gone.
2. Paste a podcast RSS URL: episode list (newest 15); pick one; it downloads.
3. Refusals: `http://example.com/a.mp3`, `https://user:pw@host/a.mp3`, an HTML page, a >2 GB file (cap message appears when reached).
4. A server redirecting https -> http, or a public host redirecting to `https://192.168.x.x/`: refused.
5. Cancel mid-download: temp folder removed, nothing queued.
6. `http://192.168.x.x/file.mp3` on the LAN: warning shown; works or is blocked by ATS (record which).
