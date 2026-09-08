import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../test_helpers/backend_client_fixtures.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });

  tearDown(() async {
    await db.close();
  });

  http.Response decisionResponse({int transcodeCode = 1001, String container = 'mkv'}) => http.Response(
    jsonEncode({
      'MediaContainer': {
        'transcodeDecisionCode': transcodeCode,
        'Metadata': [
          {
            'Media': [
              {'container': container},
            ],
          },
        ],
      },
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  test('download transcode start path is a progressive MKV stream with quality caps', () async {
    Uri? decisionUri;
    final client = testPlexClient(
      serverId: ServerId('server-id'),
      handler: (request) async {
        if (request.url.path == '/video/:/transcode/universal/decision') {
          decisionUri = request.url;
          return decisionResponse();
        }
        return http.Response('not used', 500);
      },
    );
    addTearDown(client.close);

    final result = await client.buildDownloadTranscodeStartPath(
      ratingKey: '42',
      mediaIndex: 1,
      partIndex: 2,
      preset: TranscodeQualityPreset.p720_2mbps,
      sessionIdentifier: 'session-id',
      transcodeSessionId: 'transcode-id',
    );

    expect(result.outcome, TranscodeDecisionOutcome.transcodeOk);
    final startPath = result.startPath!;
    expect(startPath, startsWith('/video/:/transcode/universal/start.mkv?'));
    expect(startPath, contains('protocol=http'));
    expect(startPath, contains('directPlay=0'));
    expect(startPath, contains('directStream=1'));
    expect(startPath, contains('subtitles=none'));
    expect(startPath, contains('session=transcode-id'));
    expect(startPath, contains('mediaIndex=1'));
    expect(startPath, contains('partIndex=2'));
    expect(startPath, contains('videoResolution=1280x720'));
    // Profile extra carries the bitrate limitation and the http/MKV target;
    // no HLS subtitle target rides along on the download profile.
    expect(startPath, contains('video.bitrate%26value%3D2000'));
    expect(startPath, contains('container%3Dmkv'));
    expect(startPath, isNot(contains('subtitleProfile')));
    // Start URLs are token-stripped; the caller re-appends it.
    expect(startPath, isNot(contains('X-Plex-Token')));

    // The decision request went out with the exact start params.
    expect(decisionUri, isNotNull);
    expect(decisionUri!.queryParameters['protocol'], 'http');
    expect(decisionUri!.queryParameters['session'], 'transcode-id');
  });

  test('a decision that does not echo the MKV container is refused', () async {
    final client = testPlexClient(
      serverId: ServerId('server-id'),
      handler: (request) async {
        if (request.url.path == '/video/:/transcode/universal/decision') {
          return decisionResponse(container: 'mpegts');
        }
        return http.Response('not used', 500);
      },
    );
    addTearDown(client.close);

    final result = await client.buildDownloadTranscodeStartPath(
      ratingKey: '42',
      mediaIndex: 0,
      preset: TranscodeQualityPreset.p720_2mbps,
      sessionIdentifier: 'session-id',
      transcodeSessionId: 'transcode-id',
    );

    expect(result.outcome, TranscodeDecisionOutcome.failed);
    expect(result.startPath, isNull);
  });

  test('a direct-play-only decision reports directPlayOnly so callers fall back to the original', () async {
    final client = testPlexClient(
      serverId: ServerId('server-id'),
      handler: (request) async {
        if (request.url.path == '/video/:/transcode/universal/decision') {
          return decisionResponse(transcodeCode: 1000);
        }
        return http.Response('not used', 500);
      },
    );
    addTearDown(client.close);

    final result = await client.buildDownloadTranscodeStartPath(
      ratingKey: '42',
      mediaIndex: 0,
      preset: TranscodeQualityPreset.p720_2mbps,
      sessionIdentifier: 'session-id',
      transcodeSessionId: 'transcode-id',
    );

    expect(result.outcome, TranscodeDecisionOutcome.directPlayOnly);
  });

  test('getTranscodeSessionProgress matches the session by key and parses percent', () async {
    final client = testPlexClient(
      serverId: ServerId('server-id'),
      handler: (request) async {
        if (request.url.path == '/transcode/sessions') {
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'TranscodeSession': [
                  {'key': 'other-session', 'progress': 12.0},
                  {'key': 'transcode-id', 'progress': 57.5},
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not used', 500);
      },
    );
    addTearDown(client.close);

    expect(await client.getTranscodeSessionProgress('transcode-id'), 57.5);
    expect(await client.getTranscodeSessionProgress('missing-session'), isNull);
  });
}
