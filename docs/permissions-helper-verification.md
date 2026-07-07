# Permissions helper + Local Network diagnosis — manual verification

The macOS **Local Network** privacy gate and the microphone / system-audio TCC
prompts can't be exercised in CI (they need a signed build and a human to click
the prompts), so this is the manual checklist — mirroring
`docs/meeting-capture-verification.md` and `docs/update-verification.md`.

Background: a public host name that resolves to a LAN address (e.g.
`ollama.lab.example.com → 192.168.0.5`) still needs Local Network permission.
`NetworkScope.isLocalOrResolvesLocal` now catches that via DNS resolution; the
DistavoCore unit tests (`NetworkScopeTests`) cover the classification with an
injected resolver, so only the UI + OS wiring needs a human here.

## Test Connections guidance (the auto-prompt)

1. Configure the Server Ollama URL to a LAN host that is **up** but for which
   Distavo has **no** Local Network permission (or toggle Distavo off in
   System Settings → Privacy & Security → Local Network first).
2. Settings → **Test connection**. Expect: the Server Ollama dot goes red **and**
   an inline orange warning appears naming the host, with a **Fix permissions…**
   button. Confirm it also fires when the URL is a *public FQDN that resolves to a
   LAN IP*, not just a literal `192.168.x` address.
3. Grant Local Network permission, relaunch, Test again → dot green, warning gone.

## Permissions sheet

4. Settings → Connections → **Check permissions…** opens the sheet.
5. **Local Network** row: "Open Local Network Settings" opens the correct pane;
   the orange note explains the after-update **off→on + relaunch** fix.
6. On macOS **14.4+** the **Microphone** and **System Audio Recording** rows show.
   - Microphone reflects real state: green "Granted" when allowed; "Request
     Access…" when undetermined (clicking prompts and the row updates); "Open
     Microphone Settings" when denied.
   - Audio row opens the System Audio Recording pane.
7. On macOS **< 14.4** only the Local Network row shows (capture unsupported).

## The real-world trigger this fixes

After a Sparkle auto-update replaced the app binary, the Local Network grant read
**ON** but was denied — every connection to the LAN host failed while `curl`
worked. Cure: toggle the entry **off→on** and relaunch. Multiple "Distavo"
entries can accumulate (one per code signature seen); enable them all.
