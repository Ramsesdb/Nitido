import 'package:flutter_test/flutter_test.dart';
import 'package:nitido/core/services/ai/auto_categorization_service.dart';

void main() {
  group('parseCategorizationResponse', () {
    final allowedIds = {'C10', 'C12', 'C19', 'C03'};

    test('high confidence above threshold → returns suggestion', () {
      final result = parseCategorizationResponse(
        '{"categoryId":"C12","confidence":0.85}',
        allowedIds: allowedIds,
      );

      expect(result, isNotNull);
      expect(result!.categoryId, equals('C12'));
      expect(result.confidence, equals(0.85));
    });

    test('confidence at threshold (0.55) → returns suggestion', () {
      final result = parseCategorizationResponse(
        '{"categoryId":"C19","confidence":0.55}',
        allowedIds: allowedIds,
      );

      expect(result, isNotNull);
      expect(result!.categoryId, equals('C19'));
    });

    test('confidence below threshold (0.40) → returns null', () {
      final result = parseCategorizationResponse(
        '{"categoryId":"C10","confidence":0.40}',
        allowedIds: allowedIds,
      );

      expect(
        result,
        isNull,
        reason: 'Below kMinConfidence the call site must fall through to '
            'the constant fallback (C19/C03).',
      );
    });

    test('confidence just under threshold (0.5499) → returns null', () {
      final result = parseCategorizationResponse(
        '{"categoryId":"C10","confidence":0.5499}',
        allowedIds: allowedIds,
      );

      expect(result, isNull);
    });

    test('categoryId not in allowed set → returns null', () {
      final result = parseCategorizationResponse(
        '{"categoryId":"C99","confidence":0.9}',
        allowedIds: allowedIds,
      );

      expect(result, isNull);
    });

    test('null payload → returns null', () {
      final result = parseCategorizationResponse(null, allowedIds: allowedIds);
      expect(result, isNull);
    });

    test('empty payload → returns null', () {
      final result = parseCategorizationResponse('', allowedIds: allowedIds);
      expect(result, isNull);
    });

    test('payload without JSON object → returns null', () {
      final result = parseCategorizationResponse(
        'sin json aqui',
        allowedIds: allowedIds,
      );
      expect(result, isNull);
    });

    test('malformed JSON → returns null', () {
      final result = parseCategorizationResponse(
        '{"categoryId":"C12","confidence":}',
        allowedIds: allowedIds,
      );
      expect(result, isNull);
    });

    test('missing confidence field → treated as 0.0 → returns null', () {
      final result = parseCategorizationResponse(
        '{"categoryId":"C12"}',
        allowedIds: allowedIds,
      );
      expect(result, isNull);
    });

    test('confidence as string "0.7" → parsed and accepted', () {
      final result = parseCategorizationResponse(
        '{"categoryId":"C12","confidence":"0.7"}',
        allowedIds: allowedIds,
      );

      expect(result, isNotNull);
      expect(result!.confidence, equals(0.7));
    });

    test('confidence above 1.0 is clamped to 1.0', () {
      final result = parseCategorizationResponse(
        '{"categoryId":"C12","confidence":1.7}',
        allowedIds: allowedIds,
      );

      expect(result, isNotNull);
      expect(result!.confidence, equals(1.0));
    });

    test('JSON wrapped in surrounding text → still extracted', () {
      final result = parseCategorizationResponse(
        'Aqui tienes: {"categoryId":"C19","confidence":0.62} listo.',
        allowedIds: allowedIds,
      );

      expect(result, isNotNull);
      expect(result!.categoryId, equals('C19'));
    });
  });

  group('kMinConfidence', () {
    test('threshold matches design §5 decision (0.55)', () {
      expect(kMinConfidence, equals(0.55));
    });
  });
}
