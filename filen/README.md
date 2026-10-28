# Filen backend for the Ente photos app (Android)

This fork keeps Ente's Android photos UI and replaces the cloud with [Filen](https://filen.io).

| Path | What |
|------|------|
| `filen-rs/` | Git submodule: Filen's official SDK, **unmodified**, pinned to a release tag (`FILEN_VERSION`). AGPL-3.0. |
| `scripts/build-android-native.sh` | Builds `libfilen_sdk_rs.so` (arm64-v8a) with the feature set of Filen's own app (`uniffi,http-provider`) and generates the Kotlin bindings from that binary. |
| `scripts/update-filen-rs.sh` | Moves the submodule to a newer `filen-js@X.Y.Z` release. |
| `plugin/` | Flutter plugin (`filen_sdk`): Kotlin adapter over the generated bindings + Dart API. Contains no networking or crypto. |
| `../mobile/apps/photos/lib/filen/` | Dart glue: account/session, Filen -> Ente model mapping, sync, file access, login page. |

## How it plugs into Ente

Ente syncs per collection (album) with a "diff". The fork keeps that machinery and swaps the data source:

- `CollectionsService._fetchCollections` -> Filen folders (`Filen Photos` root = *Uncategorized*, sub-folders = albums).
- `DiffFetcher.getEncryptedFilesDiff` -> compares the Filen listing with the local database.
- `getFileFromServer` / thumbnail download -> `FilenSdk.downloadFile` / `FilenSdk.thumbnail`.
- Ids: Ente integers are derived from Filen UUIDs; the UUID is kept in `EnteFile.encryptedKey`.
- The Filen session (`StringifiedClient`) is stored in `flutter_secure_storage`; the password is never stored.

## Known gaps (honest status)

- Works through Filen: login (+2FA), browsing/sync of `Filen Photos`, thumbnails, originals, backup of selected
  device folders, delete (-> Filen trash), move between albums, quota.
- Not available for Filen accounts (hidden): shared albums/feed, links, favorites, archive/hide, metadata edits,
  people tagging, family/legacy/cast/referrals, free-up-space, Ente trash screen.
- Videos have no thumbnails (the SDK cannot make them); no transfer progress, no upload resume;
  edits of already uploaded photos are not re-uploaded.
- Ente leftovers still present: `Ente` wording in non-English strings and some screens, the other Ente apps in the
  monorepo (kept as merge base only), model/asset downloads from Ente's CDN for the on-device ML.
- armeabi-v7a is not supported (Filen builds arm64-v8a/x86_64 only).
- Nothing here has been run against a live Filen account yet.

## Updating and releasing

- **Filen SDK (automatic, weekly)**: `filen-sdk-update.yml` bumps the submodule to the newest `filen-js@X.Y.Z` release
  on a branch, runs `filen-android.yml` (analyze, unit tests, signed arm64 APK) and, only if that passes,
  fast-forwards `main` and publishes a GitHub **pre-release** with the APK. If anything fails nothing is merged and a
  draft PR is left. Set the repository variable `FILEN_AUTO_MERGE=false` to always get a draft PR instead.
- **Signing**: set the secrets `FILEN_PHOTOS_KEYSTORE_B64`, `FILEN_PHOTOS_KEY_ALIAS`, `FILEN_PHOTOS_KEY_PASSWORD`,
  `FILEN_PHOTOS_STORE_PASSWORD`; without them CI signs with a throw-away key (APKs then cannot update each other).
- **Ente UI (manual)**: `git remote add upstream https://github.com/ente/ente && git merge upstream/main`;
  conflicts are expected only in the few `Filen fork:` seams.
- **One-time**: run the *Filen fork setup* workflow to disable inherited non-Android upstream workflows.
