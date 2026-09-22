---
paths:
  - "lib/**"
  - "packages/camera_api/**"
---

# Mobile App — Screen & Client Orchestration Conventions

Scoped the same as [mobile-app.md](mobile-app.md). `camera_api` itself carries no business logic
(see its [API_REFERENCE.md](../../packages/camera_api/API_REFERENCE.md) and
[SETTINGS_API_GUIDE.md](../../packages/camera_api/SETTINGS_API_GUIDE.md), which document *what
each API call means on the camera*, not how the app decides to call it) — this file is the layer
above that: the app's own policy for orchestrating those calls and presenting their results to
the user. Root `CLAUDE.md`'s screen-docs/design-ID rule and client-code-integration rule still
apply here too.

## Caching capability/service-discovery responses — don't re-fetch on every screen open

Any ONVIF service-discovery response (`GetServices`) or capability/options-style response
(`GetMaskOptions`, `GetServiceCapabilities`, and any future `Get*Options` call) describes
something that cannot change between one request and the next within the same app session — it's
a static property of the camera's current firmware build, not per-request or mutable state.
Re-fetching it before every mutating call (e.g. resolving `GetServices` fresh before each
`CreateMask`/`SetMask`/`DeleteMask`) wastes round trips for no benefit, and on this hardware a
burst of requests can visibly stall other things talking to the same camera (e.g. RTSP/NVR
viewers) while it's in flight.

**Cache these at process lifetime, keyed by `CameraConnection.host` — in the app layer, not in
the `camera_api` client.** An instance-level cache isn't enough if the consuming widget
constructs a fresh client instance every time its screen mounts (and these screens construct one
per load *and* per Apply), so the cache has to survive across instances for the life of the app
process.

**This used to live inside the clients as `static` maps** (`MaskClient._endpointCacheByHost`/
`_optionsCacheByHost`). The 2026-09-07 `camera_api` drop deliberately removed that — the package
is now a pure network client with no caching of its own — so **those identifiers no longer exist
anywhere in the package** and must not be used as a reference. The app layer owns all three
halves now:

- `lib/app_state/camera_settings_cache.dart`'s `NetworkAnswerCache` — `Get*Options` **values**.
- `lib/app_state/camera_network.dart`'s `CameraNetwork` — the pooled **HTTPS connection** and the
  resolved **ONVIF Media2 endpoint**, both keyed by host. Every ONVIF client takes `httpClient:`
  and (for the five Media2 clients) `endpoint:`; **always pass both**. Omitting them costs two
  fresh TLS handshakes plus a `GetServices` round trip on every single operation, because each
  client builds its own `HttpClient` *and* nests an `OnvifDeviceClient` that builds another, and
  caches its resolved endpoint for its own instance lifetime only.

Use those two as the reference shape for any client that resolves a service endpoint, fetches an
options/capabilities response, or performs a create/update/delete mutation:

- Resolve `GetServices` once per camera host and reuse it for every subsequent call any client
  instance for that host makes.
- Cache `Get*Options`/`GetServiceCapabilities`-style responses the same way. Give the method a
  `forceRefresh` parameter (default `false`) so an explicit user action (a manual reload button)
  can still force a real round trip, while normal screen load/reload leaves it `false`.
- Provide a `static void debugClearCaches()` reset hook for tests — a process-lifetime static
  cache will silently leak state between test cases that reuse a fixed mock host unless each test
  clears it in `setUp()`.
- After a mutation call that itself reported success, update local/in-memory state directly
  instead of re-fetching to confirm — the app already knows the resulting state from what it just
  sent. Only re-fetch when the outcome is genuinely ambiguous (e.g. the mutation call timed out).
- **Never** apply this to state that's genuinely live/mutable (e.g. `GetMasks`'s actual mask
  list) — that must still be re-fetched whenever the screen needs current truth. The test is
  "can this response change without the user or app doing something" — a capability/endpoint
  answer can't; live state can.

## LAN/WAN transport selection for settings screens

Applies to any settings screen with both a LAN (ONVIF) and WAN (AWS IoT) client available.

1. **Which transport to use is decided by real connectivity, never by comparing IP addresses.**
   Try LAN first and only fall back to WAN after a genuine reachability failure — not by
   comparing the phone's current IP against a saved camera IP (fragile: VPNs, mobile hotspots,
   guest WiFi VLANs, or a camera whose LAN IP simply changed since onboarding would all give a
   wrong answer). Whatever component negotiates live view should track the most recently
   confirmed transport and thread it down to any settings screen opened from there.
2. **A settings entry point must be disabled, not just default to LAN, until that transport is
   actually known.** Silently defaulting an unknown transport to `false`/LAN makes every WAN-path
   control unreachable in practice no matter how the camera is actually connected — gate the
   entry point on the transport being known, not on a guessed default.
3. **On top of connectivity-based selection, a LAN Apply/Set request that fails should
   automatically retry over WAN before surfacing an error to the user** (when a WAN path is
   configured at all). A LAN Set can fail for reasons unrelated to the request itself (e.g. the
   camera being mid-firmware-update and briefly rejecting ONVIF calls) — retrying over WAN
   recovers from exactly that case instead of making the user notice and retry manually.
4. **Options/bounds queries (`Get*Options`-style capability responses, not the current value
   itself) are LAN-only, with exactly one exception.** A settings screen's normal load/reload
   should only ever call the LAN options client, regardless of transport — on WAN with nothing
   cached yet, show an explanatory message rather than attempting a WAN options fetch. The one
   allowed WAN options read is immediately after a WAN Apply/Set request itself fails — refresh
   the cached bounds from WAN at that point (a likely cause of the failure is the camera's bounds
   having changed since they were last cached), then still surface the original failure. This
   matters because options are cached as a capability (see above), not re-fetched per visit — a
   current-value read has no such restriction and may use either transport normally.
5. **A field's UI treatment (read-only label vs. editable picker) must be derived from what the
   camera's own Options response actually reports, never hardcoded in the client/screen code.**
   Don't bake in an assumption like "this firmware only ever has one valid choice" — parse every
   entry the camera reports and pick between a fixed label and a real picker based on the
   resulting list length at render time. Correct today if there's genuinely one choice, and still
   correct if a future firmware build ever reports more.
6. **Every settings screen that has a Set/Apply request must have a matching Options/capability
   request, on both transports, and the UI must be built from that response — never from a
   hardcoded assumption about what the camera supports.** If the LAN transport already has a
   `Get*Options`/`GetOptions` ONVIF call for a setting, the WAN command set for that same setting
   should expose an equivalent before the screen ships. A field is editable/shown as a picker
   only if the Options response says there's more than one supported value; otherwise it's a
   read-only label — never assume a fixed set of choices without confirming it against the live
   Options response.

## Settings/control screen UX conventions

Applies to any screen that reads a camera setting and lets the user change it. `lib/screens/
camera_settings/camera_settings_screen.dart` and its sub-screens are currently stubs — apply this
convention as each one gets built out with real `camera_api` integration, not just to screens
that already exist.

1. **Local pending edits, explicit Apply — never fire a request per tap/drag.** Every control
   edits an in-memory "pending" value only. A camera request is sent **only** when the user taps
   that section's Apply button, and only if the pending value actually differs from the last
   camera-confirmed ("applied") value — an unchanged apply wastes a request and, on WAN, a real
   round trip.
2. **Reset reverts locally, Reload re-fetches from the camera — they are not the same button.**
   Reset sets pending back to the last-loaded applied value with no network call (the
   already-loaded applied value doubles as the local cache). Reload is the only thing that talks
   to the camera to refresh what "applied" means. Load automatically on screen open (and screen
   re-entry) so Reload is rarely needed manually, but keep the manual button too — the user may
   want to confirm nothing changed out-of-band (another client, a scheduled mode change) without
   leaving the screen.
3. **Block the whole screen during any in-flight request, not just the section making it.** A
   full-screen overlay (dimmed background + spinner + status text) appears whenever any section
   has a request in flight, absorbing all touch input. Track this as a **counter**, not a bool —
   several sections can load concurrently on screen open, and a bool would flicker off after the
   first one finishes while others are still loading.
4. **A reference/preview image, if the screen has one, stays fixed outside the scrolling area**
   (a `Column` with the preview pinned above an `Expanded` scrollable list, not one more item
   inside the list) — and refreshes immediately after any section's Apply succeeds, not just on
   screen open. An unchanged preview after a successful apply reads as "nothing happened" even
   when the camera did confirm the change.
5. Value types used for pending/applied comparison must have real equality (Dart records, or a
   class with `==`/`hashCode` overridden) — a class relying on default identity equality will
   falsely show "unsaved changes" the moment a new instance is constructed with identical field
   values, even from selecting an already-selected option twice.

## Call-style screen UX conventions

Applies to any screen that presents a live, real-time session the user actively participates in
(currently: the Talk button on `CameraLiveScreen`, which is a local UI toggle only — no real
WebRTC session wired up yet). Apply this convention once that gets built out:

1. **The presentation opens before the session connects, not after.** It owns a
   `connecting → talking → (busy | error)` state machine and performs the actual connect call
   itself, so a slow or failing connection is visibly "Calling…" rather than nothing happening
   until success. Each state gets its own icon color/glyph and status text — busy (someone else
   already using the resource) is visually distinct from a hard error, both distinct from
   in-progress and connected — not just a single generic spinner-or-not toggle.
2. **Route-to-loudspeaker control, defaulted on.** Any two-way-audio session needs a way to make
   the far side's audio louder without the user fumbling for the phone's own hardware volume
   buttons — expose it as a call-style toggle button, defaulted on, since a quiet earpiece-routed
   default reads as "too quiet" on first open.
3. **A grace window before treating a transient ICE `disconnected` as a real drop.** On a LAN
   connection with no STUN/TURN (host candidates only), WebRTC's periodic consent-freshness check
   can routinely report a momentary `disconnected` on an otherwise healthy session — ending the
   call on the first such blip treats a normal hiccup as a hard failure. Wait a few seconds for
   recovery to `connected`/`completed` before tearing down.
4. **Every exit path funnels through one teardown method** (an explicit End/Close action, and the
   session dropping on its own via its connection-state stream) so there's no path that clears
   the panel/screen without also tearing down the underlying session.
5. **In-call settings (e.g. volume) belong on the call panel, not the idle tile** — shown only
   while the session is active, and not present at all when idle. Adjusting these values is only
   ever urgent *during* the session.
6. **A player-level mute (if relevant) is a separate, always-available control from the session's
   own audio.** A two-way-talk speakerphone toggle routes *outbound* call audio; a live view's
   own plain-playback mute (the video's own audio, independent of any call) is a different
   concern and deserves its own control — don't conflate the two.
7. **Before opening a second concurrent connection to the same camera for a new real-time
   feature, check whether the camera's signaling endpoint supports more than one connection at
   once.** Some embedded camera firmware supports exactly one active peer connection per
   signaling port and tears down whatever exists first on a new offer — opening an independent
   second connection assuming it can coexist with live view's own can cause the two to evict each
   other in a loop. If that turns out to be the case here, renegotiate the existing connection
   (add/change a transceiver, resend the offer) rather than opening a second one.

## Password field visibility toggle

Every password/secret entry field in this app should use a shared `PasswordFormField` widget
(e.g. `lib/widgets/password_form_field.dart`, matching this repo's `lib/widgets/` convention)
rather than a bare `TextFormField` with `obscureText: true`, so the show/hide (eye) icon is
consistent everywhere instead of each screen reimplementing its own toggle state.

**Not yet extracted in this repo** — `login_screen.dart`, `signup_screen.dart`,
`scanned_devices_screen.dart`, `account_settings_screen.dart`, `create_user_screen.dart`, and
`wifi_config_screen.dart` each currently use a bare `TextFormField(obscureText: ...)` with their
own local toggle state. Worth factoring out into a shared widget next time one of these screens is
touched, rather than adding a seventh copy of the same toggle logic. (`camera_info_screen.dart`'s
Modify Password dialog now uses `PasswordFormField`.)
