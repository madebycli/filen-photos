class DownloadFailedError implements Exception {
  final String message;

  DownloadFailedError(this.message);

  @override
  String toString() => message;
}
