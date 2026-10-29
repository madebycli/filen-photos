# Filen backend for the Ente photos app (Android)

This fork keeps Ente's Android photos UI and on-device machine learning, and replaces the cloud with
[Filen](https://filen.io). **Filen is the only cloud.** The Ente account, server, payments, sharing,
casting, family, social and push code has been removed from `mobile/apps/photos`, not hidden.

| Path | What |
|------|------|
| `filen-rs/` | Git submodule: Filen's official SDK, **unmodified**, pinned to a release tag (`FILEN_VERSION`). AGPL-3.0. |
| `scripts/build-android-native.sh` | Builds `libfilen_sdk_rs.so` (arm64-v8a) with the feature set of Filen's own app (`uniffi,http-provider`) and generates the Kotlin bindings from that binary. |
| `scripts/update-filen-rs.sh` | Moves the submodule to a newer `filen-js@X.Y.Z` release. |
| `plugin/` | Flutter plugin (`filen_sdk`): Kotlin adapter over the generated bindings + Dart API. Contains no networking or crypto of its own. |
| `../mobile/apps/photos/lib/filen/` | Dart glue: account/session, Filen -> Ente model mapping, sync, file access, settings sync, login page. |
| `../mobile/apps/photos/lib/filen/state/` | The app's cloud state on Filen (see below). |

## How it plugs into the gallery

- `CollectionsService` is Filen-only: albums are Filen folders (`Filen Photos` root = *Uncategorized*, sub-folders =
  albums); favorites, hidden/archived state and other "virtual" albums are kept in the state folder.
- `DiffFetcher.getEncryptedFilesDiff` -> `FilenSyncService.getDiff`: compares the Filen listing with the local database
  and returns only changed rows; local photos that were already uploaded (same name, type and time) are linked instead
  of being inserted a second time, so signing in again with the same folders does not duplicate anything.
- `getFileFromServer` / thumbnails -> `FilenSdk.downloadFile` / `FilenSdk.thumbnail`; previews are cached in the state
  folder (`thumbs/`), videos get a frame from the SDK's stream URL.
- Ids: Ente integers are derived from Filen UUIDs (first 15 hex digits); the UUID is kept in `EnteFile.encryptedKey`.
- The Filen session (`StringifiedClient`) is stored in `flutter_secure_storage`; the password is never stored.

## What is stored on Filen besides the photos

Everything lives in `Filen Photos/.filen-photos/` (end-to-end encrypted by Filen, plain JSON inside), written
as revisioned files so two devices never overwrite each other:

| Folder | Content |
|--------|---------|
| `meta/` | what Filen files cannot hold: hash, GPS, duration, camera, edited date, magic metadata, captions |
| `collections/` | virtual albums, favorites, folder metadata, album membership |
| `entities/` | people (face clusters, names), saved places, smart albums |
| `ml/` | face/semantic embeddings per photo (so a new device does not re-run the models) |
| `thumbs/` | preview images |
| `settings/` | gallery/video/ML/backup preferences (whitelist in `filen_settings.dart`, three-way merge) |

## On-device ML, maps

- Models (face detection/embedding, CLIP) and the offline places database are static files from Ente's CDN
  (`models.ente.com`, `assets.ente.com`; no account, no user data sent). They are fetched by `filen_assets.dart`
  with a SHA-256 check and then used by Ente's unchanged Rust ML code.
- ML consent and the map switch are local settings (`filen.ml_consent`, `filen.map_enabled`), no server round trip.
- The map uses OpenStreetMap tiles (identified as "Filen Photos").
- No server-side AI or online-only feature is present.

## Known gaps (honest status)

- Nothing here has been verified against a live Filen account by the author; the last on-device feedback came from
  an earlier build. Treat every item below as "implemented, needs a device check" unless noted.
- Not available for Filen (removed, not faked): shared albums/links/feed, family/legacy/cast/referrals/payments,
  Ente account screens, server-side thumbnails/previews.
- Permanent deletion of user photos happens only from the trash page after confirmation; "empty trash" only deletes
  the photos/videos shown there.
- Edits of already uploaded photos are not re-uploaded (no in-place update yet).
- The library lives in the fixed Filen folder `Filen Photos`; choosing another cloud folder is not planned.
- Background backup is Ente's WorkManager task; there is no on/off switch for it (not planned).
- armeabi-v7a is not supported (Filen builds arm64-v8a/x86_64 only).
- Some Ente wording remains in translated strings of the shared `strings` package.

## Updating and releasing

- **Filen SDK (automatic, weekly)**: `filen-sdk-update.yml` bumps the submodule to the newest `filen-js@X.Y.Z` release
  on a branch, runs `filen-android.yml` (analyze, unit tests, signed arm64 APK) and, only if that passes,
  fast-forwards `main` and publishes a GitHub **pre-release** with the APK. If anything fails nothing is merged and a
  draft PR is left. Set the repository variable `FILEN_AUTO_MERGE=false` to always get a draft PR instead.
  GitHub Actions must be enabled in the fork for this to run; it has not been run yet.
- **Signing**: set the secrets `FILEN_PHOTOS_KEYSTORE_B64`, `FILEN_PHOTOS_KEY_ALIAS`, `FILEN_PHOTOS_KEY_PASSWORD`,
  `FILEN_PHOTOS_STORE_PASSWORD`; without them CI signs with a throw-away key (APKs then cannot update each other).
- **Ente UI (manual)**: `git remote add upstream https://github.com/ente/ente && git merge upstream/main`;
  expect conflicts wherever Ente cloud code was removed (collections, sync, upload, settings) - resolve towards the
  Filen version and keep upstream UI/ML improvements.
- **One-time**: run the *Filen fork setup* workflow to disable inherited non-Android upstream workflows.
