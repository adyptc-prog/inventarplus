import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'license_service.dart';

// ─── Ecran licență ────────────────────────────────────────────────────────────
// Status, cod de instalare, import fișier și transmiterea licenței către
// telefonul partener (licența cumpărată acoperă ambele telefoane sincronizate).
class LicenseScreen extends StatefulWidget {
  // Trimite licența partenerilor de sincronizare; întoarce câte telefoane,
  // sau un număr negativ dacă trimiterea a fost oprită (ex. SMS blocat) și
  // utilizatorul a fost deja informat.
  final Future<int> Function()? onShareWithPartners;

  const LicenseScreen({super.key, this.onShareWithPartners});

  @override
  State<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends State<LicenseScreen> {
  String _businessId = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() => _run(() async {
        await LicenseService.checkNewLicense();
        _businessId = await LicenseService.getBusinessId();
      });

  void _snack(String text, {Color? color}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: color),
    );
  }

  Future<void> _pick() => _run(() async {
        final r = await LicenseService.pickLicenseFile();
        if (!mounted) return;
        if (!r.success && r.message.isEmpty) return; // selector anulat
        if (r.success) {
          _snack('Licență activată cu succes!', color: Colors.green.shade700);
          await widget.onShareWithPartners?.call();
        } else {
          _snack(r.message, color: Colors.red.shade700);
        }
      });

  Future<void> _share() => _run(() async {
        final sent = await widget.onShareWithPartners!.call();
        if (!mounted || sent < 0) return;
        _snack(sent == 0
            ? 'Niciun telefon partener configurat pentru sincronizare.'
            : 'Licența a fost trimisă prin SMS la $sent '
                '${sent == 1 ? 'telefon' : 'telefoane'}.');
      });

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  ({IconData icon, Color color, String title, String subtitle}) _status() {
    if (LicenseService.isNewLicenseActive) {
      final until = LicenseService.validUntilLocal;
      final days = LicenseService.newLicenseDaysUntilExpiry;
      if (LicenseService.newLicenseIsLifetime) {
        return (
          icon: Icons.verified_user,
          color: Colors.green.shade700,
          title: 'Licență pe viață activă',
          subtitle: 'Nu expiră.',
        );
      }
      return (
        icon: LicenseService.isExpiringSoon
            ? Icons.warning_amber_rounded
            : Icons.verified_user,
        color: LicenseService.isExpiringSoon
            ? Colors.orange.shade800
            : Colors.green.shade700,
        title: LicenseService.isExpiringSoon
            ? 'Licența expiră în curând'
            : 'Licență activă',
        subtitle: [
          if (until != null) 'Valabilă până la ${_formatDate(until)}',
          if (days != null) '$days zile rămase',
        ].join(' · '),
      );
    }
    if (LicenseService.isLegacyLicensed) {
      return (
        icon: Icons.verified_user,
        color: Colors.green.shade700,
        title: 'Licență activă (cod .invtoken)',
        subtitle: 'Activată cu un cod Volt Academy.',
      );
    }
    final invalidNote = LicenseService.newLicenseStatus == 'invalid' &&
            LicenseService.newLicenseMessage.isNotEmpty
        ? '\nLicență respinsă: ${LicenseService.newLicenseMessage}'
        : '';
    if (LicenseService.isTrialActive) {
      return (
        icon: Icons.lock_open_outlined,
        color: Colors.orange.shade800,
        title: 'Perioadă de trial',
        subtitle: '${LicenseService.trialDaysLeft} zile rămase$invalidNote',
      );
    }
    return (
      icon: Icons.lock_outline,
      color: Colors.red.shade700,
      title: 'Fără licență',
      subtitle: 'Perioada de trial a expirat.$invalidNote',
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status();
    final canShare = widget.onShareWithPartners != null &&
        LicenseService.isNewLicenseActive;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Licență'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(status.icon, color: status.color, size: 32),
              title: Text(status.title,
                  style: TextStyle(
                      color: status.color, fontWeight: FontWeight.w600)),
              subtitle: Text(status.subtitle),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.qr_code_2),
              title: const Text('Cod de instalare'),
              subtitle: SelectableText(
                _businessId,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copiază codul',
                onPressed: _businessId.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                            ClipboardData(text: _businessId));
                        if (mounted) _snack('Cod copiat.');
                      },
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.folder_open),
            label: const Text('Selectează fișierul de licență'),
            onPressed: _busy ? null : _pick,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Reverifică licența'),
            onPressed: _busy ? null : _refresh,
          ),
          if (canShare) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.send_to_mobile),
              label: const Text('Trimite licența la telefonul partener'),
              onPressed: _busy ? null : _share,
            ),
          ],
          const SizedBox(height: 16),
          Card(
            color: const Color(0xFFEEF2FF),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Cumpără o licență pe voltacademy.app/inventarplus.html folosind '
                'codul de instalare de mai sus, apoi selectează fișierul '
                'descărcat.\n\n'
                'Licența e valabilă pe două telefoane: configurează '
                'sincronizarea între ele și licența se transferă automat '
                'prin SMS pe al doilea telefon.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
