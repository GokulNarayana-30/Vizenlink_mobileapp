# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# mobilecctvapp

A Flutter mobile app for viewing/managing CCTV camera feeds (VizenLink/NuraEye cameras). Scope and core features (live view, playback, alerts, etc.) derive from `VizenLink_Home_Community_CCTV_Feature_Seed_v0.1.md` and the `scenarios/`/`features/` specs.

## Commands

Run from the repo root unless noted.

- `flutter analyze && dart format --output=none --set-exit-if-changed lib test` — lint/format gate (same as the `flutter-lint` skill). Run before considering any Dart change done. **Scoped to `lib`/`test` deliberately** — `packages/camera_api` keeps the senior engineer's own formatting verbatim (an older formatter at ~100 columns, vs this SDK's tall style at 80), so that each incoming drop stays a clean diff against their copy. Running the gate over `.` would rewrite ~112 package files and silently undo that.
- `flutter test` — run the app's widget/unit tests (`test/widget_test.dart`).
- `flutter test test/widget_test.dart --plain-name "Dashboard is the initial route"` — run a single test by name.
- `flutter run` — run the app on a connected device/simulator/desktop/web target (see `flutter-run` skill).
- `flutter build apk` / `flutter build appbundle` / `flutter build ipa` — release artifacts (see `flutter-release` skill).
- `flutter pub get` — after pulling changes that touch `pubspec.yaml`.

`packages/camera_api` is a separate pure-Dart package with its own test suite:
- `cd packages/camera_api && flutter test` — run its tests (mock-based, no real camera needed).
- `cd packages/camera_api && dart test test/mask_client_test.dart` — run a single file.

## Architecture

**State management**: no external state-management package — plain `ValueNotifier<State>` subclasses in `lib/app_state/` (e.g. `HomesController extends ValueNotifier<HomesState>`), instantiated once in `_MobileCctvAppState` (`lib/main.dart`) and passed down explicitly through widget constructors. There is no DI framework/service locator; a screen that needs a controller receives it as a constructor parameter from its `GoRoute` builder.

**Routing**: `go_router`, built in `main.dart`'s `_buildRouter()`. Top-level routes (`/splash`, `/login`, `/signup`) sit outside a `StatefulShellRoute.indexedStack` (`MainShell`) with four branches — Dashboard, Alerts, Events, Account — each an independently-nested route tree (e.g. camera live → camera settings → video display → video mode). Screens needing a data object (a `Camera`, `Alert`, `RecordedEvent`) receive it via `state.extra`, cast at the route builder.

**`packages/camera_api`** is the sole network-access layer for talking to a NuraEye/VizenLink camera, as a separate pure-Dart package (zero `package:flutter` dependency) consumed via a `path:` pubspec dependency. It has no UI or app-decision logic — every call returns a typed `CameraResult<T>` (`CameraSuccess`/`CameraFailure`/`CameraTimeout`) rather than throwing. Two transport families live side by side:
- `lib/src/lan/onvif/` — ONVIF SOAP clients (WS-UsernameToken digest auth) for on-LAN control.
- `lib/src/lan/nuraeye/` — the camera's proprietary `/nuraeye/*` REST API (some files are generated — `rest_*.dart`, `nuraeye_rest_client.dart`).
- `lib/src/wan/` — AWS IoT MQTT command relay + Kinesis Video Streams (KVS) playback, for off-LAN control/streaming.

Full client-by-client reference: `packages/camera_api/API_REFERENCE.md`; which client/capability flag to use for a given setting: `packages/camera_api/SETTINGS_API_GUIDE.md`. The app-side policy for *how* screens call these clients (LAN-vs-WAN selection, caching capability responses, retry-on-failure, settings-screen Apply/Reset/Reload UX, call-style session UX) is documented in `.claude/rules/mobile-app-screen-conventions.md`, not in the package itself. Build/branding/lint/SDK conventions (not yet applied: VizenLink branding rename, explicit Android SDK version pinning) live in `.claude/rules/mobile-app.md`. **Any actual change to `packages/camera_api/**` requires the user's explicit confirmation first** — see `.claude/rules/api-change-confirmation.md`.

**Design-ID convention**: every interactive/documented UI element carries a stable `key: const Key('<SCREEN-PREFIX>-NNN')`, matched 1:1 to a row in that screen's `docs/screens/**/*.md` file — see the Screen documentation rule below before touching screen code.

## Project structure

- `lib/` — Dart application source: `screens/` (route-level widgets), `widgets/` (reusable components), `app_state/` (`ValueNotifier`-based controllers), `models/`, `theme/`, `utils/`.
- `packages/camera_api/` — pure-Dart camera network client package (see Architecture above); has its own `pubspec.yaml`, tests, and `API_REFERENCE.md`/`SETTINGS_API_GUIDE.md`.
- `docs/screens/` — one markdown file per screen, design-ID tables (see Screen documentation rule).
- `docs/client_code/` — per-file reference tables documenting client Dart files (functions/classes/purpose), generated by the `client-code-docs` skill. Separate from `docs/screens/`.
- `test/` — Dart/Flutter tests (`flutter test`).
- `android/`, `ios/`, `macos/`, `linux/`, `windows/`, `web/` — platform runner projects generated by `flutter create`. Avoid hand-editing generated files unless configuring platform-specific permissions (e.g. camera/network permissions in `Info.plist` / `AndroidManifest.xml`).
- `client_code_inbox/` — drop location for Dart files shared by the senior engineer (client logic/data/state); staging only, not part of the app build. See `client-code-docs` and `integrate-client-code` skills.
- `VizenLink_Home_Community_CCTV_Feature_Seed_v0.1.md` — raw product vision doc; every feature/scenario below derives from it. Background context only for `scenario-gap-audit`, not itself a gap-report source.
- `scenarios/`, `features/` — product spec as structured markdown (one scenario/feature file per capability, each folder indexed in its own `INDEX.md`), dropped in manually. `scenarios/` includes both `mobile-app-*` and `vms-*` files — only `mobile-app-*` (`Component = mobile-app` in the index) applies to this app. Requirements reference for `scenario-gap-audit`.
- `knowledgebase/_research_cache/` — condensed extraction of the seed doc + `scenarios/`+`features/` plus a manifest, written and read only by `scenario-gap-audit` to avoid re-reading unchanged files every run. Safe to delete; forces a cold-start rebuild.
- `pubspec.yaml` — dependencies and app metadata.
- `analysis_options.yaml` — lint rules (uses `flutter_lints`).

## Conventions

- Package name: `com.onchiptech.mobilecctvapp`.
- Follow standard Dart/Flutter style — enforced via `flutter analyze` and `dart format`. Use the `flutter-lint` skill before considering work done.
- Prefer `flutter test` for unit/widget tests.
- State management is plain `ValueNotifier` controllers in `lib/app_state/` (see Architecture above) — this has already been decided; don't introduce Provider/Riverpod/Bloc without confirming with the user first.
- Camera integration is via `packages/camera_api` (ONVIF over LAN, AWS IoT/KVS over WAN) — this has already been decided; confirm with the user before adding a different/competing CCTV protocol or streaming dependency.

## Screen documentation rule

Every screen (route-level widget) must have a companion markdown file in `docs/screens/`, and every documented UI element must have a stable design ID (`<SCREEN-PREFIX>-NNN`, e.g. `LOGIN-001`) referenced in code via `key: const Key('LOGIN-001')`. Use the `screen-docs` skill whenever adding a new screen or changing elements on an existing one. Template: `docs/screens/_TEMPLATE.md`.

## Plan-before-code rule

Before writing any code for a new screen, first present the element inventory (list of every field/button/label/etc. the screen needs, i.e. the draft `docs/screens/<subfolder>/<name>.md` table) and get user confirmation. Do not write Dart code for a screen until the user has confirmed its element list. This keeps the design ID table and the code in sync from the start instead of reconciling after the fact.

## Client-code integration rule

A senior engineer separately builds the app's client code (business logic/data/state) and shares Dart files for integration. Drop shared files into `client_code_inbox/` (staging only, not part of the build). Rules for integrating them:

- Client code is source of truth for logic/data/state; the existing UI is source of truth for navigation, layout, screen boundaries, and design IDs.
- Existing screen boundaries always win — if a client file bundles features already split across separate screens (e.g. night mode + imaging settings), split its logic across those screens rather than merging or restructuring the UI to match the client file's grouping.
- Never modify a client file unless a change is genuinely unavoidable — if so, stop and flag the specific reason to the user before editing, rather than changing it silently.
- Document a client file (`client-code-docs`) before integrating it if it isn't already documented in `docs/client_code/`.
- After integrating, re-sync the relevant `docs/screens/**/*.md` files and design IDs (`screen-docs`) if UI elements changed, then run `flutter-lint`.

Use `client-code-docs`, `integrate-client-code`, or the combined `client-pipeline` command for this workflow.

## Skills

- `flutter-run` — build and run the app on a connected device/simulator/desktop/web target.
- `flutter-lint` — run `flutter analyze` + `dart format` as a quality gate.
- `flutter-release` — produce release build artifacts (APK/AAB for Android, IPA for iOS).
- `screen-docs` — create/update per-screen markdown docs and design IDs.
- `client-code-docs` — document a senior engineer's client Dart file (functions/classes) as a markdown table in `docs/client_code/`.
- `integrate-client-code` — wire a client Dart file's logic/data into the existing UI without modifying the client file unless unavoidable.
- `scenario-gap-audit` — cross-reference this workspace's `scenarios/`+`features/` against `lib/screens/` and report what's implemented/partial/missing.
- `ui-api-gap-audit` — cross-reference built UI screens against documented client/API code (`docs/client_code/`) to find screens still running on mock data vs. really wired up.

## Commands (slash)

- `/client-code-docs <filename.dart>` — document a file from `client_code_inbox/`.
- `/integrate-client-code <filename.dart>` — integrate a file from `client_code_inbox/` into the existing UI.
- `/client-pipeline <filename.dart>` — full chain: doc → integrate → screen-docs sync → lint → run.
- `/scenario-gap-audit` — generate `docs/scenario_audit/gap_report.md` comparing `scenarios/`+`features/` against current screens.
- `/ui-api-gap-audit` — generate `docs/api_coverage_audit/gap_report.md` comparing built screens against documented client/API code.
- `/art-refine <prompt or .claude/ path>` — restructure a prompt into ART format, preview, then execute on approval.
- `/git-push` — push the current branch to its remote, after checking status and confirming anything risky.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
