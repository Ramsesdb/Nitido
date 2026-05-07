import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitido/i18n/generated/translations.g.dart';

/// Widget test 1.11c — verifies that the processing screen's progress
/// pattern (`ValueListenableBuilder<int>` over `currentImageIndex`)
/// renders the i18n key `STATEMENT_IMPORT.PROCESSING.progress` as
/// "Procesando N de M".
///
/// We avoid pumping the full ProcessingPage (which boots the extractor
/// service + matching engine) and instead assemble the same builder
/// shape in isolation: a `ValueNotifier<int>` driving a
/// `ValueListenableBuilder<int>` that calls
/// `t.statement_import.processing.progress(current:..., total:...)`.
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

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.notifier, required this.total});

  final ValueNotifier<int> notifier;
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: notifier,
      builder: (ctx, idx, _) => Text(
        t.statement_import.processing.progress(
          current: idx + 1,
          total: total,
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.es);
  });

  testWidgets('renders "Procesando 2 de 5" when notifier value is 1', (
    tester,
  ) async {
    final notifier = ValueNotifier<int>(1);
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      _wrap(_ProgressLine(notifier: notifier, total: 5)),
    );

    expect(find.text('Procesando 2 de 5'), findsOneWidget);
  });

  testWidgets('updates text reactively when notifier value changes', (
    tester,
  ) async {
    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      _wrap(_ProgressLine(notifier: notifier, total: 3)),
    );

    expect(find.text('Procesando 1 de 3'), findsOneWidget);

    notifier.value = 2;
    await tester.pump();

    expect(find.text('Procesando 1 de 3'), findsNothing);
    expect(find.text('Procesando 3 de 3'), findsOneWidget);
  });

  testWidgets('all_failed key resolves to Spanish copy', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (ctx) {
            final t = Translations.of(ctx);
            return Text(t.statement_import.processing.all_failed);
          },
        ),
      ),
    );

    expect(
      find.text('No se pudo extraer nada de las imágenes'),
      findsOneWidget,
    );
  });

  testWidgets('image_failed renders "Imagen 2: ..."', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (ctx) {
            final t = Translations.of(ctx);
            return Text(t.statement_import.review.image_failed(index: 2));
          },
        ),
      ),
    );

    expect(
      find.text('Imagen 2: no se extrajeron movimientos'),
      findsOneWidget,
    );
  });
}
