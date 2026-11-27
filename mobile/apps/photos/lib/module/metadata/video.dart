import "dart:io";

import "package:logging/logging.dart";
import "package:photos/models/ffmpeg/ffprobe_props.dart";
import "package:photos/module/metadata/exif.dart";
import "package:photos/services/ffmpeg_service.dart";

final _logger = Logger("VideoMetadata");

Future<FFProbeProps?> getVideoProps(File file) async {
  try {
    final stopwatch = Stopwatch()..start();
    final mediaInfo = await FfmpegService.instance.getVideoInfo(file.path);
    if (mediaInfo.isEmpty) {
      return null;
    }
    final properties = FFProbeProps.parseData(mediaInfo);
    _logger.info("getVideoProps took ${stopwatch.elapsedMilliseconds}ms");
    return properties;
  } catch (e, s) {
    _logger.severe("Failed to get video properties", e, s);
    return null;
  }
}

ParsedExifDateTime? videoCaptureTime(FFProbeProps? props) {
  final creationDate = props?.quickTimeCreationDate;
  if (creationDate == null) {
    return null;
  }
  try {
    final parsed = getDateTimeInDeviceTimezone(creationDate, null);
    final offsetTime = parsed.offsetTime;
    if (offsetTime == null || offsetTime == "Z") {
      return null;
    }
    return parsed;
  } on FormatException {
    _logger.warning("Ignoring invalid video creation date: $creationDate");
    return null;
  }
}
