# QR Pairing TODO (Android)

## Goal
Enable fast pairing of the Android Probnik app with a remote BEAM node using ASCII QR emitted from the remote shell via `ProbnikQR.show/0`. The QR payload must be **Erlang terms** (no JSON).

## Payload format (Erlang term)
- Term shape:
  - `{probnik_pair, Node, Cookie, [{mode, shortnames|longnames}]}`
- Example:
  - `{probnik_pair, 'one@super-io', secret_token, [{mode, shortnames}]}`

## QR generation (remote shell)
- `ProbnikQR.show/0` (already added to the main app):
  - Uses `node()` and `Node.get_cookie()`
  - Detects name mode from hostname
  - Renders ASCII QR via `eqrcode`
- Usage from the observed node:
  - `iex --name one@super-io --cookie secret_token -S mix`
  - `ProbnikQR.show()`

## Implementation Status

### Done
- [x] **NodePreferences.java** - SharedPreferences helper for paired nodes
  - Save/load paired nodes list
  - Parse Erlang term QR payload
  - Add/update/remove nodes
  - Track active node
- [x] **PairingActivity.java** - Startup pairing screen
  - List of previously paired nodes with status
  - "Scan QR Code" button
  - Auto-connect to last active node on startup
  - Delete nodes from list
- [x] **QrScannerActivity.java** - Full-screen QR scanner
  - CameraX + ML Kit barcode scanning
  - Validates probnik_pair format before accepting
- [x] **HostActivity.java** - Updated to receive connection info
  - Writes connection.config in Erlang term format
  - Passes node/cookie/mode to Elixir side
- [x] **runtime.exs** - Reads connection config
  - Uses `:file.consult/1` to read connection.config
  - Applies node/cookie/mode settings
- [x] **Layouts** - Native Android UI
  - activity_pairing.xml - Dark theme pairing screen
  - activity_qr_scanner.xml - Camera preview with overlay
  - item_node.xml - Node list item
- [x] **AndroidManifest.xml** - Updated
  - Camera permission
  - PairingActivity as launcher
  - QrScannerActivity registered

### Remaining
- [ ] Test QR scanning end-to-end
- [ ] Update inetrc dynamically based on scanned host
- [ ] Handle connection failures gracefully (show error, allow retry)
- [ ] Status updates after connection attempt
- [ ] Display active node in main UX footer/watermark

## Android QR parsing
- Parse Erlang term string using Java regex (implemented in NodePreferences.parseQrPayload)
- Format: `{probnik_pair, 'node@host', cookie, [{mode, shortnames}]}`
- Validates node contains `@`

## Persistence
- SharedPreferences at `probnik_nodes`
- Fields per profile:
  - `node` (string)
  - `cookie` (string)
  - `mode` (string: "shortnames" | "longnames")
  - `lastConnected` (timestamp)
  - `lastStatus` (string)
- On app start:
  - Auto-connect to last active profile (implemented)

## Connection flow (Android)
1. PairingActivity starts
2. If active node exists → connect immediately
3. Otherwise show node list + scan button
4. On scan/select → write connection.config → start HostActivity
5. HostActivity initializes native → BEAM reads config → connects

## Error states to handle
- [x] Invalid QR payload (not Erlang term / missing fields) - shows toast
- [ ] Hostname invalid for current name mode
- [ ] Cookie mismatch / `:nodedown`
- [ ] Distribution not started / epmd not reachable

## Testing checklist
- [ ] Show QR in shell; scan successfully on Android
- [ ] Pairing persists across app restarts
- [ ] Auto-connect works on next launch
- [ ] Switching profiles reconnects correctly
- [ ] Invalid QR payload shows user-friendly error
