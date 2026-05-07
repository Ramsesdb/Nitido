import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:nitido/app/accounts/statement_import/statement_import_flow.dart';
import 'package:nitido/app/accounts/statement_import/widgets/si_header.dart';
import 'package:nitido/core/constants/fallback_categories.dart';
import 'package:nitido/core/constants/feature_flags.dart';
import 'package:nitido/core/database/app_db.dart';
import 'package:nitido/core/database/services/account/account_service.dart';
import 'package:nitido/core/database/services/category/category_service.dart';
import 'package:nitido/core/models/account/account.dart';
import 'package:nitido/core/models/category/category.dart';
import 'package:nitido/core/models/transaction/transaction_status.enum.dart';
import 'package:nitido/core/models/transaction/transaction_type.enum.dart';
import 'package:nitido/core/presentation/helpers/snackbar.dart';
import 'package:nitido/core/presentation/widgets/number_ui_formatters/currency_displayer.dart';
import 'package:nitido/core/presentation/widgets/retroactive_preview_dialog.dart';
import 'package:nitido/core/services/statement_import/models/matching_result.dart';
import 'package:nitido/core/services/statement_import/statement_batches_service.dart';
import 'package:nitido/core/utils/uuid.dart';
import 'package:nitido/i18n/generated/translations.g.dart';

/// Relative diff threshold that escalates the retroactive preview to the
/// strong-confirm dialog. Mirrors `account-pre-tracking-period`'s rule used in
/// `account_form.dart`: shift > 50% OR projected balance < 0.
const double kRetroactivePreFreshDiffThreshold = 0.5;

/// Pure predicate that decides whether the strong-confirmation dialog must be
/// shown instead of the simple preview when adjusting `trackedSince` at
/// import time. Reused by tests; mirrors the rule in `account_form.dart`.
@visibleForTesting
bool shouldEscalatePreFreshDialog({
  required double currentBalance,
  required double simulatedBalance,
}) {
  final diff = (currentBalance - simulatedBalance).abs();
  return simulatedBalance < 0 ||
      (currentBalance.abs() > 0 &&
          diff / currentBalance.abs() > kRetroactivePreFreshDiffThreshold) ||
      (currentBalance.abs() == 0 && simulatedBalance < 0);
}

class ConfirmPage extends StatefulWidget {
  const ConfirmPage({super.key});

  @override
  State<ConfirmPage> createState() => _ConfirmPageState();
}

class _ConfirmPageState extends State<ConfirmPage> {
  bool _committing = false;

  /// Resolve a fallback category for the given transaction type.
  /// The DB CHECK constraint requires exactly one of
  /// `categoryID` / `receivingAccountID` to be non-null.
  Future<Category?> _resolveCategoryForKind(String kind) async {
    final type = kind == 'income'
        ? TransactionType.income
        : TransactionType.expense;
    final categories = await CategoryService.instance.getCategories().first;
    return resolveFallbackCategory(type, categories);
  }

  /// Detects pre-fresh rows in the approved set and (when the feature flag is
  /// on) offers the user to push `account.trackedSince` back so they remain
  /// visible in the account view after commit.
  ///
  /// Return semantics — "should the commit continue?":
  /// - `true` when there are no pre-fresh rows.
  /// - `true` when `account.trackedSince` is null (no tracking configured).
  /// - `true` when the user accepts the dialog (mutation applied).
  /// - `true` when the user dismisses the standard preview dialog without
  ///   accepting (no mutation; pre-fresh rows persist as historical).
  /// - `false` only when the strong-confirm dialog was shown AND actively
  ///   rejected by the user — that's an explicit abort.
  Future<bool> _handlePreFresh(
    Account account,
    List<MatchingResult> approved,
  ) async {
    if (account.trackedSince == null) return true;

    final preFresh = approved.where((r) => r.isPreFresh).toList();
    if (preFresh.isEmpty) return true;

    final proposed = preFresh
        .map((r) => r.row.date)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final proposedTruncated = DateTime(
      proposed.year,
      proposed.month,
      proposed.day,
    );

    final accountService = AccountService.instance;
    final currentBalance = await accountService
        .getAccountsMoney(accountIds: [account.id])
        .first;
    final simulatedBalance = await accountService
        .getAccountsMoneyPreview(
          accountId: account.id,
          simulatedTrackedSince: proposedTruncated,
        )
        .first;

    final bool isStrong = shouldEscalatePreFreshDialog(
      currentBalance: currentBalance,
      simulatedBalance: simulatedBalance,
    );

    if (!mounted) return true;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => isStrong
          ? RetroactiveStrongConfirmDialog(
              currentBalance: currentBalance,
              simulatedBalance: simulatedBalance,
              currency: account.currency,
            )
          : RetroactivePreviewDialog(
              currentBalance: currentBalance,
              simulatedBalance: simulatedBalance,
              currency: account.currency,
            ),
    );

    if (confirmed == true) {
      await accountService.updateAccount(
        account.copyWith(trackedSince: drift.Value(proposedTruncated)),
      );
      if (!mounted) return true;
      await StatementImportFlow.of(context).refreshAccount();
      return true;
    }

    // Strong-confirm with explicit rejection → abort the commit.
    if (isStrong) return false;

    // Standard preview dismissed without accepting → proceed with commit;
    // pre-fresh rows will persist but stay flagged as historical.
    return true;
  }

  Future<void> _commit() async {
    if (_committing) return;
    final flow = StatementImportFlow.of(context);
    final approved = flow.approvedResults ?? const <MatchingResult>[];
    final account = flow.account;
    if (approved.isEmpty) return;

    if (kEnablePreFreshAutoAdjust) {
      final shouldContinue = await _handlePreFresh(account, approved);
      if (!shouldContinue) return;
      if (!mounted) return;
    }

    // Re-read flow + account in case `_handlePreFresh` triggered a refresh.
    final currentFlow = StatementImportFlow.of(context);
    final currentAccount = currentFlow.account;

    setState(() => _committing = true);

    // Pre-resolve fallback categories so every transaction satisfies
    // the XOR constraint (categoryID vs receivingAccountID).
    final incomeCat = await _resolveCategoryForKind('income');
    final expenseCat = await _resolveCategoryForKind('expense');

    if (incomeCat == null || expenseCat == null) {
      if (mounted) {
        setState(() => _committing = false);
        NitidoSnackbar.error(
          SnackbarParams(
            Translations.of(context).statement_import.confirm.error,
            message:
                'No se encontró una categoría por defecto. '
                'Crea al menos una categoría de ingreso y '
                'una de gasto antes de importar.',
          ),
        );
      }
      return;
    }

    final now = DateTime.now();
    final txs = <TransactionInDB>[];

    for (final r in approved) {
      final row = r.row;
      final isIncome = row.kind == 'income';
      final value = isIncome ? row.amount.abs() : -row.amount.abs();
      final fallbackCategory = isIncome ? incomeCat : expenseCat;
      txs.add(
        TransactionInDB(
          id: generateUUID(),
          date: row.date,
          value: value,
          isHidden: false,
          accountID: currentAccount.id,
          type: isIncome ? TransactionType.income : TransactionType.expense,
          status: TransactionStatus.reconciled,
          notes: row.description.isEmpty ? null : row.description,
          categoryID: fallbackCategory.id,
          createdAt: now,
        ),
      );
    }

    try {
      final batchId = await StatementBatchesService.instance.commit(
        accountId: currentAccount.id,
        transactionsToInsert: txs,
        activeModes: currentFlow.activeModes.toList(),
      );
      if (!mounted) return;
      currentFlow.goToSuccess(batchId: batchId, count: txs.length);
    } catch (e, st) {
      debugPrint('ConfirmPage._commit failed: $e\n$st');
      if (!mounted) return;
      setState(() => _committing = false);
      NitidoSnackbar.error(
        SnackbarParams(
          Translations.of(context).statement_import.confirm.error,
          message: '$e',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final flow = StatementImportFlow.of(context);
    final approved = flow.approvedResults ?? const <MatchingResult>[];
    final account = flow.account;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final incomeSum = approved
        .where((r) => r.row.kind == 'income')
        .fold<double>(0, (a, r) => a + r.row.amount.abs());
    final expenseSum = approved
        .where((r) => r.row.kind == 'expense')
        .fold<double>(0, (a, r) => a + r.row.amount.abs());
    final feesSum = approved
        .where((r) => r.row.kind == 'fee')
        .fold<double>(0, (a, r) => a + r.row.amount.abs());

    final neto = incomeSum - expenseSum - feesSum;
    final isInformative = flow.activeModes.contains('informative');

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _committing
              ? null
              : () => StatementImportFlow.of(context).backToReview(),
        ),
        title: Text(t.statement_import.confirm.title),
      ),
      body: Column(
        children: [
          SiHeader(account: account),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              children: [
                Text(
                  t.statement_import.confirm.movements(n: approved.length),
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${approved.length}',
                      style: tt.displaySmall?.copyWith(
                        fontWeight: FontWeight.w300,
                        letterSpacing: -1.5,
                        height: 1.05,
                      ),
                    ),
                  ],
                ),
                if (isInformative) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: cs.primary.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: cs.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            t.statement_import.confirm.informative_chip,
                            style: tt.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.statement_import.confirm.breakdown_title
                            .toUpperCase(),
                        style: tt.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          letterSpacing: 0.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _BreakdownRow(
                        label: t.statement_import.confirm.breakdown_income,
                        amount: incomeSum,
                        prefix: '+',
                        color: Colors.green.shade400,
                        currency: account.currency,
                      ),
                      _BreakdownRow(
                        label: t.statement_import.confirm.breakdown_expense,
                        amount: expenseSum,
                        prefix: '-',
                        color: cs.error,
                        currency: account.currency,
                      ),
                      _BreakdownRow(
                        label: t.statement_import.confirm.breakdown_fees,
                        amount: feesSum,
                        prefix: '-',
                        color: cs.error,
                        currency: account.currency,
                      ),
                      Divider(color: cs.outlineVariant),
                      _BreakdownRow(
                        label: t.statement_import.confirm.breakdown_total,
                        amount: neto.abs(),
                        prefix: neto >= 0 ? '+' : '-',
                        color: neto >= 0 ? Colors.green.shade400 : cs.error,
                        bold: true,
                        currency: account.currency,
                      ),
                      const SizedBox(height: 6),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    t.statement_import.confirm.undo_hint,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: Row(
                children: [
                  OutlinedButton(
                    onPressed: _committing
                        ? null
                        : () => StatementImportFlow.of(context).backToReview(),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 52),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                    ),
                    child: Text(t.statement_import.confirm.back),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _committing || approved.isEmpty
                          ? null
                          : _commit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: _committing
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : Text(t.statement_import.confirm.import_cta),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.label,
    required this.amount,
    required this.prefix,
    required this.color,
    required this.currency,
    this.bold = false,
  });

  final String label;
  final double amount;
  final String prefix;
  final Color color;
  final CurrencyInDB? currency;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: tt.bodyMedium?.copyWith(
                color: bold ? null : cs.onSurfaceVariant,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          Text(
            prefix,
            style: tt.titleSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 2),
          CurrencyDisplayer(
            amountToConvert: amount,
            currency: currency,
            followPrivateMode: false,
            integerStyle: tt.titleSmall!.copyWith(
              color: color,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
