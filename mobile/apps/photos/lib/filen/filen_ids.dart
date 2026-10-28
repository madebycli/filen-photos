import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';

/// Fork-specific glue between Ente's gallery model and Filen's drive.
///
/// Ente identifies files and albums by integers, Filen by UUIDs. Instead of keeping a mapping
/// table, the integer is derived from the UUID and the UUID itself is stored in
/// [EnteFile.encryptedKey] (a field Filen files have no other use for, since Filen's SDK handles
/// all encryption). [kFilenKeyMarker] in [EnteFile.keyDecryptionNonce] tags such files.
const String kFilenKeyMarker = 'filen-v1';

/// Stored as Ente's "token" so Ente's own login checks pass; it is not a credential.
const String kFilenTokenMarker = 'filen-session';

/// Official Filen SDK release this build was made with (`--dart-define=FILEN_SDK_VERSION=...`).
const String kFilenSdkVersion = String.fromEnvironment(
  'FILEN_SDK_VERSION',
  defaultValue: 'unknown',
);

/// Direct child of the Filen drive root that holds the photo library.
const String kFilenPhotosRootName = 'Filen Photos';

/// Positive 60-bit integer taken from the leading hex digits of a UUID. UUIDv4 carries ~122
/// random bits, so collisions are negligible at photo-library scale.
int filenUuidToId(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length < 15 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
    throw ArgumentError.value(uuid, 'uuid', 'not a UUID');
  }
  return int.parse(hex.substring(0, 15), radix: 16);
}

bool isFilenFile(EnteFile file) =>
    file.keyDecryptionNonce == kFilenKeyMarker && file.encryptedKey != null;

/// The Filen UUID of a file that [isFilenFile].
String filenUuidOf(EnteFile file) {
  if (!isFilenFile(file)) {
    throw StateError('Not a Filen file: ${file.tag}');
  }
  return file.encryptedKey!;
}

/// The Filen folder UUID behind a collection that came from Filen, or null for other collections.
String? filenDirUuidOf(Collection collection) =>
    collection.keyDecryptionNonce == kFilenKeyMarker
    ? collection.encryptedKey
    : null;
