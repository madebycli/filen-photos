import "dart:io";

typedef MlFileDownloadAndLoader = Future<File?> Function();

/// Loads the file for ML. Filen's SDK verifies the data while downloading, so a failure is
/// reported as is and no retry loop is needed.
Future<File?> downloadAndLoadFileForMlWithDecryptionRetry(
  MlFileDownloadAndLoader downloadAndLoad,
) => downloadAndLoad();
