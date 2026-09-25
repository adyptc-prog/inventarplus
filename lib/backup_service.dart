import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// Stare backup, așa cum o raportează partea nativă (BackupManager.status).
class BackupStatus {
  final String? folderName;
  final bool folderAccessible;
  final bool hasFolder;
  final String? destination; // 'usb' | 'phone'
  final DateTime? lastAutoAt;
  final String? lastAutoError;
  final DateTime? lastManualAt;

  const BackupStatus({
    this.folderName,
    this.folderAccessible = false,
    this.hasFolder = false,
    this.destination,
    this.lastAutoAt,
    this.lastAutoError,
    this.lastManualAt,
  });

  static DateTime? _date(Object? ms) =>
      ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;

  factory BackupStatus.fromMap(Map<Object?, Object?>? m) => BackupStatus(
        folderName: m?['folderName'] as String?,
        folderAccessible: (m?['folderAccessible'] as bool?) ?? false,
        hasFolder: m?['folderUri'] != null,
        destination: m?['destination'] as String?,
        lastAutoAt: _date(m?['lastAutoAt']),
        lastAutoError: m?['lastAutoError'] as String?,
        lastManualAt: _date(m?['lastManualAt']),
      );
}

class BackupEntry {
  final String id;
  final String name;
  final DateTime modifiedAt;
  final int size;
  final bool auto;

  const BackupEntry({
    required this.id,
    required this.name,
    required this.modifiedAt,
    required this.size,
    required this.auto,
  });

  factory BackupEntry.fromMap(Map<Object?, Object?> m) => BackupEntry(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        modifiedAt: DateTime.fromMillisecondsSinceEpoch((m['modifiedAt'] as int?) ?? 0),
        size: (m['size'] as int?) ?? 0,
        auto: (m['auto'] as bool?) ?? false,
      );
}

// Utilizatorul a închis selectorul fără să aleagă nimic.
class BackupCancelled implements Exception {
  const BackupCancelled();
}

// ─── Serviciu backup ──────────────────────────────────────────────────────────
// Backup-ul (manual + automat zilnic) și restaurarea sunt implementate nativ
// (BackupManager.kt), ca backup-ul automat să ruleze și cu aplicația închisă.
class BackupService {
  static const _ch = MethodChannel('inventarplus/backup');

  @visibleForTesting
  static bool? debugIsAndroid;
  static bool get isSupported => debugIsAndroid ?? Platform.isAndroid;

  static Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      if (e.code.endsWith('_CANCELLED')) throw const BackupCancelled();
      throw Exception(e.message ?? e.code);
    }
  }

  static Future<BackupStatus> getStatus() async {
    if (!isSupported) return const BackupStatus();
    return BackupStatus.fromMap(await _call<Map<Object?, Object?>>('getStatus'));
  }

  // destination: 'usb' sau 'phone' — un singur folder activ.
  static Future<BackupStatus> pickFolder(String destination) async =>
      BackupStatus.fromMap(await _call<Map<Object?, Object?>>(
          'pickFolder', {'destination': destination}));

  static Future<BackupEntry> createBackup() async =>
      BackupEntry.fromMap((await _call<Map<Object?, Object?>>('createBackup'))!);

  static Future<List<BackupEntry>> listBackups() async {
    final r = await _call<List<Object?>>('listBackups') ?? const [];
    return r.whereType<Map<Object?, Object?>>().map(BackupEntry.fromMap).toList();
  }

  static Future<void> restoreBackup(String id, {required bool keepSyncPartners}) =>
      _call<void>('restoreBackup', {'id': id, 'keepSyncPartners': keepSyncPartners});

  static Future<void> pickAndRestoreBackup({required bool keepSyncPartners}) =>
      _call<void>('pickAndRestoreBackup', {'keepSyncPartners': keepSyncPartners});
}
