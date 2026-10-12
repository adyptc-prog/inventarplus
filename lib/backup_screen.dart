import 'package:flutter/material.dart';

import 'backup_service.dart';
import 'l10n.dart';

// ─── Ecran backup & restaurare ────────────────────────────────────────────────
class BackupScreen extends StatefulWidget {
  // Apelat înainte de restaurare (oprește scrierile din fundal) și după
  // (reîncarcă toate datele din aplicație). onRestored primește true dacă
  // restaurarea a reușit.
  final Future<void> Function()? onBeforeRestore;
  final Future<void> Function(bool success)? onRestored;

  const BackupScreen({super.key, this.onBeforeRestore, this.onRestored});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  BackupStatus _status = const BackupStatus();
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _run(_loadStatus);
  }

  Future<void> _loadStatus() async {
    _status = await BackupService.getStatus();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on BackupCancelled {
      // selector închis — nimic de raportat
    } catch (e) {
      _setMessage(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setMessage(String text, {bool error = false}) {
    _message = text;
    _messageIsError = error;
  }

  static String _formatDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _pickFolder(String destination) => _run(() async {
        _status = await BackupService.pickFolder(destination);
        _setMessage(tr('Folderul de backup a fost setat.', 'The backup folder has been set.'));
      });

  Future<void> _create() => _run(() async {
        final b = await BackupService.createBackup();
        await _loadStatus();
        _setMessage(tr('Backup creat: ${b.name}', 'Backup created: ${b.name}'));
      });

  // Confirmare + alegerea partenerului de sincronizare; întoarce null la anulare.
  Future<bool?> _confirmRestore(String source) {
    var keepPartners = true;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Text(tr('Restaurezi backup-ul?', 'Restore the backup?')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Toate datele actuale din aplicație vor fi înlocuite cu cele '
                  'din $source.',
              'All current data in the app will be replaced with the data '
              'from $source.')),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: keepPartners,
                onChanged: (v) => setDs(() => keepPartners = v ?? true),
                title: Text(tr('Păstrează partenerul de sincronizare actual', 'Keep the current sync partner')),
                subtitle: Text(
                  tr('Debifează doar dacă restaurezi pe același telefon de pe care '
                  'a fost făcut backup-ul.',
                  'Untick only if you are restoring on the same phone '
                  'the backup was made on.'),
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Anulează', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, keepPartners),
              child: Text(tr('Restaurează', 'Restore')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restore(
      String source, Future<void> Function(bool keepPartners) restore) async {
    final keepPartners = await _confirmRestore(source);
    if (keepPartners == null || !mounted) return;
    await _run(() async {
      await widget.onBeforeRestore?.call();
      var ok = false;
      try {
        await restore(keepPartners);
        ok = true;
      } finally {
        await widget.onRestored?.call(ok);
      }
      await _loadStatus();
      _setMessage(tr('Backup restaurat. Datele au fost reîncărcate.', 'Backup restored. The data has been reloaded.'));
    });
  }

  Future<void> _restoreFromFolder() async {
    List<BackupEntry>? backups;
    await _run(() async => backups = await BackupService.listBackups());
    if (!mounted || backups == null) return; // eroarea e deja afișată
    if (backups!.isEmpty) {
      setState(() => _setMessage(tr('Nu există backup-uri în folderul ales.', 'There are no backups in the chosen folder.')));
      return;
    }
    final chosen = await showDialog<BackupEntry>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Alege backup-ul', 'Choose the backup')),
        children: [
          for (final b in backups!)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, b),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(b.auto ? Icons.schedule : Icons.save_outlined),
                title: Text(_formatDate(b.modifiedAt)),
                subtitle: Text(
                    tr('${b.auto ? 'Automat' : 'Manual'} · ${(b.size / 1024).toStringAsFixed(1)} KB', '${b.auto ? 'Automatic' : 'Manual'} · ${(b.size / 1024).toStringAsFixed(1)} KB')),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    await _restore(
      tr('backup-ul din ${_formatDate(chosen.modifiedAt)}', 'the backup from ${_formatDate(chosen.modifiedAt)}'),
      (keep) => BackupService.restoreBackup(chosen.id, keepSyncPartners: keep),
    );
  }

  Future<void> _restoreFromFile() => _restore(
        tr('fișierul pe care îl vei alege', 'the file you choose'),
        (keep) => BackupService.pickAndRestoreBackup(keepSyncPartners: keep),
      );

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final folderOk = s.hasFolder && s.folderAccessible;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Backup & restaurare', 'Backup & restore')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr('Destinație backup', 'Backup destination'),
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                  value: 'usb', icon: Icon(Icons.usb), label: Text(tr('Stick USB', 'USB stick'))),
              ButtonSegment(
                  value: 'phone',
                  icon: Icon(Icons.phone_android),
                  label: Text(tr('Memoria telefonului', 'Phone storage'))),
            ],
            emptySelectionAllowed: true,
            selected: {if (s.destination != null) s.destination!},
            onSelectionChanged: _busy
                ? null
                : (sel) => sel.isEmpty
                    ? _pickFolder(s.destination ?? 'phone')
                    : _pickFolder(sel.first),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(
                folderOk ? Icons.folder : Icons.folder_off_outlined,
                color: folderOk
                    ? Theme.of(context).colorScheme.primary
                    : Colors.orange.shade800,
              ),
              title: Text(!s.hasFolder
                  ? tr('Niciun folder ales', 'No folder chosen')
                  : folderOk
                      ? s.folderName!
                      : tr('Folderul nu este accesibil', 'The folder is not accessible')),
              subtitle: Text(!s.hasFolder
                  ? tr('Alege destinația de mai sus.', 'Choose the destination above.')
                  : folderOk
                      ? tr('Backup automat zilnic, în jurul orei 00:00.', 'Automatic daily backup, around 00:00.')
                      : tr('Conectează stick-ul sau alege din nou folderul.', 'Connect the stick or choose the folder again.')),
              trailing: s.hasFolder
                  ? IconButton(
                      tooltip: tr('Schimbă folderul', 'Change folder'),
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: _busy
                          ? null
                          : () => _pickFolder(s.destination ?? 'phone'),
                    )
                  : null,
            ),
          ),
          if (s.hasFolder)
            Card(
              child: ListTile(
                leading: Icon(
                  s.lastAutoError != null
                      ? Icons.error_outline
                      : Icons.schedule,
                  color: s.lastAutoError != null ? Colors.red.shade700 : null,
                ),
                title: Text(s.lastAutoAt != null
                    ? tr('Ultimul backup automat: ${_formatDate(s.lastAutoAt!)}', 'Last automatic backup: ${_formatDate(s.lastAutoAt!)}')
                    : tr('Niciun backup automat încă', 'No automatic backup yet')),
                subtitle: s.lastAutoError != null
                    ? Text(tr('Ultima încercare a eșuat: ${s.lastAutoError}', 'The last attempt failed: ${s.lastAutoError}'),
                        style: TextStyle(color: Colors.red.shade700))
                    : s.lastManualAt != null
                        ? Text(tr('Ultimul backup manual: ${_formatDate(s.lastManualAt!)}', 'Last manual backup: ${_formatDate(s.lastManualAt!)}'))
                        : null,
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.backup),
            label: Text(tr('Creează backup acum', 'Create backup now')),
            onPressed: _busy || !folderOk ? null : _create,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.restore),
            label: Text(tr('Restaurează din folderul de backup', 'Restore from the backup folder')),
            onPressed: _busy || !folderOk ? null : _restoreFromFolder,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.file_open_outlined),
            label: Text(tr('Restaurează din alt fișier', 'Restore from another file')),
            onPressed: _busy ? null : _restoreFromFile,
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_message != null) ...[
            const SizedBox(height: 16),
            Card(
              color: _messageIsError ? Colors.red.shade50 : Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _messageIsError
                          ? Colors.red.shade800
                          : Colors.green.shade800),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Card(
            color: const Color(0xFFEEF2FF),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                tr('Backup-ul conține toate produsele, setările și codul de '
                'instalare împreună cu licența — după restaurare pe un telefon '
                'nou, licența funcționează în continuare.\n\n'
                'Se păstrează ultimele 14 backup-uri automate; cele manuale '
                'nu se șterg niciodată automat.',
                'The backup contains all products, settings and the installation '
                'code together with the license — after restoring on a new '
                'phone, the license keeps working.\n\n'
                'The last 14 automatic backups are kept; manual ones '
                'are never deleted automatically.'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
