import 'dart:async';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:monekin/app/layout/page_framework.dart';
import 'package:monekin/core/database/services/transaction/transaction_service.dart';
import 'package:monekin/core/extensions/color.extensions.dart';
import 'package:monekin/core/extensions/date.extensions.dart';
import 'package:monekin/core/models/transaction/transaction.dart';
import 'package:monekin/core/models/transaction/transaction_type.enum.dart';
import 'package:monekin/core/presentation/app_colors.dart';
import 'package:monekin/core/presentation/widgets/transaction_filter/transaction_filter_set.dart';
import 'package:monekin/core/services/dolar_api_service.dart';
import 'package:monekin/core/utils/date_time_picker.dart';
import 'package:monekin/core/database/services/category/category_service.dart';
import 'package:monekin/core/models/category/category.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:share_plus/share_plus.dart';

/// Settlement Report ("Reporte de Liquidación")
///
/// Features:
/// - Date range presets (Hoy / Semana / Mes / Custom)
/// - Percentage slider with haptic feedback
/// - Account breakdown with color-coded progress bars
/// - VES/USD toggle with rate status (live / cached / manual)
/// - VES rounded to integers (céntimos don't exist physically)
class SettlementReportPage extends StatefulWidget {
  const SettlementReportPage({super.key});

  @override
  State<SettlementReportPage> createState() => _SettlementReportPageState();
}

class _SettlementReportPageState extends State<SettlementReportPage>
    with SingleTickerProviderStateMixin {
  // --- State ---
  late DateTime _startDate;
  late DateTime _endDate;
  double _percentage = 20.0;
  bool _showInUsd = false;
  double? _bcvRate;
  double? _paraleloRate;
  _RateType _rateType = _RateType.bcv;
  bool _loadingRate = true;
  bool _isManualRate = false;
  bool _isStaleRate = false;

  // Quick presets
  static const _presets = ['Hoy', 'Semana', 'Mes', 'Otro'];
  String _activePreset = 'Semana';

  // Animation
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeInOut);
    _fadeCtrl.forward();
    _applyPreset('Semana');
    unawaited(_fetchRate());
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _applyPreset(String preset) {
    final now = DateTime.now();
    setState(() {
      _activePreset = preset;
      switch (preset) {
        case 'Hoy':
          _startDate = DateTime(now.year, now.month, now.day);
          _endDate = DateTime(now.year, now.month, now.day, 23, 59, 59);
          break;
        case 'Semana':
          final weekday = now.weekday;
          _startDate = DateTime(now.year, now.month, now.day - (weekday - 1));
          _endDate = DateTime(now.year, now.month, now.day, 23, 59, 59);
          break;
        case 'Mes':
          _startDate = DateTime(now.year, now.month, 1);
          _endDate = DateTime(now.year, now.month, now.day, 23, 59, 59);
          break;
        default:
          break;
      }
    });
    _fadeCtrl.reset();
    _fadeCtrl.forward();
  }

  Future<void> _fetchRate() async {
    setState(() => _loadingRate = true);
    final rates = await DolarApiService.instance.fetchAllRates();
    if (mounted) {
      final svc = DolarApiService.instance;
      setState(() {
        _bcvRate = svc.oficialRate?.promedio;
        _paraleloRate = svc.paraleloRate?.promedio;
        // Apply the currently selected rate type
        _applyRateType(_rateType);
        _loadingRate = false;
        _isManualRate = false;
        _isStaleRate = svc.isStale;
      });
    }
  }

  /// Apply the selected rate type
  void _applyRateType(_RateType type) {
    setState(() {
      _rateType = type;
      _isManualRate = type == _RateType.manual;
      if (type == _RateType.bcv && _bcvRate != null) {
        // Rate already in _bcvRate, used by _fmt via
        // _activeRate getter
      } else if (type == _RateType.paralelo && _paraleloRate != null) {
        // Rate from _paraleloRate
      }
    });
    _fadeCtrl.reset();
    unawaited(_fadeCtrl.forward());
  }

  /// Current active rate based on selection
  double? get _activeRate {
    switch (_rateType) {
      case _RateType.bcv:
        return _bcvRate;
      case _RateType.paralelo:
        return _paraleloRate;
      case _RateType.manual:
        return _bcvRate; // Manual overwrites _bcvRate
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await openDateTimePicker(
      context,
      initialDate: isStart ? _startDate : _endDate,
      showTimePickerAfterDate: false,
    );
    if (picked != null) {
      setState(() {
        _activePreset = 'Otro';
        if (isStart) {
          _startDate = picked.justDay();
        } else {
          _endDate = DateTime(
            picked.year,
            picked.month,
            picked.day,
            23,
            59,
            59,
          );
        }
      });
      _fadeCtrl.reset();
      _fadeCtrl.forward();
    }
  }

  /// Format amount with correct decimals:
  /// - Base amounts are in Bs.S (preferred currency)
  /// - VES (default): 2 decimals, locale es_VE
  /// - USD (toggle): divide by active rate, 2 decimals
  String _fmt(double amount) {
    final rate = _activeRate;
    if (_showInUsd && rate != null && rate > 0) {
      final usd = amount / rate;
      return NumberFormat.currency(
        locale: 'es_VE',
        symbol: '\$ ',
        decimalDigits: 2,
      ).format(usd);
    }
    // Default: show in Bs.S with 2 decimals
    return NumberFormat.currency(
      locale: 'es_VE',
      symbol: 'Bs. ',
      decimalDigits: 2,
    ).format(amount);
  }

  bool get _exportInUsd {
    final rate = _activeRate;
    return _showInUsd && rate != null && rate > 0;
  }

  String get _exportCurrencyCode => _exportInUsd ? 'USD' : 'VES';

  String _fmtNumber(double amount) {
    final rate = _activeRate;
    final value = _exportInUsd && rate != null && rate > 0
        ? amount / rate
        : amount;
    final locale = _exportInUsd ? 'en_US' : 'es_VE';
    return NumberFormat('#,##0.00', locale).format(value);
  }

  /// Show dialog to manually enter the rate
  void _showManualRateDialog() {
    final controller = TextEditingController(
      text: (_activeRate)?.toStringAsFixed(2) ?? '',
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tasa Manual'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ingresa la tasa manualmente '
              '(útil cuando no hay internet)',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Tasa Bs/\$',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.edit),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text);
              if (parsed != null && parsed > 0) {
                setState(() {
                  _bcvRate = parsed;
                  _rateType = _RateType.manual;
                  _isManualRate = true;
                  _isStaleRate = false;
                });
                Navigator.pop(ctx);
                _fadeCtrl.reset();
                unawaited(_fadeCtrl.forward());
              }
            },
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    final filter = TransactionFilterSet(minDate: _startDate, maxDate: _endDate);

    return PageFramework(
      title: 'Reporte de Iglesia',
      appBarActions: [
        // Currency toggle badge
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            avatar: Icon(
              _showInUsd ? Icons.attach_money : Icons.currency_exchange,
              size: 18,
              color: colors.onConsistentPrimary,
            ),
            label: Text(
              _showInUsd ? 'USD' : 'VES',
              style: TextStyle(
                color: colors.onConsistentPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: colors.consistentPrimary,
            side: BorderSide.none,
            onPressed: () {
              setState(() => _showInUsd = !_showInUsd);
              _fadeCtrl.reset();
              _fadeCtrl.forward();
            },
          ),
        ),
      ],
      body: StreamBuilder<List<dynamic>>(
        stream: Rx.combineLatest2(
          TransactionService.instance.getTransactions(filters: filter),
          CategoryService.instance.getCategories(),
          (txs, cats) => [txs, cats],
        ),
        builder: (context, snapshot) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Active Filter Banner (Fix #4)
                _buildFilterBanner(theme),
                const SizedBox(height: 12),

                _buildDateRangeSelector(colors, theme),
                const SizedBox(height: 16),
                _buildPercentageSlider(colors, theme),
                const SizedBox(height: 16),

                // Rate Selector (BCV / Paralelo / Manual)
                _buildRateSelector(colors, theme),
                const SizedBox(height: 16),

                if (!snapshot.hasData)
                  const Padding(
                    padding: EdgeInsets.all(48),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if ((snapshot.data![0] as List<MoneyTransaction>).isEmpty)
                  _buildEmptyState(theme)
                else
                  FadeTransition(
                    opacity: _fadeAnim,
                    child: _buildReport(
                      snapshot.data![0] as List<MoneyTransaction>,
                      snapshot.data![1] as List<Category>,
                      colors,
                      theme,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ─── Filter Banner ────────────────────────────────────

  Widget _buildFilterBanner(ThemeData theme) {
    final fmt = DateFormat('dd/MM/yyyy');
    final days = _endDate.difference(_startDate).inDays + 1;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.primary.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.filter_list, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
                children: [
                  TextSpan(
                    text: fmt.format(_startDate),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(text: '  →  '),
                  TextSpan(
                    text: fmt.format(_endDate),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(text: '  ($days días)'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Rate Status Indicator ────────────────────────────

  Widget _buildRateSelector(AppColors colors, ThemeData theme) {
    final rate = _activeRate;
    // Status line text
    String statusText;
    Color statusColor;
    IconData statusIcon;

    if (_loadingRate) {
      statusText = 'Cargando tasas...';
      statusColor = Colors.grey;
      statusIcon = Icons.sync;
    } else if (rate == null) {
      statusText = 'Sin tasa disponible';
      statusColor = Colors.red;
      statusIcon = Icons.error_outline;
    } else if (_isStaleRate && !_isManualRate) {
      statusText =
          'Tasa guardada: ${rate.toStringAsFixed(2)}'
          ' Bs/\$';
      statusColor = Colors.orange;
      statusIcon = Icons.warning_amber;
    } else {
      final typeLabel = _rateType == _RateType.bcv
          ? 'BCV'
          : _rateType == _RateType.paralelo
          ? 'Paralelo'
          : 'Manual';
      statusText =
          'Tasa $typeLabel: ${rate.toStringAsFixed(2)}'
          ' Bs/\$';
      statusColor = _isManualRate
          ? Colors.amber.shade700
          : Colors.green.shade700;
      statusIcon = _isManualRate ? Icons.edit : Icons.check_circle_outline;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Segmented toggle: BCV | Paralelo | Manual
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              _buildRateTab(
                label: 'BCV',
                subtitle: _bcvRate != null
                    ? '${_bcvRate!.toStringAsFixed(2)}'
                    : '—',
                selected: _rateType == _RateType.bcv,
                onTap: () => _applyRateType(_RateType.bcv),
                theme: theme,
                colors: colors,
              ),
              _buildRateTab(
                label: 'Paralelo',
                subtitle: _paraleloRate != null
                    ? '${_paraleloRate!.toStringAsFixed(2)}'
                    : '—',
                selected: _rateType == _RateType.paralelo,
                onTap: () => _applyRateType(_RateType.paralelo),
                theme: theme,
                colors: colors,
              ),
              _buildRateTab(
                label: 'Manual',
                subtitle: _isManualRate
                    ? '${_bcvRate?.toStringAsFixed(2)}'
                    : '✎',
                selected: _rateType == _RateType.manual,
                onTap: _showManualRateDialog,
                theme: theme,
                colors: colors,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Status line
        Row(
          children: [
            Icon(statusIcon, size: 14, color: statusColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                statusText,
                style: TextStyle(
                  fontSize: 12,
                  color: statusColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            InkWell(
              onTap: _fetchRate,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.refresh, size: 16, color: statusColor),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRateTab({
    required String label,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    required ThemeData theme,
    required AppColors colors,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? colors.consistentPrimary : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: selected
                      ? colors.onConsistentPrimary
                      : theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: selected
                      ? colors.onConsistentPrimary.withOpacity(0.8)
                      : theme.colorScheme.onSurface.withOpacity(0.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Date Range Selector ──────────────────────────────

  Widget _buildDateRangeSelector(AppColors colors, ThemeData theme) {
    final dateFormat = DateFormat('dd MMM yyyy');

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withOpacity(0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.date_range,
                  size: 20,
                  color: colors.consistentPrimary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Periodo',
                  style: theme.textTheme.titleSmall!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Preset chips row
            Row(
              children: _presets.map((preset) {
                final isActive = _activePreset == preset;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Text(
                        preset,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isActive
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      selected: isActive,
                      showCheckmark: false,
                      selectedColor: colors.consistentPrimary,
                      labelStyle: TextStyle(
                        color: isActive ? colors.onConsistentPrimary : null,
                      ),
                      onSelected: (_) {
                        if (preset == 'Otro') {
                          _pickDate(isStart: true);
                        } else {
                          _applyPreset(preset);
                        }
                      },
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 12),

            // Date tiles
            Row(
              children: [
                Expanded(
                  child: _buildDateTile(
                    label: 'Desde',
                    date: dateFormat.format(_startDate),
                    onTap: () => _pickDate(isStart: true),
                    theme: theme,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                  ),
                ),
                Expanded(
                  child: _buildDateTile(
                    label: 'Hasta',
                    date: dateFormat.format(_endDate),
                    onTap: () => _pickDate(isStart: false),
                    theme: theme,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateTile({
    required String label,
    required String date,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall!.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              date,
              style: theme.textTheme.bodyMedium!.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Percentage Slider ────────────────────────────────

  Widget _buildPercentageSlider(AppColors colors, ThemeData theme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withOpacity(0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.pie_chart_outline,
                      size: 20,
                      color: colors.consistentPrimary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Porcentaje Pastoral',
                      style: theme.textTheme.titleSmall!.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colors.consistentPrimary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${_percentage.toStringAsFixed(0)}%',
                    style: TextStyle(
                      color: colors.onConsistentPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: colors.consistentPrimary,
                thumbColor: colors.consistentPrimary,
                inactiveTrackColor: colors.consistentPrimary.withOpacity(0.2),
                overlayColor: colors.consistentPrimary.withOpacity(0.1),
                trackHeight: 6,
              ),
              child: Slider(
                value: _percentage,
                min: 0,
                max: 100,
                divisions: 20,
                label: '${_percentage.toStringAsFixed(0)}%',
                onChanged: (val) {
                  HapticFeedback.selectionClick();
                  setState(() => _percentage = val);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Main Report Body ─────────────────────────────────

  Widget _buildReport(
    List<MoneyTransaction> transactions,
    List<Category> categories,
    AppColors colors,
    ThemeData theme,
  ) {
    // Determine INCOMES and EXPENSES accurately for tithe logic
    final incomes = transactions
        .where((tx) => tx.type == TransactionType.income)
        .toList();
    final expenses = transactions
        .where((tx) => tx.type == TransactionType.expense)
        .toList();

    double totalIncome = 0;
    double titheableIncome = 0;
    double nonTitheableIncome = 0;

    Map<String, double> directIncomesByCategory = {};
    Map<String, double> expensesByCategory = {};

    for (final tx in incomes) {
      final val = tx.currentValueInPreferredCurrency.abs();
      totalIncome += val;
      
      if (tx.calcTithe) {
        titheableIncome += val;
      } else {
        nonTitheableIncome += val;
      }

      if (tx.category != null) {
        directIncomesByCategory[tx.category!.id] =
            (directIncomesByCategory[tx.category!.id] ?? 0) + val;
      }
    }
    
    for (final tx in expenses) {
      final val = tx.currentValueInPreferredCurrency.abs();
      if (tx.category != null) {
        expensesByCategory[tx.category!.id] =
            (expensesByCategory[tx.category!.id] ?? 0) + val;
      }
    }

    final pastoralShare = titheableIncome * (_percentage / 100);
    final churchRetains = totalIncome - pastoralShare;

    // Calculate Sub-funds
    final List<_SubFundBalance> subFundBalances = [];
    for (final cat in categories) {
      if (cat.subFundPercent > 0 ||
          directIncomesByCategory.containsKey(cat.id) ||
          expensesByCategory.containsKey(cat.id)) {
        final initialAllocation = totalIncome * (cat.subFundPercent / 100);
        final directInc = directIncomesByCategory[cat.id] ?? 0.0;
        final totalExp = expensesByCategory[cat.id] ?? 0.0;
        
        subFundBalances.add(_SubFundBalance(
            category: cat,
            initialAllocation: initialAllocation,
            directIncome: directInc,
            totalExpenses: totalExp,
        ));
      }
    }

    // Group by Account for proportional breakdown
    final grouped = groupBy(incomes, (MoneyTransaction tx) => tx.account.name);

    final breakdownEntries = <_BreakdownEntry>[];
    for (final entry in grouped.entries) {
      double accIncome = 0;
      double accTitheable = 0;
      for (final tx in entry.value) {
        final val = tx.currentValueInPreferredCurrency.abs();
        accIncome += val;
        if (tx.calcTithe) accTitheable += val;
      }
      final proportion = titheableIncome > 0 ? accTitheable / titheableIncome : 0.0;
      breakdownEntries.add(
        _BreakdownEntry(
          accountName: entry.key,
          totalIncome: accIncome,
          shareAmount: pastoralShare * proportion,
          transactionCount: entry.value.length,
          proportion: proportion,
        ),
      );
    }

    breakdownEntries.sort((a, b) => b.totalIncome.compareTo(a.totalIncome));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Hero: Total Income ───
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                colors.consistentPrimary,
                colors.consistentPrimary.withOpacity(0.8),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              Text(
                'Resumen de Diezmos y Aportes',
                style: TextStyle(
                  color: colors.onConsistentPrimary.withOpacity(0.8),
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Ingreso General Total', style: TextStyle(color: colors.onConsistentPrimary.withOpacity(0.8))),
                  Text(_fmt(totalIncome), style: TextStyle(color: colors.onConsistentPrimary, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Ingreso Diezmable (Base)', style: TextStyle(color: colors.onConsistentPrimary.withOpacity(0.8))),
                  Text(_fmt(titheableIncome), style: TextStyle(color: Colors.greenAccent[100], fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Ingreso No Diezmable', style: TextStyle(color: colors.onConsistentPrimary.withOpacity(0.8))),
                  Text(_fmt(nonTitheableIncome), style: TextStyle(color: colors.onConsistentPrimary.withOpacity(0.7), fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                height: 1,
                color: colors.onConsistentPrimary.withOpacity(0.2),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildHeroSplit(
                      label:
                          'Pastor '
                          '(${_percentage.toStringAsFixed(0)}%)',
                      amount: pastoralShare,
                      icon: Icons.person,
                      colors: colors,
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 40,
                    color: colors.onConsistentPrimary.withOpacity(0.2),
                  ),
                  Expanded(
                    child: _buildHeroSplit(
                      label: 'Iglesia',
                      amount: churchRetains,
                      icon: Icons.church,
                      colors: colors,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // ── Breakdown Header ───
        Row(
          children: [
            Icon(
              Icons.account_balance_wallet,
              size: 20,
              color: colors.consistentPrimary,
            ),
            const SizedBox(width: 8),
            Text(
              'Desglose por Cuenta',
              style: theme.textTheme.titleSmall!.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Distribución proporcional del '
          'porcentaje pastoral',
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.onSurface.withOpacity(0.5),
          ),
        ),
        const SizedBox(height: 12),

        ...breakdownEntries.asMap().entries.map((mapEntry) {
          final idx = mapEntry.key;
          final entry = mapEntry.value;
          final tintColors = [
            Colors.blue,
            Colors.teal,
            Colors.orange,
            Colors.purple,
            Colors.indigo,
          ];
          final tint = tintColors[idx % tintColors.length];

          return Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: tint.withOpacity(0.2)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: tint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.accountName,
                          style: theme.textTheme.titleSmall!.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: tint.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${entry.transactionCount} mov.',
                          style: TextStyle(
                            fontSize: 11,
                            color: tint.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: entry.proportion,
                      minHeight: 6,
                      backgroundColor: tint.withOpacity(0.1),
                      valueColor: AlwaysStoppedAnimation(tint),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Total: ${_fmt(entry.totalIncome)}',
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        'Pastor: '
                        '${_fmt(entry.shareAmount)}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: tint.shade700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),

        const SizedBox(height: 16),

        // Footer
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${incomes.length} ingresos en este periodo',
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ),
        ),

        const SizedBox(height: 24),

        // ── Sub-Funds Section ───
        Row(
          children: [
            Icon(
              Icons.account_tree_outlined,
              size: 20,
              color: colors.consistentPrimary,
            ),
            const SizedBox(width: 8),
            Text(
              'Apartados (Sub-Fondos)',
              style: theme.textTheme.titleSmall!.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (subFundBalances.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No hay categorías configuradas como apartados con porcentaje asignado o con movimientos directos.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ),
          )
        else
          ...subFundBalances.map((subFund) {
            final catColor = ColorHex.get(subFund.category.color);
            return Card(
              elevation: 0,
              margin: const EdgeInsets.symmetric(vertical: 6.0),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: catColor.withOpacity(0.2)),
              ),
              child: ExpansionTile(
                leading: subFund.category.icon.display(color: catColor, size: 32),
                title: Text(
                  subFund.category.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  'Disponible: ${_fmt(subFund.totalAvailable)}',
                  style: TextStyle(color: catColor, fontWeight: FontWeight.w600),
                ),
                childrenPadding: const EdgeInsets.all(16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Asignación (${subFund.category.subFundPercent}%)', style: theme.textTheme.bodyMedium),
                      Text(_fmt(subFund.initialAllocation), style: const TextStyle(fontWeight: FontWeight.w500)),
                    ],
                  ),
                  if (subFund.directIncome > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Ingresos Directos', style: theme.textTheme.bodyMedium),
                          Text(_fmt(subFund.directIncome), style: const TextStyle(fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Gastos Realizados', style: theme.textTheme.bodyMedium),
                          Text(_fmt(subFund.totalExpenses), style: const TextStyle(fontWeight: FontWeight.w500)),
                        ],
                      ),
                  ),
                ],
              ),
            );
          }),

        const SizedBox(height: 24),

        // ── Export Buttons ──
        _buildExportSection(
          incomes: incomes,
          totalIncome: totalIncome,
          pastoralShare: pastoralShare,
          churchRetains: churchRetains,
          breakdownEntries: breakdownEntries,
          colors: colors,
          theme: theme,
        ),
      ],
    );
  }

  // ── Export Section ─────────────────────────────

  Widget _buildExportSection({
    required List<MoneyTransaction> incomes,
    required double totalIncome,
    required double pastoralShare,
    required double churchRetains,
    required List<_BreakdownEntry> breakdownEntries,
    required AppColors colors,
    required ThemeData theme,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.share, size: 18, color: colors.consistentPrimary),
              const SizedBox(width: 8),
              Text(
                'Exportar Corte',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Genera un archivo CSV para compartir',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _exportExcel(
                    detailed: false,
                    incomes: incomes,
                    totalIncome: totalIncome,
                    pastoralShare: pastoralShare,
                    churchRetains: churchRetains,
                    breakdown: breakdownEntries,
                  ),
                  icon: const Icon(Icons.summarize, size: 18),
                  label: const Text('Excel Resumen'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: colors.consistentPrimary),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _exportExcel(
                    detailed: true,
                    incomes: incomes,
                    totalIncome: totalIncome,
                    pastoralShare: pastoralShare,
                    churchRetains: churchRetains,
                    breakdown: breakdownEntries,
                  ),
                  icon: const Icon(Icons.table_chart, size: 18),
                  label: const Text('Excel Detallado'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    backgroundColor: colors.consistentPrimary,
                    foregroundColor: colors.onConsistentPrimary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Export Excel (.xlsx) and share
  Future<void> _exportExcel({
    required bool detailed,
    required List<MoneyTransaction> incomes,
    required double totalIncome,
    required double pastoralShare,
    required double churchRetains,
    required List<_BreakdownEntry> breakdown,
  }) async {
    final dateFmt = DateFormat('dd/MM/yyyy');
    final from = dateFmt.format(_startDate);
    final to = dateFmt.format(_endDate);
    final rate = _activeRate;
    final rateLabel = _rateType == _RateType.bcv
        ? 'BCV'
        : _rateType == _RateType.paralelo
        ? 'Paralelo'
        : 'Manual';
    final rateStr = rate != null ? '${rate.toStringAsFixed(2)} Bs/\$' : 'N/A';

    final excel = xl.Excel.createExcel();
    final summarySheet = excel['Resumen'];
    excel.delete('Sheet1');

    final titleStyle = xl.CellStyle(
      bold: true,
      fontSize: 14,
      horizontalAlign: xl.HorizontalAlign.Center,
      backgroundColorHex: xl.ExcelColor.fromHexString('FF0F3375'),
      fontColorHex: xl.ExcelColor.fromHexString('FFFFFFFF'),
    );
    final headerStyle = xl.CellStyle(
      bold: true,
      backgroundColorHex: xl.ExcelColor.fromHexString('FFE6EEF9'),
    );
    final labelStyle = xl.CellStyle(bold: true);

    int appendRow(
      xl.Sheet sheet,
      List<xl.CellValue> values, {
      xl.CellStyle? style,
      int? mergeToColumn,
    }) {
      final rowIndex = sheet.maxRows;
      sheet.appendRow(values);
      if (style != null) {
        for (var col = 0; col < values.length; col++) {
          final cell = sheet.cell(
            xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: rowIndex),
          );
          cell.cellStyle = style;
        }
      }
      if (mergeToColumn != null && mergeToColumn > 0) {
        sheet.merge(
          xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIndex),
          xl.CellIndex.indexByColumnRow(
            columnIndex: mergeToColumn,
            rowIndex: rowIndex,
          ),
        );
      }
      return rowIndex;
    }

    summarySheet.setColumnWidth(0, 24);
    summarySheet.setColumnWidth(1, 16);
    summarySheet.setColumnWidth(2, 10);
    summarySheet.setColumnWidth(3, 16);
    summarySheet.setColumnWidth(4, 16);
    summarySheet.setColumnWidth(5, 10);
    summarySheet.setColumnWidth(6, 12);

    appendRow(
      summarySheet,
      [xl.TextCellValue('Liquidaci\u00f3n Iglesia')],
      style: titleStyle,
      mergeToColumn: 6,
    );
    appendRow(summarySheet, [
      xl.TextCellValue('Periodo'),
      xl.TextCellValue(from),
      xl.TextCellValue('\u2192'),
      xl.TextCellValue(to),
    ], style: labelStyle);
    appendRow(summarySheet, [
      xl.TextCellValue('Moneda'),
      xl.TextCellValue(_exportCurrencyCode),
    ], style: labelStyle);
    appendRow(summarySheet, [
      xl.TextCellValue('Tasa ($rateLabel)'),
      xl.TextCellValue(rateStr),
    ], style: labelStyle);
    appendRow(summarySheet, [
      xl.TextCellValue('Porcentaje Pastoral'),
      xl.TextCellValue('${_percentage.toStringAsFixed(0)}%'),
    ], style: labelStyle);
    appendRow(summarySheet, [xl.TextCellValue('')]);

    appendRow(summarySheet, [
      xl.TextCellValue('Total Ingresos'),
      xl.TextCellValue(_fmtNumber(totalIncome)),
      xl.TextCellValue(_exportCurrencyCode),
    ], style: labelStyle);
    appendRow(summarySheet, [
      xl.TextCellValue('Pastor (${_percentage.toStringAsFixed(0)}%)'),
      xl.TextCellValue(_fmtNumber(pastoralShare)),
      xl.TextCellValue(_exportCurrencyCode),
    ], style: labelStyle);
    appendRow(summarySheet, [
      xl.TextCellValue('Iglesia'),
      xl.TextCellValue(_fmtNumber(churchRetains)),
      xl.TextCellValue(_exportCurrencyCode),
    ], style: labelStyle);
    appendRow(summarySheet, [xl.TextCellValue('')]);

    appendRow(
      summarySheet,
      [xl.TextCellValue('Desglose por Cuenta')],
      style: headerStyle,
      mergeToColumn: 6,
    );
    appendRow(summarySheet, [
      xl.TextCellValue('Cuenta'),
      xl.TextCellValue('Monto'),
      xl.TextCellValue('Moneda'),
      xl.TextCellValue('Participaci\u00f3n'),
      xl.TextCellValue('Part. Pastor'),
      xl.TextCellValue('Moneda'),
      xl.TextCellValue('Movimientos'),
    ], style: headerStyle);
    for (final e in breakdown) {
      appendRow(summarySheet, [
        xl.TextCellValue(e.accountName),
        xl.TextCellValue(_fmtNumber(e.totalIncome)),
        xl.TextCellValue(_exportCurrencyCode),
        xl.TextCellValue('${(e.proportion * 100).toStringAsFixed(1)}%'),
        xl.TextCellValue(_fmtNumber(e.shareAmount)),
        xl.TextCellValue(_exportCurrencyCode),
        xl.TextCellValue('${e.transactionCount}'),
      ]);
    }

    if (detailed) {
      final detailSheet = excel['Detalle'];
      detailSheet.setColumnWidth(0, 12);
      detailSheet.setColumnWidth(1, 20);
      detailSheet.setColumnWidth(2, 20);
      detailSheet.setColumnWidth(3, 14);
      detailSheet.setColumnWidth(4, 10);
      detailSheet.setColumnWidth(5, 30);

      appendRow(
        detailSheet,
        [xl.TextCellValue('Detalle de Transacciones')],
        style: titleStyle,
        mergeToColumn: 5,
      );
      appendRow(detailSheet, [
        xl.TextCellValue('Fecha'),
        xl.TextCellValue('Cuenta'),
        xl.TextCellValue('Categor\u00eda'),
        xl.TextCellValue('Monto'),
        xl.TextCellValue('Moneda'),
        xl.TextCellValue('Nota'),
      ], style: headerStyle);
      for (final tx in incomes) {
        final txDate = dateFmt.format(tx.date);
        final txAccount = tx.account.name;
        final txCategory = tx.category?.name ?? '';
        final txAmount = _fmtNumber(tx.currentValueInPreferredCurrency.abs());
        final txNote = tx.notes ?? '';
        appendRow(detailSheet, [
          xl.TextCellValue(txDate),
          xl.TextCellValue(txAccount),
          xl.TextCellValue(txCategory),
          xl.TextCellValue(txAmount),
          xl.TextCellValue(_exportCurrencyCode),
          xl.TextCellValue(txNote),
        ]);
      }
    }

    try {
      final dir = await getTemporaryDirectory();
      final type = detailed ? 'detallado' : 'resumen';

      final filenameFmt = DateFormat('dd-MM-yyyy');
      final fromFile = filenameFmt.format(_startDate);
      final toFile = filenameFmt.format(_endDate);

      final fileName = 'liquidacion_${type}_$fromFile\_$toFile.xlsx';
      final file = File('${dir.path}/$fileName');
      final bytes = excel.encode();
      if (bytes == null) {
        throw Exception('No se pudo generar el Excel');
      }
      await file.writeAsBytes(bytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject:
              'Liquidaci\u00f3n $from \u2192 $to '
              '($type)',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error al exportar: $e')));
      }
    }
  }

  Widget _buildHeroSplit({
    required String label,
    required double amount,
    required IconData icon,
    required AppColors colors,
  }) {
    return Column(
      children: [
        Icon(
          icon,
          size: 18,
          color: colors.onConsistentPrimary.withOpacity(0.7),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: colors.onConsistentPrimary.withOpacity(0.7),
            fontSize: 11,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 2),
        Text(
          _fmt(amount),
          style: TextStyle(
            color: colors.onConsistentPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  // ─── Empty State ──────────────────────────────────────

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.inbox_rounded,
              size: 64,
              color: theme.colorScheme.onSurface.withOpacity(0.2),
            ),
            const SizedBox(height: 16),
            Text(
              'Sin movimientos en este periodo',
              style: theme.textTheme.bodyLarge!.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.4),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Selecciona otro rango de fechas',
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Internal helper for breakdown data
class _BreakdownEntry {
  final String accountName;
  final double totalIncome;
  final double shareAmount;
  final int transactionCount;
  final double proportion;

  const _BreakdownEntry({
    required this.accountName,
    required this.totalIncome,
    required this.shareAmount,
    required this.transactionCount,
    required this.proportion,
  });
}

class _SubFundBalance {
  final Category category;
  final double initialAllocation;
  final double directIncome;
  final double totalExpenses;

  double get totalAvailable => initialAllocation + directIncome - totalExpenses;

  _SubFundBalance({
    required this.category,
    required this.initialAllocation,
    required this.directIncome,
    required this.totalExpenses,
  });
}

/// Rate type selection for the settlement report
enum _RateType { bcv, paralelo, manual }
