import 'package:nitido/core/models/category/category.dart';
import 'package:nitido/core/models/transaction/transaction_type.enum.dart';

/// Stable seed ID for `Otros Gastos` in `assets/sql/initial_categories.json`.
/// Type `"B"` (both income/expense eligible) — see seed line 548.
const String kFallbackExpenseCategoryId = 'C19';

/// Stable seed ID for `Otros Ingresos` in `assets/sql/initial_categories.json`.
/// Type `"I"` (income only) — see seed line 54.
const String kFallbackIncomeCategoryId = 'C03';

/// Synchronous resolver for the neutral fallback category.
///
/// Resolution order (per `screenshot-import-improvements/specs/categorization-fallback.md`):
///   1. Filter `userCategories` by `type` (income → `I` or `B`; expense → `E` or `B`).
///   2. Look up the type-appropriate seed ID (`C03` / `C19`) inside the
///      filtered list. If found, return it.
///   3. Otherwise return the first entry of the filtered list (preserves the
///      legacy `.first` behaviour when the user deleted the seed).
///   4. If the filtered list is empty, return `null`.
///
/// `transfer` is NOT supported (transfers do not carry a category) and
/// returns `null`.
Category? resolveFallbackCategorySync(
  TransactionType type,
  List<Category> userCategories,
) {
  if (type == TransactionType.transfer) return null;

  final filtered = userCategories
      .where((c) => c.type.matchWithTransactionType(type))
      .toList();

  if (filtered.isEmpty) return null;

  final wantedId = type == TransactionType.income
      ? kFallbackIncomeCategoryId
      : kFallbackExpenseCategoryId;

  for (final c in filtered) {
    if (c.id == wantedId) return c;
  }

  return filtered.first;
}

/// Async-friendly wrapper used by call sites that already work in `Future`
/// pipelines (statement-import / proposal-review). Behaviour is identical to
/// [resolveFallbackCategorySync].
Future<Category?> resolveFallbackCategory(
  TransactionType type,
  List<Category> userCategories,
) async => resolveFallbackCategorySync(type, userCategories);
