import 'dart:convert';

import 'package:nitido/core/database/services/category/category_service.dart';
import 'package:nitido/core/database/services/user-setting/user_setting_service.dart';
import 'package:nitido/core/models/auto_import/transaction_proposal.dart';
import 'package:nitido/core/models/transaction/transaction_type.enum.dart';
import 'package:nitido/core/services/ai/ai_service.dart';

const double kMinConfidence = 0.55;

class AutoCategorySuggestion {
  final String categoryId;
  final double confidence;

  const AutoCategorySuggestion({
    required this.categoryId,
    required this.confidence,
  });
}

/// Visible-for-testing pure parser for the LLM categorization response.
/// Returns `null` when the payload is missing/malformed, the categoryId is
/// not in [allowedIds], or the confidence falls below [kMinConfidence].
AutoCategorySuggestion? parseCategorizationResponse(
  String? raw, {
  required Set<String> allowedIds,
}) {
  if (raw == null || raw.isEmpty) return null;

  final match = RegExp(r'\{[\s\S]*\}').firstMatch(raw);
  final jsonText = match?.group(0);
  if (jsonText == null) return null;

  final dynamic parsed;
  try {
    parsed = jsonDecode(jsonText);
  } catch (_) {
    return null;
  }
  if (parsed is! Map<String, dynamic>) return null;

  final categoryId = parsed['categoryId'];
  if (categoryId is! String || !allowedIds.contains(categoryId)) return null;

  final confidenceRaw = parsed['confidence'];
  final confidence = confidenceRaw is num
      ? confidenceRaw.toDouble()
      : double.tryParse(confidenceRaw?.toString() ?? '') ?? 0.0;

  final clamped = confidence.clamp(0.0, 1.0);
  if (clamped < kMinConfidence) return null;

  return AutoCategorySuggestion(
    categoryId: categoryId,
    confidence: clamped,
  );
}

class AutoCategorizationService {
  static final instance = AutoCategorizationService._();
  AutoCategorizationService._();

  Future<AutoCategorySuggestion?> suggest({
    required TransactionProposal proposal,
  }) async {
    if (proposal.type == TransactionType.transfer) return null;

    final aiEnabled = appStateSettings[SettingKey.nexusAiEnabled] == '1';
    final featureEnabled =
        appStateSettings[SettingKey.aiCategorizationEnabled] == '1';

    if (!aiEnabled || !featureEnabled) return null;

    try {
      final categories = await CategoryService.instance.getCategories().first;
      final allowed = categories
          .where((c) => c.type.matchWithTransactionType(proposal.type))
          .toList();

      if (allowed.isEmpty) return null;

      final allowedIds = {for (final c in allowed) c.id};
      final categoriesPrompt = allowed
          .map((c) => '- ${c.id}: ${c.name}')
          .join('\n');

      final raw = await AiService.instance.complete(
        temperature: 0.1,
        messages: [
          {
            'role': 'system',
            'content':
                'Respondes en ESPANOL siempre. Sin markdown innecesario. '
                'Debes responder SOLO con JSON valido con la forma '
                '{"categoryId":"...","confidence":0.0}. '
                'No agregues texto adicional.',
          },
          {
            'role': 'user',
            'content':
                'Clasifica este movimiento usando SOLO una categoria valida.\n'
                'Tipo: ${proposal.type.databaseValue}\n'
                'Monto: ${proposal.amount} ${proposal.currencyId}\n'
                'Counterparty: ${proposal.counterpartyName ?? '-'}\n'
                'Sender: ${proposal.sender ?? '-'}\n'
                'Texto crudo: ${proposal.rawText}\n\n'
                'Categorias permitidas:\n$categoriesPrompt\n\n'
                'Si no estás 100% seguro de la categoría, devuelve "C19" '
                'para gastos o "C03" para ingresos. Es preferible una '
                'clasificación neutral a una incorrecta.',
          },
        ],
      );

      return parseCategorizationResponse(raw, allowedIds: allowedIds);
    } catch (_) {
      return null;
    }
  }
}
