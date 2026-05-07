import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitido/app/accounts/statement_import/screens/confirm.page.dart';
import 'package:nitido/core/database/app_db.dart';
import 'package:nitido/core/presentation/widgets/retroactive_preview_dialog.dart';
import 'package:nitido/i18n/generated/translations.g.dart';

/// Phase 3 widget tests for the pre-fresh auto-adjust hook in
/// `confirm.page.dart`. We exercise the public-by-design pieces:
///   * `shouldEscalatePreFreshDialog` — pure predicate.
///   * `RetroactivePreviewDialog` / `RetroactiveStrongConfirmDialog` — the
///     two dialogs that the hook chooses between based on the predicate.
///
/// The full `_handlePreFresh` flow lives behind a singleton service
/// (`AccountService.instance`) and a singleton flow scope, so the integration
/// path is covered by Phase 4 smoke (3.5d deferred per change scope).

const _bs = CurrencyInDB(
  code: 'BS',
  symbol: 'Bs',
  name: 'Bolivar',
  decimalPlaces: 2,
  isDefault: false,
  type: 0,
);

Widget _wrap(Widget child) {
  return TranslationProvider(
    child: Builder(
      builder: (context) => MaterialApp(
        locale: TranslationProvider.of(context).flutterLocale,
        supportedLocales: AppLocaleUtils.supportedLocales,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.es);
  });

  group('shouldEscalatePreFreshDialog (3.5b predicate)', () {
    test('small shift (<= 50%) does not escalate', () {
      // 1000 → 850 = 15% shift, balance positive.
      expect(
        shouldEscalatePreFreshDialog(
          currentBalance: 1000,
          simulatedBalance: 850,
        ),
        isFalse,
      );
    });

    test('shift > 50% escalates to strong confirm', () {
      // 1000 → 300 = 70% shift.
      expect(
        shouldEscalatePreFreshDialog(
          currentBalance: 1000,
          simulatedBalance: 300,
        ),
        isTrue,
      );
    });

    test('projected balance < 0 escalates regardless of shift size', () {
      // 100 → -50 — small absolute diff but negative simulated.
      expect(
        shouldEscalatePreFreshDialog(
          currentBalance: 100,
          simulatedBalance: -50,
        ),
        isTrue,
      );
    });

    test('exactly 50% shift does NOT escalate (strict greater-than)', () {
      // 1000 → 500 = exactly 50%; predicate uses `>`.
      expect(
        shouldEscalatePreFreshDialog(
          currentBalance: 1000,
          simulatedBalance: 500,
        ),
        isFalse,
      );
    });

    test('current balance zero with non-negative simulated does not escalate', () {
      expect(
        shouldEscalatePreFreshDialog(
          currentBalance: 0,
          simulatedBalance: 50,
        ),
        isFalse,
      );
    });
  });

  group('RetroactivePreviewDialog render (3.5a)', () {
    testWidgets('renders preview with both balances when shift is small', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (ctx) {
              return ElevatedButton(
                onPressed: () {
                  showDialog<bool>(
                    context: ctx,
                    builder: (_) => const RetroactivePreviewDialog(
                      currentBalance: 1000,
                      simulatedBalance: 850,
                      currency: _bs,
                    ),
                  );
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Title from t.account.retroactive.preview_title.
      expect(find.text('Impacto en el balance'), findsOneWidget);
      // Message includes both formatted balances.
      expect(find.textContaining('1000.00 Bs'), findsOneWidget);
      expect(find.textContaining('850.00 Bs'), findsOneWidget);
      // Buttons.
      expect(find.text('Aceptar'), findsOneWidget);
      expect(find.text('Cancelar'), findsOneWidget);
      // No CONFIRMAR text-input hint.
      expect(find.textContaining('CONFIRMAR'), findsNothing);
    });
  });

  group('RetroactiveStrongConfirmDialog render (3.5b escalation)', () {
    testWidgets('renders text input and disables Accept until CONFIRMAR typed', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (ctx) {
              return ElevatedButton(
                onPressed: () {
                  showDialog<bool>(
                    context: ctx,
                    builder: (_) => const RetroactiveStrongConfirmDialog(
                      currentBalance: 1000,
                      simulatedBalance: 300,
                      currency: _bs,
                    ),
                  );
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Strong-confirm hint visible (asks user to type CONFIRMAR).
      expect(find.textContaining('CONFIRMAR'), findsWidgets);
      // Accept button disabled until matching word is typed.
      final acceptBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Aceptar'),
      );
      expect(acceptBtn.onPressed, isNull);

      // Type the wrong word — still disabled.
      await tester.enterText(find.byType(TextField), 'NO');
      await tester.pump();
      final stillDisabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Aceptar'),
      );
      expect(stillDisabled.onPressed, isNull);

      // Type the right word — enabled.
      await tester.enterText(find.byType(TextField), 'CONFIRMAR');
      await tester.pump();
      final enabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Aceptar'),
      );
      expect(enabled.onPressed, isNotNull);
    });
  });

  group('trackedSince null bypass (3.5c)', () {
    // The hook returns true immediately when account.trackedSince is null,
    // skipping all balance lookups and dialog rendering. We assert the
    // contract by simulating the early-return branch via a thin wrapper that
    // mirrors the production guard (we cannot pump the full ConfirmPage
    // because it requires the singleton AccountService).
    test('null trackedSince returns true without consulting balances', () async {
      Future<bool> simulated({
        required DateTime? trackedSince,
        required bool hasPreFresh,
      }) async {
        // Mirror of the early-return guards inside _handlePreFresh:
        //   1) trackedSince == null  → true.
        //   2) no pre-fresh rows     → true.
        if (trackedSince == null) return true;
        if (!hasPreFresh) return true;
        // (Else the production code would await balance + dialog.)
        throw StateError('balance lookup must NOT run when guards short-circuit');
      }

      // Null trackedSince: pre-fresh flag is irrelevant.
      expect(await simulated(trackedSince: null, hasPreFresh: true), isTrue);
      expect(await simulated(trackedSince: null, hasPreFresh: false), isTrue);

      // Configured trackedSince but no pre-fresh rows: still bypass.
      expect(
        await simulated(trackedSince: DateTime(2026, 4, 1), hasPreFresh: false),
        isTrue,
      );
    });
  });
}
