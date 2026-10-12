import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
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
          _snack(tr('Licență activată cu succes!', 'License activated successfully!'), color: Colors.green.shade700);
          await widget.onShareWithPartners?.call();
        } else {
          _snack(r.message, color: Colors.red.shade700);
        }
      });

  Future<void> _share() => _run(() async {
        final sent = await widget.onShareWithPartners!.call();
        if (!mounted || sent < 0) return;
        _snack(sent == 0
            ? tr('Niciun telefon partener configurat pentru sincronizare.', 'No partner phone is set up for sync.')
            : tr('Licența a fost trimisă prin SMS la $sent '
                '${sent == 1 ? 'telefon' : 'telefoane'}.',
            'The license was sent by SMS to $sent '
            '${sent == 1 ? 'phone' : 'phones'}.'));
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
          title: tr('Licență pe viață activă', 'Lifetime license active'),
          subtitle: tr('Nu expiră.', 'It does not expire.'),
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
            ? tr('Licența expiră în curând', 'The license expires soon')
            : tr('Licență activă', 'License active'),
        subtitle: [
          if (until != null) tr('Valabilă până la ${_formatDate(until)}', 'Valid until ${_formatDate(until)}'),
          if (days != null) tr('$days zile rămase', '$days ${days == 1 ? 'day' : 'days'} left'),
        ].join(' · '),
      );
    }
    if (LicenseService.isLegacyLicensed) {
      return (
        icon: Icons.verified_user,
        color: Colors.green.shade700,
        title: tr('Licență activă (cod .invtoken)', 'License active (.invtoken code)'),
        subtitle: tr('Activată cu un cod Volt Academy.', 'Activated with a Volt Academy code.'),
      );
    }
    final invalidNote = LicenseService.newLicenseStatus == 'invalid' &&
            LicenseService.newLicenseMessage.isNotEmpty
        ? tr('\nLicență respinsă: ${LicenseService.newLicenseMessage}', '\nLicense rejected: ${LicenseService.newLicenseMessage}')
        : '';
    if (LicenseService.isTrialActive) {
      return (
        icon: Icons.lock_open_outlined,
        color: Colors.orange.shade800,
        title: tr('Perioadă de trial', 'Trial period'),
        subtitle: tr('${LicenseService.trialDaysLeft} zile rămase$invalidNote', '${LicenseService.trialDaysLeft} days left$invalidNote'),
      );
    }
    return (
      icon: Icons.lock_outline,
      color: Colors.red.shade700,
      title: tr('Fără licență', 'No license'),
      subtitle: tr('Perioada de trial a expirat.$invalidNote', 'The trial period has expired.$invalidNote'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status();
    final canShare = widget.onShareWithPartners != null &&
        LicenseService.isNewLicenseActive;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Licență', 'License')),
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
              title: Text(tr('Cod de instalare', 'Installation code')),
              subtitle: SelectableText(
                _businessId,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                tooltip: tr('Copiază codul', 'Copy code'),
                onPressed: _businessId.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                            ClipboardData(text: _businessId));
                        if (mounted) _snack(tr('Cod copiat.', 'Code copied.'));
                      },
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.folder_open),
            label: Text(tr('Selectează fișierul de licență', 'Select the license file')),
            onPressed: _busy ? null : _pick,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh),
            label: Text(tr('Reverifică licența', 'Check the license again')),
            onPressed: _busy ? null : _refresh,
          ),
          if (canShare) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.send_to_mobile),
              label: Text(tr('Trimite licența la telefonul partener', 'Send the license to the partner phone')),
              onPressed: _busy ? null : _share,
            ),
          ],
          const SizedBox(height: 16),
          Card(
            color: const Color(0xFFEEF2FF),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                tr('Cumpără o licență pe voltacademy.app/inventarplus.html folosind '
                'codul de instalare de mai sus, apoi selectează fișierul '
                'descărcat.\n\n'
                'Licența e valabilă pe două telefoane: configurează '
                'sincronizarea între ele și licența se transferă automat '
                'prin SMS pe al doilea telefon.',
                'Buy a license at voltacademy.app/inventarplus.html using '
                'the installation code above, then select the downloaded '
                'file.\n\n'
                'The license is valid on two phones: set up '
                'sync between them and the license is transferred automatically '
                'by SMS to the second phone.'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
