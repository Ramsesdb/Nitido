import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitido/core/models/auto_import/capture_channel.dart';
import 'package:nitido/core/models/auto_import/raw_capture_event.dart';
import 'package:nitido/core/services/auto_import/constants.dart';
import 'package:nitido/core/services/auto_import/profiles/generic_llm_profile.dart';

void main() {
  RawCaptureEvent makeEvent(
    String rawText, {
    String sender = 'com.bancodevenezuela.bdvdigital',
  }) {
    return RawCaptureEvent(
      rawText: rawText,
      sender: sender,
      receivedAt: DateTime(2026, 5, 3, 10, 0),
      channel: CaptureChannel.notification,
    );
  }

  group('GenericLlmProfile — kLlmCallTimeout constant', () {
    test('kLlmCallTimeout is 15 seconds', () {
      expect(kLlmCallTimeout, const Duration(seconds: 15));
    });
  });

  group('GenericLlmProfile — LLM responds within timeout', () {
    test('valid JSON response is parsed correctly', () async {
      final profile = GenericLlmProfile(
        completeOverride: (systemPrompt, userPrompt) async {
          // Simulate a fast LLM response (< 15s)
          return '{"isTransaction":true,"amount":500.0,"currencyCode":"VES",'
              '"type":"income","counterpartyName":"JUAN PEREZ",'
              '"bankRef":"123456","bankName":"Banco de Venezuela",'
              '"date":"2026-05-03","confidence":0.9}';
        },
      );

      final event = makeEvent(
        'Transferencia BDV recibida\n'
        'Recibiste una transferencia BDV de JUAN PEREZ '
        'por Bs.500,00 bajo el número de operación 123456',
      );

      final result = await profile.tryParseWithDetails(
        event,
        accountId: 'acc-bdv',
      );

      expect(result.success, isTrue);
      expect(result.transaction, isNotNull);
      expect(result.transaction!.amount, 500.0);
      expect(result.transaction!.currencyId, 'VES');
      expect(result.resolvedBankName, 'Banco de Venezuela');
    });

    test('non-transaction response returns failed', () async {
      final profile = GenericLlmProfile(
        completeOverride: (systemPrompt, userPrompt) async {
          return '{"isTransaction":false}';
        },
      );

      final event = makeEvent('Promoción BDV\nTenemos una oferta para ti');
      final result = await profile.tryParseWithDetails(
        event,
        accountId: 'acc-bdv',
      );

      expect(result.success, isFalse);
      expect(result.failureReason, contains('no es transacción'));
    });
  });

  group('GenericLlmProfile — LLM exceeds timeout', () {
    test('slow LLM returns null → ParseResult.failed', () async {
      final profile = GenericLlmProfile(
        completeOverride: (systemPrompt, userPrompt) async {
          // Simulate a completion that would take way longer than 15s.
          // We use a short delay here; the actual timeout is on the
          // production path (AiService.instance.complete), not on
          // completeOverride.  But we test the handling of a null return.
          return null;
        },
      );

      final event = makeEvent('Transferencia recibida\nBs.100,00 ref 999');

      final result = await profile.tryParseWithDetails(
        event,
        accountId: 'acc-bdv',
      );

      expect(result.success, isFalse);
      expect(result.failureReason, contains('llm_unavailable'));
    });

    test('LLM throwing exception returns failed', () async {
      final profile = GenericLlmProfile(
        completeOverride: (systemPrompt, userPrompt) async {
          throw TimeoutException('LLM call exceeded 15s');
        },
      );

      final event = makeEvent('Transferencia recibida\nBs.100,00 ref 999');

      final result = await profile.tryParseWithDetails(
        event,
        accountId: 'acc-bdv',
      );

      expect(result.success, isFalse);
      expect(result.failureReason, contains('llm_unavailable'));
    });
  });

  group('GenericLlmProfile — edge cases', () {
    test('empty LLM response returns failed', () async {
      final profile = GenericLlmProfile(
        completeOverride: (systemPrompt, userPrompt) async => '',
      );

      final event = makeEvent('Alerta\nTexto vacío');
      final result = await profile.tryParseWithDetails(
        event,
        accountId: 'acc-bdv',
      );

      expect(result.success, isFalse);
      expect(result.failureReason, 'llm_unavailable');
    });

    test('malformed JSON from LLM returns failed', () async {
      final profile = GenericLlmProfile(
        completeOverride: (systemPrompt, userPrompt) async => '{not valid json',
      );

      final event = makeEvent('Alerta\nTexto');
      final result = await profile.tryParseWithDetails(
        event,
        accountId: 'acc-bdv',
      );

      expect(result.success, isFalse);
      expect(result.failureReason, contains('llm_invalid_response'));
    });

    test('low confidence (< 0.4) returns failed', () async {
      final profile = GenericLlmProfile(
        completeOverride: (systemPrompt, userPrompt) async {
          return '{"isTransaction":true,"amount":100.0,"currencyCode":"VES",'
              '"type":"expense","bankName":"TestBank","confidence":0.2}';
        },
      );

      final event = makeEvent('Alerta\nBs.100');
      final result = await profile.tryParseWithDetails(event, accountId: 'acc');

      expect(result.success, isFalse);
      expect(result.failureReason, contains('confianza muy baja'));
    });

    test('confidence is capped at 0.75 for LLM results', () async {
      final profile = GenericLlmProfile(
        completeOverride: (systemPrompt, userPrompt) async {
          return '{"isTransaction":true,"amount":100.0,"currencyCode":"VES",'
              '"type":"income","bankName":"TestBank","confidence":0.99}';
        },
      );

      final event = makeEvent('Transferencia\nBs.100 ref 123');
      final result = await profile.tryParseWithDetails(event, accountId: 'acc');

      expect(result.success, isTrue);
      expect(result.transaction!.confidence, 0.75);
    });

    test('markdown-wrapped JSON is cleaned and parsed', () async {
      final profile = GenericLlmProfile(
        completeOverride: (systemPrompt, userPrompt) async {
          return '```json\n'
              '{"isTransaction":true,"amount":250.0,"currencyCode":"USD",'
              '"type":"expense","bankName":"TestBank","confidence":0.8}\n'
              '```';
        },
      );

      final event = makeEvent('Pago\n\$250 ref ABC');
      final result = await profile.tryParseWithDetails(event, accountId: 'acc');

      expect(result.success, isTrue);
      expect(result.transaction!.amount, 250.0);
      expect(result.transaction!.currencyId, 'USD');
    });
  });
}
