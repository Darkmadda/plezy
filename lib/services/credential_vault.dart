import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../utils/app_logger.dart';
import 'app_data_directories.dart';
import 'base_shared_preferences_service.dart';
import 'sensitive_prefs.dart';

/// Encrypts credentials before they are persisted in Drift config/token
/// columns. The database no longer stores raw server tokens; registries
/// decrypt at their boundaries and rewrite legacy plaintext values on read.
///
/// Security model: the key is stored in a `credential_vault.key` file next to
/// the database (with a legacy/mirror copy in SharedPreferences), so this is
/// obfuscation-at-rest against casual database inspection/export rather than
/// OS-backed Keychain/Keystore protection. Anyone with full access to the app
/// data directory can recover the tokens.
///
/// The key file travels with the database: copying the app data directory
/// between installs (e.g. desktop → Android) keeps every stored token
/// decryptable instead of orphaning them behind the old install's
/// preferences-only key. A key file that disagrees with preferences is
/// canonical — it pairs with whatever database sits beside it.
class CredentialVault {
  CredentialVault._();

  static const String _keyPref = credentialVaultKeyPref;
  static const String _keyFileName = 'credential_vault.key';
  static const String _prefix = 'enc:v1:';
  static final AesGcm _algorithm = AesGcm.with256bits();
  static Future<SecretKey>? _secretKey;

  /// Test seam for the key-file directory. Production resolution uses
  /// [initializeKeyFileLocation]; tests that want key-file behavior set this
  /// instead — everything else runs preferences-only with no file I/O.
  @visibleForTesting
  static Future<Directory> Function()? keyFileDirectoryOverride;

  static Future<Directory>? _keyFileDirectory;

  /// Eagerly resolves (and memoizes) the directory holding the key file.
  /// Called once during startup bootstrap, before the first database token is
  /// revealed. Deliberately the ONLY place that touches path_provider: a
  /// platform-channel lookup triggered lazily from inside a widget test's
  /// fake-async zone never gets its reply and would hang the caller, so
  /// [_resolveKeyFile] consumes only this pre-resolved value (or the test
  /// override) and uninitialized environments degrade to preferences-only.
  /// Never throws — a failed lookup just disables key-file portability.
  static Future<void> initializeKeyFileLocation() async {
    try {
      _keyFileDirectory ??= appDataBaseDirectory();
      await _keyFileDirectory;
    } catch (e) {
      appLogger.w('CredentialVault: key file location unavailable, using preferences only', error: e);
      _keyFileDirectory = null;
    }
  }

  /// Drops the memoized key so tests can simulate key loss/divergence.
  @visibleForTesting
  static void resetKeyForTesting() {
    _secretKey = null;
  }

  static bool isProtected(String? value) => value != null && value.startsWith(_prefix);

  static Future<String> protect(String value) async {
    if (value.isEmpty || isProtected(value)) return value;
    final key = await _getSecretKey();
    final box = await _algorithm.encrypt(utf8.encode(value), secretKey: key);
    return '$_prefix${jsonEncode({'n': base64Encode(box.nonce), 'c': base64Encode(box.cipherText), 'm': base64Encode(box.mac.bytes)})}';
  }

  /// Decrypts a protected value, or returns it unchanged when it isn't
  /// protected. Returns null when decryption fails — a failed MAC check
  /// (key/ciphertext divergence: restored backup, clobbered prefs, racing
  /// key generation) or a corrupt payload means the credential is *lost*,
  /// never a reason to crash; callers treat null as "re-acquire the token".
  static Future<String?> reveal(String value) async {
    if (!isProtected(value)) return value;
    try {
      final payload = jsonDecode(value.substring(_prefix.length)) as Map<String, dynamic>;
      final box = SecretBox(
        base64Decode(payload['c'] as String),
        nonce: base64Decode(payload['n'] as String),
        mac: Mac(base64Decode(payload['m'] as String)),
      );
      final clear = await _algorithm.decrypt(box, secretKey: await _getSecretKey());
      return utf8.decode(clear);
    } catch (e) {
      appLogger.w('CredentialVault: failed to decrypt stored credential, treating as lost', error: e);
      return null;
    }
  }

  static Future<Map<String, Object?>> protectConnectionConfig(String kind, Map<String, Object?> config) async {
    final copy = Map<String, Object?>.from(config);
    final tokenKey = _tokenKeyForKind(kind);
    final token = tokenKey == null ? null : copy[tokenKey];
    if (token is String) copy[tokenKey!] = await protect(token);
    if (kind == 'plex') {
      copy['servers'] = await _protectPlexServers(copy['servers']);
    }
    return copy;
  }

  static Future<({Map<String, dynamic> config, bool migrated})> revealConnectionConfig(
    String kind,
    Map<String, dynamic> config,
  ) async {
    final copy = Map<String, dynamic>.from(config);
    final tokenKey = _tokenKeyForKind(kind);
    var migrated = false;
    final token = tokenKey == null ? null : copy[tokenKey];
    if (token is String && token.isNotEmpty) {
      final revealed = await reveal(token);
      // An undecryptable token becomes the empty string — the shared
      // "no credential, re-auth" shape — and must not be rewritten back.
      migrated = revealed != null && !isProtected(token);
      copy[tokenKey!] = revealed ?? '';
    }
    if (kind == 'plex') {
      final result = await _revealPlexServers(copy['servers']);
      copy['servers'] = result.servers;
      migrated = migrated || result.migrated;
    }
    return (config: copy, migrated: migrated);
  }

  /// Config key holding the long-lived credential for a `connections.kind`
  /// value. Returning `null` means "nothing to encrypt", so every new kind MUST
  /// be listed here — an omission silently persists the token in plaintext.
  static String? _tokenKeyForKind(String kind) => switch (kind) {
    'plex' => 'accountToken',
    'jellyfin' || 'emby' => 'accessToken',
    _ => null,
  };

  static Future<Object?> _protectPlexServers(Object? rawServers) async {
    if (rawServers is! List) return rawServers;
    final servers = <Object?>[];
    for (final raw in rawServers) {
      if (raw is! Map) {
        servers.add(raw);
        continue;
      }
      final server = Map<String, Object?>.from(raw);
      final token = server['accessToken'];
      if (token is String) server['accessToken'] = await protect(token);
      servers.add(server);
    }
    return servers;
  }

  static Future<({Object? servers, bool migrated})> _revealPlexServers(Object? rawServers) async {
    if (rawServers is! List) return (servers: rawServers, migrated: false);
    var migrated = false;
    final servers = <Object?>[];
    for (final raw in rawServers) {
      if (raw is! Map) {
        servers.add(raw);
        continue;
      }
      final server = Map<String, dynamic>.from(raw);
      final token = server['accessToken'];
      if (token is String && token.isNotEmpty) {
        final revealed = await reveal(token);
        migrated = migrated || (revealed != null && !isProtected(token));
        server['accessToken'] = revealed ?? '';
      }
      servers.add(server);
    }
    return (servers: servers, migrated: migrated);
  }

  static Future<SecretKey> _getSecretKey() {
    return _secretKey ??= () async {
      final keyFile = await _resolveKeyFile();

      // A present key file wins outright: it was written next to (and pairs
      // with) the database, possibly on another install. Preferences are
      // mirrored so legacy readers and the #1732 repair flows stay coherent.
      final fileKey = await _readKeyFile(keyFile);
      if (fileKey != null) {
        await _mirrorKeyToPrefs(fileKey);
        return SecretKey(base64Decode(fileKey));
      }

      final adopted = await _loadOrCreatePrefsKey();
      await _writeKeyFileIfAbsent(keyFile, adopted.encoded);
      return adopted.key;
    }();
  }

  static Future<({SecretKey key, String encoded})> _loadOrCreatePrefsKey() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    // The cached snapshot can predate a key written by another isolate
    // (background downloader, first-run migration); generating "fresh" over
    // it would clobber the real key and orphan every stored ciphertext.
    // Reload before deciding, and after writing re-read and adopt whatever
    // actually landed so all isolates converge on a single key.
    try {
      await prefs.reloadCache();
    } catch (e) {
      appLogger.d('CredentialVault: prefs reload before key check failed', error: e);
    }
    // Tolerant read: a wrong-typed key must surface as a repairable
    // failure, not be mistaken for 'no key yet' and silently replaced —
    // that would orphan every ciphertext in the database (#1732).
    final stored = readTolerantString(prefs, _keyPref);
    if (stored != null && stored.isNotEmpty) {
      return (key: SecretKey(base64Decode(stored)), encoded: stored);
    }
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    await prefs.setString(_keyPref, base64Encode(bytes));
    try {
      await prefs.reloadCache();
    } catch (e) {
      appLogger.d('CredentialVault: prefs re-read after key write failed', error: e);
    }
    // Outside the catch: if another isolate raced us and left a wrong-typed
    // value, swallowing it here would return a key that never durably
    // landed, and every ciphertext written under it would be unreadable on
    // the next launch. Surface it for repair instead (#1732).
    final settled = readTolerantString(prefs, _keyPref);
    if (settled != null && settled.isNotEmpty) {
      return (key: SecretKey(base64Decode(settled)), encoded: settled);
    }
    return (key: SecretKey(bytes), encoded: base64Encode(bytes));
  }

  static Future<File?> _resolveKeyFile() async {
    try {
      final pending = keyFileDirectoryOverride?.call() ?? _keyFileDirectory;
      // Not initialized (tests, or a failed startup lookup) — the vault
      // degrades to the preferences-only behavior it always had.
      if (pending == null) return null;
      final dir = await pending;
      return File(p.join(dir.path, _keyFileName));
    } catch (e) {
      appLogger.d('CredentialVault: key file location unavailable, using preferences only', error: e);
      return null;
    }
  }

  /// Reads and validates the key file, or null when absent/unreadable. An
  /// unreadable file is only logged: decryption with a fallback key that does
  /// not match simply yields "credential lost" downstream, never a crash.
  static Future<String?> _readKeyFile(File? file) async {
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final content = (await file.readAsString()).trim();
      if (content.isEmpty) return null;
      base64Decode(content);
      return content;
    } catch (e) {
      appLogger.w('CredentialVault: unreadable key file, falling back to preferences', error: e);
      return null;
    }
  }

  /// Publishes [encoded] as the key file unless one already exists. Exclusive
  /// create keeps concurrent isolates from clobbering a key another install
  /// copied in; losing the race is fine — the existing file is canonical and
  /// is adopted on the next launch, while this process keeps the prefs key it
  /// resolved (they only diverge in the copied-database scenario, where the
  /// database is being replaced anyway).
  static Future<void> _writeKeyFileIfAbsent(File? file, String encoded) async {
    if (file == null) return;
    try {
      if (await file.exists()) return;
      await file.create(exclusive: true);
      await file.writeAsString(encoded, flush: true);
    } on FileSystemException {
      // Lost the create race or the directory is read-only; nothing to do.
    } catch (e) {
      appLogger.w('CredentialVault: failed to write key file', error: e);
    }
  }

  static Future<void> _mirrorKeyToPrefs(String encoded) async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      if (readTolerantString(prefs, _keyPref) != encoded) {
        await prefs.setString(_keyPref, encoded);
      }
    } catch (e) {
      appLogger.d('CredentialVault: failed to mirror key file into preferences', error: e);
    }
  }
}
