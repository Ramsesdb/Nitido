import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nitido/core/services/statement_import/image_pivot.dart';
import 'package:nitido/i18n/generated/translations.g.dart';

class _PendingPivot {
  final int index;
  final ImagePivot pivot;
  DateTime? picked;

  _PendingPivot({required this.index, required this.pivot, this.picked});
}

Future<List<ImagePivot>?> promptMissingPivots(
  BuildContext context,
  List<ImagePivot> images,
) async {
  final missingIndices = <int>[];
  for (var i = 0; i < images.length; i++) {
    if (images[i].exifDate == null) missingIndices.add(i);
  }
  if (missingIndices.isEmpty) return List<ImagePivot>.from(images);

  final pending = [
    for (final i in missingIndices)
      _PendingPivot(index: i, pivot: images[i], picked: null),
  ];

  final result = await showModalBottomSheet<List<_PendingPivot>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _MissingPivotSheet(pending: pending),
  );

  if (result == null) return null;

  final today = DateTime.now();
  final next = List<ImagePivot>.from(images);
  for (final p in result) {
    final picked = p.picked ?? today;
    next[p.index] = p.pivot.copyWith(resolvedPivot: picked);
  }
  return next;
}

class _MissingPivotSheet extends StatefulWidget {
  const _MissingPivotSheet({required this.pending});

  final List<_PendingPivot> pending;

  @override
  State<_MissingPivotSheet> createState() => _MissingPivotSheetState();
}

class _MissingPivotSheetState extends State<_MissingPivotSheet> {
  late final List<_PendingPivot> _items;

  @override
  void initState() {
    super.initState();
    _items = [
      for (final p in widget.pending)
        _PendingPivot(index: p.index, pivot: p.pivot, picked: p.picked),
    ];
  }

  Future<void> _pickFor(_PendingPivot p) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: p.picked ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked != null) {
      setState(() => p.picked = picked);
    }
  }

  void _allToday() {
    final today = DateTime.now();
    setState(() {
      for (final p in _items) {
        p.picked = today;
      }
    });
  }

  bool get _allResolved => _items.every((p) => p.picked != null);

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.statement_import.capture.missing_pivot_title,
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              t.statement_import.capture.missing_pivot_body,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _allToday,
                icon: const Icon(Icons.event_available_outlined, size: 18),
                label: Text(t.statement_import.capture.missing_pivot_all_today),
              ),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (ctx, idx) {
                  final p = _items[idx];
                  return _PivotRow(
                    pending: p,
                    onTap: () => _pickFor(p),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _allResolved
                  ? () => Navigator.of(context).pop(_items)
                  : null,
              child: Text(t.statement_import.capture.missing_pivot_continue),
            ),
          ],
        ),
      ),
    );
  }
}

class _PivotRow extends StatelessWidget {
  const _PivotRow({required this.pending, required this.onTap});

  final _PendingPivot pending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final t = Translations.of(context);

    final picked = pending.picked;
    final label = picked == null
        ? t.statement_import.capture.missing_pivot_select
        : '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _Thumb(base64: pending.pivot.base64),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.statement_import.capture.missing_pivot_image_label(
                      n: pending.index + 1,
                    ),
                    style: tt.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: tt.bodySmall?.copyWith(
                      color: picked == null
                          ? cs.error
                          : cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.calendar_month_outlined,
              size: 20,
              color: cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.base64});

  final String base64;

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      bytes = base64Decode(base64);
    } catch (_) {
      bytes = null;
    }
    if (bytes == null) {
      return Container(
        width: 56,
        height: 56,
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: const Icon(Icons.image_not_supported_outlined, size: 18),
      );
    }
    return Image.memory(
      bytes,
      width: 56,
      height: 56,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        width: 56,
        height: 56,
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: const Icon(Icons.image_not_supported_outlined, size: 18),
      ),
    );
  }
}
