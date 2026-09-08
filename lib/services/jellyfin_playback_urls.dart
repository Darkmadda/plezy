/// [mediaSegment] selects the endpoint family: Jellyfin serves the identical
/// static-stream contract under `/Videos/{id}/stream` and `/Audio/{id}/stream`
/// — music track playback passes `'Audio'`.
String buildJellyfinDirectStreamUrl({
  required String baseUrl,
  required String accessToken,
  required String deviceId,
  required String itemId,
  String mediaSegment = 'Videos',
  String? container,
  String? mediaSourceId,
  String? playSessionId,
  String? liveStreamId,
  int? audioStreamIndex,
}) {
  final params = <String, String>{
    'Static': 'true',
    'api_key': accessToken,
    'DeviceId': deviceId,
    'Container': ?container,
    'MediaSourceId': ?mediaSourceId,
    'PlaySessionId': ?playSessionId,
    'LiveStreamId': ?liveStreamId,
    'AudioStreamIndex': ?audioStreamIndex?.toString(),
  };
  final encodedItem = Uri.encodeComponent(itemId);
  return '$baseUrl/$mediaSegment/$encodedItem/stream?${_encodeQuery(params)}';
}

/// Quality-capped download URL: `/Videos/{id}/stream.mkv` with the transcoder
/// engaged (no `Static=true`). The `.mkv` path extension picks the container —
/// MKV because a live encode is written front-to-back and never gets a
/// finalized MP4 moov atom. Jellyfin honours `AllowVideoStreamCopy` (default
/// true), so a source already inside the caps is losslessly remuxed instead
/// of re-encoded. [playSessionId] keys the server-side transcode job for
/// progress polling and `/Videos/ActiveEncodings` cleanup.
String buildJellyfinTranscodeDownloadUrl({
  required String baseUrl,
  required String accessToken,
  required String deviceId,
  required String itemId,
  required String playSessionId,
  required int videoBitrateKbps,
  int? maxHeight,
  String? mediaSourceId,
}) {
  final params = <String, String>{
    'api_key': accessToken,
    'DeviceId': deviceId,
    'PlaySessionId': playSessionId,
    'MediaSourceId': ?mediaSourceId,
    'VideoCodec': 'h264',
    'AudioCodec': 'aac',
    // Jellyfin bitrates are bits per second (presets are kbps); the audio
    // figure matches the estimate allowance in download_size_estimator.dart.
    'VideoBitRate': '${videoBitrateKbps * 1000}',
    'AudioBitRate': '256000',
    'MaxHeight': ?maxHeight?.toString(),
  };
  final encodedItem = Uri.encodeComponent(itemId);
  return '$baseUrl/Videos/$encodedItem/stream.mkv?${_encodeQuery(params)}';
}

String buildJellyfinTrickplayTileUrl({
  required String baseUrl,
  required String accessToken,
  required String deviceId,
  required String itemId,
  required int width,
  required int sheetIndex,
  String? mediaSourceId,
}) {
  final params = <String, String>{'api_key': accessToken, 'DeviceId': deviceId, 'MediaSourceId': ?mediaSourceId};
  final encodedItem = Uri.encodeComponent(itemId);
  return '$baseUrl/Videos/$encodedItem/Trickplay/$width/$sheetIndex.jpg?${_encodeQuery(params)}';
}

String _encodeQuery(Map<String, String> params) =>
    params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
