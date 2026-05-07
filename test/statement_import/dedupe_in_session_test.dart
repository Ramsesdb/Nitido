import 'package:flutter_test/flutter_test.dart';
import 'package:nitido/core/services/statement_import/dedupe_in_session.dart';
import 'package:nitido/core/services/statement_import/models/extracted_row.dart';

ExtractedRow _row({
  required String id,
  required double amount,
  required DateTime date,
  String description = 'Pago',
  String kind = 'expense',
  double? confidence,
}) => ExtractedRow(
  id: id,
  amount: amount,
  kind: kind,
  date: date,
  description: description,
  confidence: confidence,
);

void main() {
  group('dedupeInSession', () {
    test('collapses two rows in the same 4h bucket', () {
      final base = DateTime.utc(2025, 1, 1, 0, 0, 0);
      final rows = [
        _row(id: 'a', amount: 50.00, date: base, description: 'Pago Walmart'),
        _row(
          id: 'b',
          amount: 50.00,
          date: base.add(const Duration(hours: 3, minutes: 59)),
          description: 'Pago Walmart',
        ),
      ];

      final result = dedupeInSession(rows);

      expect(result.rows.length, equals(1));
      expect(result.collisions, equals(1));
    });

    test('keeps two rows when 4h+1min apart (cross-bucket)', () {
      final base = DateTime.utc(2025, 1, 1, 0, 0, 0);
      final rows = [
        _row(id: 'a', amount: 50.00, date: base, description: 'Pago'),
        _row(
          id: 'b',
          amount: 50.00,
          date: base.add(const Duration(hours: 4, minutes: 1)),
          description: 'Pago',
        ),
      ];

      final result = dedupeInSession(rows);

      expect(result.rows.length, equals(2));
      expect(result.collisions, equals(0));
    });

    test('two rows with different amounts are not merged', () {
      final base = DateTime.utc(2025, 1, 1, 10, 0, 0);
      final rows = [
        _row(id: 'a', amount: 50.00, date: base, description: 'Pago'),
        _row(id: 'b', amount: 51.00, date: base, description: 'Pago'),
      ];

      final result = dedupeInSession(rows);

      expect(result.rows.length, equals(2));
      expect(result.collisions, equals(0));
    });

    test('amount sign is ignored (abs)', () {
      final base = DateTime.utc(2025, 1, 1, 10, 0, 0);
      final rows = [
        _row(id: 'a', amount: 50.00, date: base, description: 'Pago'),
        _row(id: 'b', amount: -50.00, date: base, description: 'Pago'),
      ];

      final result = dedupeInSession(rows);

      expect(result.rows.length, equals(1));
      expect(result.collisions, equals(1));
    });

    test('counterparty case-insensitive merge', () {
      final base = DateTime.utc(2025, 1, 1, 10, 0, 0);
      final rows = [
        _row(id: 'a', amount: 50.00, date: base, description: '  Walmart '),
        _row(id: 'b', amount: 50.00, date: base, description: 'WALMART'),
      ];

      final result = dedupeInSession(rows);

      expect(result.rows.length, equals(1));
      expect(result.collisions, equals(1));
    });

    test('different counterparty does not merge', () {
      final base = DateTime.utc(2025, 1, 1, 10, 0, 0);
      final rows = [
        _row(id: 'a', amount: 50.00, date: base, description: 'Walmart'),
        _row(id: 'b', amount: 50.00, date: base, description: 'Costco'),
      ];

      final result = dedupeInSession(rows);

      expect(result.rows.length, equals(2));
      expect(result.collisions, equals(0));
    });

    test('higher confidence wins on collision', () {
      final base = DateTime.utc(2025, 1, 1, 10, 0, 0);
      final rows = [
        _row(
          id: 'low',
          amount: 50.00,
          date: base,
          description: 'Pago',
          confidence: 0.4,
        ),
        _row(
          id: 'high',
          amount: 50.00,
          date: base,
          description: 'Pago',
          confidence: 0.9,
        ),
      ];

      final result = dedupeInSession(rows);

      expect(result.rows.length, equals(1));
      expect(result.rows.first.id, equals('high'));
      expect(result.collisions, equals(1));
    });

    test('preserves insertion order for unique rows', () {
      final base = DateTime.utc(2025, 1, 1, 10, 0, 0);
      final rows = [
        _row(id: 'first', amount: 10, date: base, description: 'A'),
        _row(id: 'second', amount: 20, date: base, description: 'B'),
        _row(id: 'third', amount: 30, date: base, description: 'C'),
      ];

      final result = dedupeInSession(rows);

      expect(result.rows.map((r) => r.id).toList(), [
        'first',
        'second',
        'third',
      ]);
      expect(result.collisions, equals(0));
    });

    test('currency upper-case key (parameter passed)', () {
      final base = DateTime.utc(2025, 1, 1, 10, 0, 0);
      final rows = [
        _row(id: 'a', amount: 50.00, date: base, description: 'Pago'),
        _row(id: 'b', amount: 50.00, date: base, description: 'Pago'),
      ];

      final lower = dedupeInSession(rows, currency: 'usd');
      final upper = dedupeInSession(rows, currency: 'USD');

      expect(lower.rows.length, equals(upper.rows.length));
      expect(lower.collisions, equals(upper.collisions));
    });
  });
}
