import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';

/// Where Android keeps the app data a user may want to reach from a computer:
/// the downloads database, downloaded media, and offline artwork.
///
/// Resolves to the app's external files directory
/// (`/storage/emulated/0/Android/data/<applicationId>/files`), which is
/// reachable over USB (MTP) and `adb`, needs no runtime permission, and is
/// still private to the app and removed on uninstall. Keeping the database,
/// `downloads/`, and `artwork/` together under one reachable root mirrors the
/// desktop layout (everything under Application Support, database paths stored
/// relative to that root), so a desktop install's data can be copied straight
/// in — or out.
///
/// Falls back to the internal documents directory when external storage is
/// unavailable. The lookup is memoized so every subsystem anchors to the same
/// directory for the lifetime of the process, even if storage availability
/// changes mid-run.
Future<Directory> androidAccessibleDataDirectory() => _androidAccessibleDataDirectory ??= _resolve();

/// Directory that holds `plezy_downloads.db` and the portable files that must
/// travel with it (the credential vault key file). Desktop anchors to the
/// application support directory, iOS/tvOS to the documents directory, and
/// Android to the user-reachable external files directory — the same split as
/// `DownloadStorageService`'s base app dir, so database, key, downloads, and
/// artwork always sit under one copyable root.
Future<Directory> appDataBaseDirectory() {
  if (Platform.isAndroid) return androidAccessibleDataDirectory();
  if (Platform.isIOS) return getApplicationDocumentsDirectory();
  return getApplicationSupportDirectory();
}

Future<Directory>? _androidAccessibleDataDirectory;

Future<Directory> _resolve() async {
  try {
    final external = await getExternalStorageDirectory();
    if (external != null) return external;
    appLogger.w('External storage unavailable; keeping app data in the internal documents directory');
  } catch (e, st) {
    appLogger.w(
      'External storage lookup failed; keeping app data in the internal documents directory',
      error: e,
      stackTrace: st,
    );
  }
  return getApplicationDocumentsDirectory();
}

/// Moves every file under [source] into the same relative location under
/// [target], creating directories as needed, then removes emptied source
/// directories. Used for the one-time relocation of legacy app data; the two
/// roots sit on different mount points (internal `/data` vs the FUSE-backed
/// external volume), so a failed rename falls back to copy-then-delete. The
/// copy lands under a temporary sibling name and is published with an atomic
/// rename, so a crash mid-copy never leaves a truncated file at the real
/// destination. Files already present at the target win — the target is the
/// live location by the time this runs. Failures are logged and skipped so one
/// bad file never aborts the rest of the move.
Future<void> moveDirectoryContentsBestEffort(Directory source, Directory target) async {
  if (!await source.exists()) return;
  await for (final entity in source.list(recursive: false, followLinks: false)) {
    final destinationPath = p.join(target.path, p.basename(entity.path));
    try {
      if (entity is Directory) {
        await moveDirectoryContentsBestEffort(entity, Directory(destinationPath));
      } else if (entity is File) {
        await _moveFile(entity, destinationPath, target);
      }
    } catch (e, st) {
      appLogger.w('Failed to move ${entity.path} → $destinationPath', error: e, stackTrace: st);
    }
  }
  try {
    if (await source.list().isEmpty) await source.delete();
  } catch (_) {
    // A leftover empty directory is harmless.
  }
}

Future<void> _moveFile(File source, String destinationPath, Directory targetDir) async {
  await targetDir.create(recursive: true);
  if (await File(destinationPath).exists()) {
    await source.delete();
    return;
  }
  try {
    await source.rename(destinationPath);
    return;
  } on FileSystemException {
    // Cross-device rename (EXDEV) — fall through to copy.
  }
  final temporary = File('$destinationPath.migrating');
  if (await temporary.exists()) await temporary.delete();
  await source.copy(temporary.path);
  await temporary.rename(destinationPath);
  await source.delete();
}
