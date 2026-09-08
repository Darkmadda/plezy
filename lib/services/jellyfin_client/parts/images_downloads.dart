part of '../../jellyfin_client.dart';

mixin _JellyfinImageDownloadMethods on _JellyfinClientInternals {
  /// [cover] is accepted for interface parity and ignored: `maxWidth`/
  /// `maxHeight` already scale the long axis to fit inside the box, so
  /// Jellyfin never overshoots the way Plex's `minSize=1` transcode does.
  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    if (path == null || path.isEmpty) return '';
    final uri = JellyfinImageAbsolutizer.joinUri(baseUrl: connection.baseUrl, urlOrPath: path);
    final params = Map<String, String>.from(uri.queryParameters);
    if (width != null && !params.containsKey('maxWidth') && !params.containsKey('MaxWidth')) {
      params['maxWidth'] = '$width';
    }
    if (height != null && !params.containsKey('maxHeight') && !params.containsKey('MaxHeight')) {
      params['maxHeight'] = '$height';
    }
    params.putIfAbsent('api_key', () => connection.accessToken);
    return uri.replace(queryParameters: params).toString();
  }

  /// Jellyfin doesn't expose an external-URL proxy endpoint comparable to
  /// Plex's `/photo/:/transcode?url=...`. External URLs pass through.
  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;

  @override
  Future<String?> resolveExternalPlaybackUrl(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    // Tracks stream from /Audio/{id}/stream; the URL contract (Static=true,
    // api_key in the query string) is otherwise identical to the video one.
    final isTrack = item.kind == MediaKind.track;
    final bundle = await fetchPlaybackBundle(item.id, sourceIndex: mediaIndex, sourceId: mediaSourceId);
    if (bundle == null) {
      return isTrack ? buildAudioDirectStreamUrl(item.id) : buildDirectStreamUrl(item.id);
    }
    final container = bundle.container;
    final pinnedSourceId = bundle.pinnedSourceId;
    return isTrack
        ? buildAudioDirectStreamUrl(item.id, container: container, mediaSourceId: pinnedSourceId)
        : buildDirectStreamUrl(item.id, container: container, mediaSourceId: pinnedSourceId);
  }

  @override
  Future<DownloadResolution> resolveDownload(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async {
    final bundle = await fetchPlaybackBundle(item.id, sourceIndex: mediaIndex, sourceId: mediaSourceId);
    final selectedSourceId = bundle?.selectedSourceId;
    final requestedSourceId = mediaSourceId?.trim();
    if (requestedSourceId != null &&
        requestedSourceId.isNotEmpty &&
        selectedSourceId?.toLowerCase() != requestedSourceId.toLowerCase()) {
      throw StateError('Requested Jellyfin download source is no longer available');
    }

    // Tracks download from the audio static-stream endpoint and have no
    // subtitle sidecars to enumerate.
    if (item.kind == MediaKind.track) {
      final audioUrl = buildAudioDirectStreamUrl(
        item.id,
        container: bundle?.container,
        mediaSourceId: bundle?.pinnedSourceId,
      );
      return DownloadResolution(videoUrl: audioUrl, mediaSourceId: selectedSourceId, externalSubtitles: const []);
    }

    // Direct-stream the selected original file (`Static=true` skips the
    // transcoder so the byte-for-byte source lands on disk) — unless a
    // quality cap asks for a server-side transcode of the video.
    final String videoUrl;
    var isTranscoded = false;
    String? transcodeSessionId;
    final videoBitrateKbps = quality.videoBitrateKbps;
    if (!quality.isOriginal && videoBitrateKbps != null) {
      final playSessionId = generateSessionIdentifier();
      videoUrl = buildJellyfinTranscodeDownloadUrl(
        baseUrl: connection.baseUrl,
        accessToken: connection.accessToken,
        deviceId: connection.deviceId,
        itemId: item.id,
        playSessionId: playSessionId,
        videoBitrateKbps: videoBitrateKbps,
        maxHeight: quality.resolutionHeight,
        mediaSourceId: bundle?.pinnedSourceId,
      );
      isTranscoded = true;
      transcodeSessionId = playSessionId;
    } else {
      videoUrl = buildDirectStreamUrl(item.id, container: bundle?.container, mediaSourceId: bundle?.pinnedSourceId);
    }

    // External subtitle sidecars are listed in the per-source MediaStreams.
    // PlaybackInfo gives us the canonical view including DeliveryUrl when
    // the server has pre-computed one; fall back to the documented stream
    // URL pattern otherwise. Negotiation is enrichment only: the static
    // stream URL above remains valid without it.
    final subtitles = <DownloadSubtitleSpec>[];
    Map<String, dynamic> playbackInfo;
    try {
      playbackInfo = await getPlaybackInfo(item.id, mediaSourceId: selectedSourceId);
    } catch (error, stackTrace) {
      if (!_canUseJellyfinStaticStreamFallback(error)) rethrow;
      appLogger.w(
        'Jellyfin download subtitle enrichment unavailable; using the static stream',
        error: error,
        stackTrace: stackTrace,
      );
      return DownloadResolution(
        videoUrl: videoUrl,
        mediaSourceId: selectedSourceId,
        externalSubtitlesResolved: false,
        isTranscoded: isTranscoded,
        transcodeSessionId: transcodeSessionId,
      );
    }

    final source = _selectDownloadMediaSource(playbackInfo['MediaSources'] as List, selectedSourceId, mediaIndex);
    if (source == null) {
      appLogger.w('Jellyfin download subtitle enrichment returned no usable source; using the static stream');
      return DownloadResolution(
        videoUrl: videoUrl,
        mediaSourceId: selectedSourceId,
        externalSubtitlesResolved: false,
        isTranscoded: isTranscoded,
        transcodeSessionId: transcodeSessionId,
      );
    }
    if (source['MediaStreams'] is! List) {
      appLogger.w('Jellyfin download subtitle enrichment returned malformed streams; using the static stream');
      return DownloadResolution(
        videoUrl: videoUrl,
        mediaSourceId: selectedSourceId,
        externalSubtitlesResolved: false,
        isTranscoded: isTranscoded,
        transcodeSessionId: transcodeSessionId,
      );
    }

    final streams = source['MediaStreams'] as List;
    final rawMediaSourceId = source['Id'];
    if (rawMediaSourceId != null && rawMediaSourceId is! String) {
      appLogger.w('Jellyfin download subtitle enrichment returned an invalid source id; using the static stream');
      return DownloadResolution(
        videoUrl: videoUrl,
        mediaSourceId: selectedSourceId,
        externalSubtitlesResolved: false,
        isTranscoded: isTranscoded,
        transcodeSessionId: transcodeSessionId,
      );
    }
    final subtitleMediaSourceId = rawMediaSourceId as String? ?? item.id;
    for (final raw in streams) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['Type'] != 'Subtitle') continue;
      final fields = parseJellyfinStreamFields(raw);
      if (!fields.isExternalFile) continue;
      final index = raw['Index'];
      if (index is! int) continue;
      final codec = fields.codec?.toLowerCase();
      final delivery = fields.deliveryUrl;
      final url = _withApiKey(
        delivery != null && delivery.isNotEmpty
            ? delivery
            : '/Videos/${_segment(item.id)}/${_segment(subtitleMediaSourceId)}/Subtitles/$index/${_segment('Stream.${codec ?? 'srt'}')}',
      );
      subtitles.add(
        DownloadSubtitleSpec(
          id: index,
          url: url,
          codec: codec,
          language: fields.language,
          languageCode: fields.languageCode,
          forced: fields.isForced,
          displayTitle: fields.displayTitle,
        ),
      );
    }

    return DownloadResolution(
      videoUrl: videoUrl,
      mediaSourceId: selectedSourceId,
      externalSubtitles: subtitles,
      isTranscoded: isTranscoded,
      transcodeSessionId: transcodeSessionId,
    );
  }

  /// Poll `/Sessions` for this device's transcode job. Jellyfin doesn't key
  /// jobs by PlaySessionId in the sessions payload, so the match is
  /// device-scoped: the session for our DeviceId that is currently
  /// transcoding. A concurrent transcode stream from the same device could
  /// briefly alias the figure — acceptable for a progress bar; the download
  /// itself is unaffected.
  @override
  Future<double?> getTranscodeSessionProgress(String transcodeSessionId) async {
    try {
      final response = await _http.get(
        '/Sessions',
        queryParameters: {'deviceId': connection.deviceId},
        timeout: const Duration(seconds: 10),
      );
      final sessions = response.data;
      if (sessions is! List) return null;
      for (final session in sessions) {
        if (session is! Map<String, dynamic>) continue;
        final transcodingInfo = session['TranscodingInfo'];
        if (transcodingInfo is! Map<String, dynamic>) continue;
        final pct = flexibleDouble(transcodingInfo['CompletionPercentage']);
        if (pct != null) return pct;
      }
      return null;
    } catch (e) {
      appLogger.d('Failed to read Jellyfin transcode progress', error: e);
      return null;
    }
  }

  @override
  Future<void> stopTranscodeSession(String transcodeSessionId) async {
    try {
      await _http.delete(
        '/Videos/ActiveEncodings',
        queryParameters: {'deviceId': connection.deviceId, 'playSessionId': transcodeSessionId},
      );
    } catch (e) {
      appLogger.d('Failed to stop Jellyfin transcode session $transcodeSessionId', error: e);
    }
  }

  Map<String, dynamic>? _selectDownloadMediaSource(List<dynamic> sources, String? selectedSourceId, int mediaIndex) {
    if (sources.isEmpty) return null;
    final requestedSourceId = selectedSourceId?.trim();
    if (requestedSourceId != null && requestedSourceId.isNotEmpty) {
      for (final source in sources) {
        if (source is! Map<String, dynamic>) continue;
        final sourceId = source['Id'];
        if (sourceId is String && sourceId.toLowerCase() == requestedSourceId.toLowerCase()) {
          return source;
        }
      }
      return null;
    }
    final source = mediaIndex >= 0 && mediaIndex < sources.length ? sources[mediaIndex] : sources.first;
    if (source is! Map<String, dynamic>) return null;
    return source;
  }

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) {
    // Jellyfin paths flow through `_absolutizeImagePath` at the mapper
    // boundary, so artwork fields on the [MediaItem] are already absolute
    // URLs. buildArtworkSpecs strips auth query params from localKey so the
    // storage layer never hashes or persists access tokens.
    return buildArtworkSpecs(item, (path) => path);
  }
}
