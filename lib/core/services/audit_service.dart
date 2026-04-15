import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:monekin/core/database/app_db.dart';
import 'package:monekin/core/services/firebase_sync_service.dart';
import 'package:monekin/core/utils/logger.dart';
import 'package:uuid/uuid.dart';

/// Service to handle the Audit Trail (Immutable Log)
///
/// Records every CREATE, UPDATE, DELETE action on critical entities (Transactions).
/// Logs are saved locally in [AppDB] and synced to Firestore.
class AuditService {
  AuditService._();
  static final AuditService instance = AuditService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Log a change to a Transaction.
  ///
  /// Must be called within a Drift transaction block to ensure atomicity.
  ///
  /// [db] - The database instance (or transaction executor)
  /// [action] - 'CREATE', 'UPDATE', 'DELETE'
  /// [oldTx] - The transaction object before the change (null for CREATE)
  /// [newTx] - The transaction object after the change (null for DELETE)
  Future<void> logTransactionAction(
    DatabaseConnectionUser db,
    String action,
    TransactionInDB? oldTx,
    TransactionInDB? newTx,
  ) async {
    try {
      final user = FirebaseSyncService.instance.currentUserId;
      final email = FirebaseSyncService.instance.currentUserEmail;

      // If we don't have a user (e.g. initial seed or automated task), we might skip or log as 'system'
      // But for church finance, usually there is always a logged in user.

      final auditId = const Uuid().v4();
      final entityId = newTx?.id ?? oldTx?.id ?? 'unknown';

      final logEntry = AuditLog(
        id: auditId,
        action: action,
        entityType: 'transaction:$action',
        entityId: entityId,
        previousValue: oldTx != null ? _safeEncode(oldTx.toJson()) : null,
        newValue: newTx != null ? _safeEncode(newTx.toJson()) : null,
        userId: user,
        userEmail: email,
        timestamp: DateTime.now(),
      );

      // 1. Save to Local DB (within the active transaction)
      await db.into(AppDB.instance.auditLogs).insert(logEntry);

      Logger.printDebug(
        'AuditService: Logged $action for Transaction $entityId',
      );

      // 2. Schedule Sync (Fire and forget, or handle by a separate sync worker)
      // We do this AFTER the local db insert to not block the UI if offline.
      unawaited(_syncToFirestore(logEntry));
    } catch (e, s) {
      Logger.printDebug('AuditService: CRITICAL ERROR logging action: $e\n$s');
      // Rethrow to abort the enclosing Drift transaction and rollback the data change.
      // This guarantees: No audit log = No transaction saved.
      rethrow;
    }
  }

  /// Sync a single log entry to Firestore (Best effort)
  Future<void> _syncToFirestore(AuditLog log) async {
    try {
      if (FirebaseSyncService.instance.currentUserId == null) return;

      final docRef = _firestore
          .collection('organizations')
          .doc(FirebaseSyncService.orgId)
          .collection('audit_logs')
          .doc(log.id);

      // entityType stores 'entity:ACTION', e.g. 'transaction:CREATE'
      final parts = log.entityType.split(':');
      final entityBase = parts.first;
      final actionStr = parts.length > 1 ? parts.last : 'UNKNOWN';

      await docRef.set({
        'id': log.id,
        'action': actionStr,
        'entityType': entityBase,
        'entityId': log.entityId,
        'previousValue': log.previousValue,
        'newValue': log.newValue,
        'userId': log.userId,
        'userEmail': log.userEmail,
        'timestamp': log.timestamp.toIso8601String(),
        'deviceTimestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      Logger.printDebug(
        'AuditService: Failed to sync log ${log.id} to Firestore: $e',
      );
      // TODO: Implement a queue for retry later if offline
    }
  }

  /// Get logs for a specific entity
  Stream<List<AuditLog>> getLogsForEntity(String entityId) {
    return (AppDB.instance.select(AppDB.instance.auditLogs)
          ..where((tbl) => tbl.entityId.equals(entityId))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.timestamp, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// Safely encode a Drift-generated toJson() map.
  ///
  /// Drift's [toJson] emits raw enum values (e.g.
  /// [TransactionType]) that [jsonEncode] can't handle.
  /// This helper converts them to their [.name] string.
  static String _safeEncode(Map<String, dynamic> map) {
    return jsonEncode(
      map,
      toEncodable: (obj) {
        if (obj is Enum) return obj.name;
        if (obj is DateTime) return obj.toIso8601String();
        return obj.toString();
      },
    );
  }
}
