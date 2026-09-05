import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/credential_vault.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  group('CredentialVault.reveal', () {
    test('round-trips a protected value', () async {
      final protected = await CredentialVault.protect('super-secret');
      expect(protected, startsWith('enc:v1:'));
      expect(await CredentialVault.reveal(protected), 'super-secret');
    });

    test('returns unprotected values unchanged', () async {
      expect(await CredentialVault.reveal('plaintext-token'), 'plaintext-token');
    });

    test('returns null instead of throwing on a tampered MAC', () async {
      final protected = await CredentialVault.protect('super-secret');
      final payload = jsonDecode(protected.substring('enc:v1:'.length)) as Map<String, dynamic>;
      payload['m'] = base64Encode(List<int>.filled(16, 0));
      final tampered = 'enc:v1:${jsonEncode(payload)}';

      expect(await CredentialVault.reveal(tampered), isNull);
    });

    test('returns null instead of throwing on a corrupt payload', () async {
      expect(await CredentialVault.reveal('enc:v1:not-json'), isNull);
      expect(await CredentialVault.reveal('enc:v1:{"n":"!!","c":"!!","m":"!!"}'), isNull);
      expect(await CredentialVault.reveal('enc:v1:{"n":"AAAA"}'), isNull);
    });

    test('returns null when the key diverged from the ciphertext', () async {
      final protected = await CredentialVault.protect('super-secret');

      // Simulate the key being lost/regenerated (cleared prefs, clobbered by
      // another isolate, restored backup) while the ciphertext survived.
      resetSharedPreferencesForTest();
      CredentialVault.resetKeyForTesting();

      expect(await CredentialVault.reveal(protected), isNull);
    });
  });

  group('CredentialVault.revealConnectionConfig', () {
    test('maps an undecryptable account token to the empty string without migrating', () async {
      final protected = await CredentialVault.protect('tok');
      resetSharedPreferencesForTest();
      CredentialVault.resetKeyForTesting();

      final result = await CredentialVault.revealConnectionConfig('plex', {
        'accountToken': protected,
        'servers': [
          {'accessToken': protected},
        ],
      });

      expect(result.config['accountToken'], '');
      expect((result.config['servers'] as List).single['accessToken'], '');
      expect(result.migrated, isFalse);
    });

    test('still reveals and flags plaintext tokens for migration', () async {
      final result = await CredentialVault.revealConnectionConfig('plex', {
        'accountToken': 'plain-tok',
        'servers': const [],
      });

      expect(result.config['accountToken'], 'plain-tok');
      expect(result.migrated, isTrue);
    });
  });

  group('CredentialVault key file', () {
    late Directory keyDir;

    setUp(() async {
      keyDir = await Directory.systemTemp.createTemp('vault-key-test');
      CredentialVault.keyFileDirectoryOverride = () async => keyDir;
    });

    tearDown(() async {
      CredentialVault.keyFileDirectoryOverride = null;
      await keyDir.delete(recursive: true);
    });

    test('persists the key next to the database so a copied install decrypts', () async {
      final protected = await CredentialVault.protect('super-secret');
      expect(File('${keyDir.path}/credential_vault.key').existsSync(), isTrue);

      // Fresh install: empty prefs, no memoized key — only the copied key file.
      resetSharedPreferencesForTest();
      CredentialVault.resetKeyForTesting();

      expect(await CredentialVault.reveal(protected), 'super-secret');
    });

    test('key file wins over a diverged preferences key', () async {
      final protected = await CredentialVault.protect('super-secret');

      // New prefs grow their own key while the vault is not memoized (the
      // copied-database scenario: local install signed in independently).
      resetSharedPreferencesForTest();
      CredentialVault.resetKeyForTesting();
      CredentialVault.keyFileDirectoryOverride = null;
      await CredentialVault.protect('unrelated');

      CredentialVault.resetKeyForTesting();
      CredentialVault.keyFileDirectoryOverride = () async => keyDir;
      expect(await CredentialVault.reveal(protected), 'super-secret');
    });

    test('falls back to the preferences key when no file exists', () async {
      CredentialVault.keyFileDirectoryOverride = null;
      final protected = await CredentialVault.protect('super-secret');

      CredentialVault.resetKeyForTesting();
      CredentialVault.keyFileDirectoryOverride = () async => keyDir;
      expect(await CredentialVault.reveal(protected), 'super-secret');
      // And the adopted prefs key is published as a file for future copies.
      expect(File('${keyDir.path}/credential_vault.key').existsSync(), isTrue);
    });
  });
}
