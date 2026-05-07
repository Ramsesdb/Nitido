import 'package:flutter_test/flutter_test.dart';
import 'package:nitido/core/constants/fallback_categories.dart';
import 'package:nitido/core/models/category/category.dart';
import 'package:nitido/core/models/transaction/transaction_type.enum.dart';

Category _cat(
  String id, {
  required CategoryType type,
  String name = 'Cat',
}) => Category(
  id: id,
  name: name,
  iconId: 'payments',
  displayOrder: 0,
  color: '737373',
  type: type,
);

void main() {
  group('resolveFallbackCategorySync', () {
    test('expense → returns C19 when present (type "B" accepted)', () {
      final cats = [
        _cat('C10', type: CategoryType.E, name: 'Alimentacion'),
        _cat('C19', type: CategoryType.B, name: 'Otros Gastos'),
        _cat('C03', type: CategoryType.I, name: 'Otros Ingresos'),
      ];

      final result = resolveFallbackCategorySync(
        TransactionType.expense,
        cats,
      );

      expect(result, isNotNull);
      expect(result!.id, equals(kFallbackExpenseCategoryId));
      expect(result.id, equals('C19'));
    });

    test('income → returns C03 when present', () {
      final cats = [
        _cat('C10', type: CategoryType.E, name: 'Alimentacion'),
        _cat('C19', type: CategoryType.B, name: 'Otros Gastos'),
        _cat('C03', type: CategoryType.I, name: 'Otros Ingresos'),
      ];

      final result = resolveFallbackCategorySync(
        TransactionType.income,
        cats,
      );

      expect(result, isNotNull);
      expect(result!.id, equals(kFallbackIncomeCategoryId));
      expect(result.id, equals('C03'));
    });

    test(
      'expense → falls back to first expense-eligible when C19 deleted',
      () {
        final cats = [
          _cat('C10', type: CategoryType.E, name: 'Alimentacion'),
          _cat('C12', type: CategoryType.E, name: 'Transporte'),
          _cat('C03', type: CategoryType.I, name: 'Otros Ingresos'),
        ];

        final result = resolveFallbackCategorySync(
          TransactionType.expense,
          cats,
        );

        expect(result, isNotNull);
        expect(result!.id, equals('C10'));
      },
    );

    test(
      'income → falls back to first income-eligible when C03 deleted',
      () {
        final cats = [
          _cat('C10', type: CategoryType.E, name: 'Alimentacion'),
          _cat('C99', type: CategoryType.B, name: 'Mixta'),
        ];

        final result = resolveFallbackCategorySync(
          TransactionType.income,
          cats,
        );

        expect(result, isNotNull);
        expect(result!.id, equals('C99'));
      },
    );

    test('expense → only income-only categories present → null', () {
      final cats = [
        _cat('C03', type: CategoryType.I, name: 'Otros Ingresos'),
        _cat('C04', type: CategoryType.I, name: 'Salario'),
      ];

      final result = resolveFallbackCategorySync(
        TransactionType.expense,
        cats,
      );

      expect(result, isNull);
    });

    test('empty list → null', () {
      final result = resolveFallbackCategorySync(
        TransactionType.expense,
        const [],
      );

      expect(result, isNull);
    });

    test('transfer type → null (transfers carry no category)', () {
      final cats = [
        _cat('C19', type: CategoryType.B, name: 'Otros Gastos'),
      ];

      final result = resolveFallbackCategorySync(
        TransactionType.transfer,
        cats,
      );

      expect(result, isNull);
    });

    test(
      'expense lookup ignores income-only category that shares the seed ID',
      () {
        final cats = [
          _cat('C19', type: CategoryType.I, name: 'Wrongly typed C19'),
          _cat('C50', type: CategoryType.E, name: 'Real expense'),
        ];

        final result = resolveFallbackCategorySync(
          TransactionType.expense,
          cats,
        );

        expect(result, isNotNull);
        expect(result!.id, equals('C50'));
      },
    );
  });

  group('resolveFallbackCategory (async wrapper)', () {
    test('returns the same result as the sync helper', () async {
      final cats = [
        _cat('C19', type: CategoryType.B, name: 'Otros Gastos'),
      ];

      final asyncResult =
          await resolveFallbackCategory(TransactionType.expense, cats);
      final syncResult =
          resolveFallbackCategorySync(TransactionType.expense, cats);

      expect(asyncResult?.id, equals(syncResult?.id));
      expect(asyncResult?.id, equals('C19'));
    });
  });
}
