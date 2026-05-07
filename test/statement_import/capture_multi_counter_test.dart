import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitido/i18n/generated/translations.g.dart';

/// Widget test 1.11b — verifies the i18n key
/// `STATEMENT_IMPORT.CAPTURE.multi-count` renders the localized
/// "{n} imágenes" string used by the capture page's `_MultiCounter`.
///
/// We mirror the exact `Text(t.statement_import.capture.multi_count(...))`
/// call site shape so the assertion fails fast if either the key path
/// changes or the slang signature drifts.
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

  testWidgets('multi_count renders "3 imágenes" in Spanish', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (ctx) {
            final t = Translations.of(ctx);
            return Text(t.statement_import.capture.multi_count(n: 3));
          },
        ),
      ),
    );

    expect(find.text('3 imágenes'), findsOneWidget);
  });

  testWidgets('multi_count renders "1 imágenes" for n=1 (no plural rule)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (ctx) {
            final t = Translations.of(ctx);
            return Text(t.statement_import.capture.multi_count(n: 1));
          },
        ),
      ),
    );

    expect(find.text('1 imágenes'), findsOneWidget);
  });

  testWidgets('multi_count renders "10 imágenes" at the cap', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (ctx) {
            final t = Translations.of(ctx);
            return Text(t.statement_import.capture.multi_count(n: 10));
          },
        ),
      ),
    );

    expect(find.text('10 imágenes'), findsOneWidget);
  });
}
