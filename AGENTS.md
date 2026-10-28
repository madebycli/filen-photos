# AGENTS.md — Filen Photos (Android only)

Fork of Ente's Android photos app (Flutter) that uses **Filen** as its only cloud. Read
`.ai/CONTEXT.md` first and follow its route to the private project context (master-context);
it holds status, decisions and the resume point. Fork docs: `filen/README.md`.

## Hard limits

- **Android only.** No iOS/web/desktop/server work, builds, tests or CI. Only `mobile/apps/photos` and
  the packages it needs matter; the rest of the Ente monorepo stays as upstream source.
- **No own crypto/network code for Filen.** Everything goes through the unmodified official SDK
  (`filen/filen-rs` submodule, pinned in `filen/FILEN_VERSION`). Never edit files inside it.
- Never log or commit credentials/session data; never use a real photo archive in tests.
- Keep edits to upstream Ente files tiny and marked `Filen fork:`; put new code under
  `mobile/apps/photos/lib/filen/`, `filen/` or `.github/workflows/filen-*`.
- No UI that pretends: a Filen feature that does not exist is removed or labelled, not faked.

## Commands (run from `mobile/apps/photos` unless noted)

```bash
git submodule update --init filen/filen-rs        # repo root
(cd mobile && flutter pub get)
(cd rust && cargo codegen frb photos)             # generates lib/src/rust (gitignored), needed for analyze/test
dart analyze lib/filen test/filen
flutter test test/filen
filen/scripts/build-android-native.sh             # repo root; SDK -> .so + Kotlin bindings (needs NDK, cargo-ndk 4)
flutter build apk --release --flavor independent --target-platform android-arm64
```

Signing for the APK build comes from `SIGNING_KEY_PATH/_ALIAS/_PASSWORD`, `SIGNING_STORE_PASSWORD`.
Host-side Filen tooling needs `RUSTFLAGS=-Zhigher-ranked-assumptions` if the `wild` linker is absent
(the build script sets it for the bindgen step).

## Where things are

- Seams into Ente (search `Filen fork`): `collections_service.dart` (`_fetchCollections`),
  `diff_fetcher.dart`, `module/download/{file,thumbnail}.dart`, `remote_sync_service.dart`,
  `configuration.dart` (restore/logout), `landing_page_widget.dart`.
- Updates: `.github/workflows/filen-sdk-update.yml` (Filen), merge `ente/ente` upstream by hand.
