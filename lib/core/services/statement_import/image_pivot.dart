import 'dart:convert';

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';

@immutable
class ImagePivot {
  final String base64;
  final DateTime? exifDate;
  final DateTime resolvedPivot;

  const ImagePivot({
    required this.base64,
    this.exifDate,
    required this.resolvedPivot,
  });

  ImagePivot copyWith({DateTime? exifDate, DateTime? resolvedPivot}) {
    return ImagePivot(
      base64: base64,
      exifDate: exifDate ?? this.exifDate,
      resolvedPivot: resolvedPivot ?? this.resolvedPivot,
    );
  }
}

Future<DateTime?> readExifDate(String base64Image) async {
  try {
    final bytes = base64Decode(base64Image);
    return readExifDateFromBytes(bytes);
  } catch (_) {
    return null;
  }
}

Future<DateTime?> readExifDateFromBytes(Uint8List bytes) async {
  try {
    final tags = await readExifFromBytes(bytes);
    if (tags.isEmpty) return null;
    final raw =
        tags['EXIF DateTimeOriginal']?.printable ??
        tags['Image DateTime']?.printable;
    if (raw == null || raw.isEmpty) return null;
    final match = RegExp(
      r'^(\d{4}):(\d{2}):(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$',
    ).firstMatch(raw.trim());
    if (match == null) return null;
    final parsed = DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
    if (parsed.isAfter(DateTime.now())) return null;
    return parsed;
  } catch (_) {
    return null;
  }
}
