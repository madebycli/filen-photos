import 'package:photos/models/file/file.dart';
import 'package:photos/services/collections_service.dart';

class DuplicateFiles {
  final List<EnteFile> files;
  final int size;
  final Set<int> collectionIDs;
  static final collectionsService = CollectionsService.instance;

  DuplicateFiles(this.files, this.size, this.collectionIDs) {
    sortByCollectionName();
  }
  List<EnteFile> sortByLocalIDs() {
    final List<EnteFile> filesWithoutLocalID = [];
    final List<EnteFile> localFiles = [];
    for (final file in files) {
      if ((file.localID ?? '').isEmpty) {
        localFiles.add(file);
      } else {
        filesWithoutLocalID.add(file);
      }
    }
    localFiles.addAll(filesWithoutLocalID);
    return localFiles;
  }

  @override
  String toString() => 'DuplicateFiles(files: $files, size: $size)';

  void sortByCollectionName() {
    files.sort((first, second) {
      final firstName = collectionsService
          .getCollectionByID(first.collectionID!)!
          .displayName;
      final secondName = collectionsService
          .getCollectionByID(second.collectionID!)!
          .displayName;
      return firstName.compareTo(secondName);
    });
  }
}
