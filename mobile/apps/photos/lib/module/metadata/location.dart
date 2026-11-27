import "dart:io";

import "package:exif_reader/exif_reader.dart";
import "package:photos/models/ffmpeg/ffprobe_props.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/location/location.dart";
import "package:photos/module/metadata/exif.dart";
import "package:photos/module/metadata/video.dart";

Future<void> updateLocationFromEmbeddedMetadata(
  EnteFile file,
  File sourceFile,
  Map<String, IfdTag>? exifData, {
  FFProbeProps? videoProps,
}) async {
  if (!Platform.isAndroid) {
    return;
  }
  if (exifData != null) {
    final exifLocation = locationFromExif(exifData);
    if (Location.isValidLocation(exifLocation)) {
      file.location = exifLocation;
      return;
    }
  }
  if (!file.hasLocation && file.isVideo) {
    final videoLocation =
        (videoProps ?? await getVideoProps(sourceFile))?.location;
    if (videoLocation != null) {
      file.location = videoLocation;
    }
  }
}
