import 'package:nitido/core/services/statement_import/models/extracted_row.dart';

class DedupeResult {
  final List<ExtractedRow> rows;
  final int collisions;

  const DedupeResult({required this.rows, required this.collisions});
}

const int _bucketMs = 4 * 3600 * 1000;

String _buildKey(ExtractedRow r, {String currency = ''}) {
  final amount = r.amount.abs().toStringAsFixed(2);
  final cur = currency.toUpperCase();
  final bucket = r.date.millisecondsSinceEpoch ~/ _bucketMs;
  final counterparty = r.description.toLowerCase().trim();
  return '$amount|$cur|$bucket|$counterparty';
}

DedupeResult dedupeInSession(
  List<ExtractedRow> rows, {
  String currency = '',
}) {
  final map = <String, ExtractedRow>{};
  final order = <String>[];
  int collisions = 0;
  for (final r in rows) {
    final key = _buildKey(r, currency: currency);
    final existing = map[key];
    if (existing == null) {
      map[key] = r;
      order.add(key);
    } else {
      collisions++;
      final existingConf = existing.confidence ?? 0;
      final candidateConf = r.confidence ?? 0;
      if (candidateConf > existingConf) {
        map[key] = r;
      }
    }
  }
  return DedupeResult(
    rows: [for (final k in order) map[k]!],
    collisions: collisions,
  );
}
