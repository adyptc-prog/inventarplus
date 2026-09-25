import 'package:flutter/material.dart';

import 'backup_service.dart';

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
        _setMessage('Folderul de backup a fost setat.');
      });

  Future<void> _create() => _run(() async {
        final b = await BackupService.createBackup();
        await _loadStatus();
        _setMessage('Backup creat: ${b.name}');
      });

  // Confirmare + alegerea partenerului de sincronizare; întoarce null la anulare.
  Future<bool?> _confirmRestore(String source) {
    var keepPartners = true;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: const Text('Restaurezi backup-ul?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Toate datele actuale din aplicație vor fi înlocuite cu cele '
                  'din $source.'),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: keepPartners,
                onChanged: (v) => setDs(() => keepPartners = v ?? true),
                title: const Text('Păstrează partenerul de sincronizare actual'),
                subtitle: const Text(
                  'Debifează doar dacă restaurezi pe același telefon de pe care '
                  'a fost făcut backup-ul.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Anulează'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, keepPartners),
              child: const Text('Restaurează'),
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
      _setMessage('Backup restaurat. Datele au fost reîncărcate.');
    });
  }

  Future<void> _restoreFromFolder() async {
    List<BackupEntry>? backups;
    await _run(() async => backups = await BackupService.listBackups());
    if (!mounted || backups == null) return; // eroarea e deja afișată
    if (backups!.isEmpty) {
      setState(() => _setMessage('Nu există backup-uri în folderul ales.'));
      return;
    }
    final chosen = await showDialog<BackupEntry>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Alege backup-ul'),
        children: [
          for (final b in backups!)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, b),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(b.auto ? Icons.schedule : Icons.save_outlined),
                title: Text(_formatDate(b.modifiedAt)),
                subtitle: Text(
                    '${b.auto ? 'Automat' : 'Manual'} · ${(b.size / 1024).toStringAsFixed(1)} KB'),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    await _restore(
      'backup-ul din ${_formatDate(chosen.modifiedAt)}',
      (keep) => BackupService.restoreBackup(chosen.id, keepSyncPartners: keep),
    );
  }

  Future<void> _restoreFromFile() => _restore(
        'fișierul pe care îl vei alege',
        (keep) => BackupService.pickAndRestoreBackup(keepSyncPartners: keep),
      );

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final folderOk = s.hasFolder && s.folderAccessible;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Backup & restaurare'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Destinație backup',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'usb', icon: Icon(Icons.usb), label: Text('Stick USB')),
              ButtonSegment(
                  value: 'phone',
                  icon: Icon(Icons.phone_android),
                  label: Text('Memoria telefonului')),
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
                  ? 'Niciun folder ales'
                  : folderOk
                      ? s.folderName!
                      : 'Folderul nu este accesibil'),
              subtitle: Text(!s.hasFolder
                  ? 'Alege destinația de mai sus.'
                  : folderOk
                      ? 'Backup automat zilnic, în jurul orei 00:00.'
                      : 'Conectează stick-ul sau alege din nou folderul.'),
              trailing: s.hasFolder
                  ? IconButton(
                      tooltip: 'Schimbă folderul',
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
                    ? 'Ultimul backup automat: ${_formatDate(s.lastAutoAt!)}'
                    : 'Niciun backup automat încă'),
                subtitle: s.lastAutoError != null
                    ? Text('Ultima încercare a eșuat: ${s.lastAutoError}',
                        style: TextStyle(color: Colors.red.shade700))
                    : s.lastManualAt != null
                        ? Text('Ultimul backup manual: ${_formatDate(s.lastManualAt!)}')
                        : null,
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.backup),
            label: const Text('Creează backup acum'),
            onPressed: _busy || !folderOk ? null : _create,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.restore),
            label: const Text('Restaurează din folderul de backup'),
            onPressed: _busy || !folderOk ? null : _restoreFromFolder,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Restaurează din alt fișier'),
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
                'Backup-ul conține toate produsele, setările și codul de '
                'instalare împreună cu licența — după restaurare pe un telefon '
                'nou, licența funcționează în continuare.\n\n'
                'Se păstrează ultimele 14 backup-uri automate; cele manuale '
                'nu se șterg niciodată automat.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
