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

- **No upload yet**: device photos are not backed up to Filen; the library is read-only in the app.
- Videos have no thumbnails (the SDK cannot make them); videos play after download.
- Ente-only account screens (subscription, recovery key, sessions, family...) are still present and
  talk to Ente servers; they must be removed or mapped to Filen features.
- armeabi-v7a is not supported (Filen builds arm64-v8a/x86_64 only).
- Nothing here has been run against a live Filen account yet.

## Updating

- Filen: the *Filen SDK update* workflow opens a draft PR with a bumped submodule and a test build.
- Ente: `git remote add upstream https://github.com/ente/ente && git merge upstream/main`;
  conflicts are expected only in the few `Filen fork:` seams.
- One-time: run the *Filen fork setup* workflow to disable inherited non-Android upstream workflows.
