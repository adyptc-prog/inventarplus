import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Constante ───────────────────────────────────────────────────────────────
const _kItemsKey         = 'inventar_products';
const _kNextNumberKey    = 'inventar_next_number';
const _kSmsTemplateKey   = 'sms_template';
const _kDeletedBufferKey = 'inventar_deleted_buffer';
const _kSyncPartnerKey   = 'sync_partner_phone';

const _kDefaultSmsTemplate =
    'Alertă stoc: [DENUMIRE]. Stoc actual: [STOC] (minim: [STOC_MINIM]).';

// ─── Helper: ID unic stabil pentru sincronizare ───────────────────────────────
String _generateSyncId() {
  final r = Random.secure();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(16, (_) => chars[r.nextInt(chars.length)]).join();
}

// Format ISO scurt (fără secunde) pentru SMS/sincronizare compactă
String _isoShort(DateTime dt) =>
    '${dt.year}-'
    '${dt.month.toString().padLeft(2, '0')}-'
    '${dt.day.toString().padLeft(2, '0')}T'
    '${dt.hour.toString().padLeft(2, '0')}:'
    '${dt.minute.toString().padLeft(2, '0')}';

// ─── Nivel de alertă stoc ──────────────────────────────────────────────────────
// 0 = normal, 1 = sub prag alertă (galben), 2 = sub stoc minim (roșu)
int alertLevelFor(Product p) {
  if (p.stocActual <= p.stocMinim) return 2;
  if (p.pragAlerta > p.stocMinim && p.stocActual <= p.pragAlerta) return 1;
  return 0;
}

// ─── Serviciu alerte (notificare push imediată + SMS imediat) ────────────────
// Spre deosebire de Organizator, alertele nu mai sunt programate la o oră
// fixă (fără AlarmManager) — se declanșează instant, o singură dată, în
// momentul în care o mișcare de stoc face produsul să treacă la un nivel
// de alertă mai grav (edge-triggered).
class AlertService {
  static const _ch = MethodChannel('inventarplus/sms');
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(settings: settings);
  }

  static Future<void> requestPermissions() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {}
  }

  // ID stabil per produs (bazat pe syncId, nu pe number — number se
  // renumerotează la ștergere/sincronizare și ar coliza cu alte produse,
  // suprascriind în tray o alertă critică încă nerezolvată).
  static int _notificationId(Product p) => p.syncId.hashCode & 0x7FFFFFFF;

  static Future<void> notify(Product p, int level, String template) async {
    if (level == 0) return;

    final title = level == 2
        ? '🔴 Stoc sub minim: ${p.denumire}'
        : '⚠️ Stoc sub prag alertă: ${p.denumire}';
    final body = 'Stoc actual: ${p.stocActual}  ·  Minim: ${p.stocMinim}';

    try {
      await _plugin.show(
        id: _notificationId(p),
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'stock_alerts',
            'Alerte stoc',
            channelDescription: 'Notificări la atingerea pragurilor de stoc',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}

    final phones = p.phones;
    if (phones.isEmpty) return;
    final prefix = level == 2 ? 'STOC EPUIZAT: ' : 'ALERTĂ STOC: ';
    final msg = prefix + _buildSmsText(p, template);
    for (final phone in phones) {
      try {
        await _ch.invokeMethod<void>(
            'sendSms', {'phone': phone, 'message': msg});
      } catch (_) {}
    }
  }

  static String _buildSmsText(Product p, String template) => template
      .replaceAll('[DENUMIRE]', p.denumire)
      .replaceAll('[STOC]', p.stocActual.toString())
      .replaceAll('[STOC_MINIM]', p.stocMinim.toString())
      .replaceAll('[PRAG_ALERTA]', p.pragAlerta.toString());
}

// ─── Serviciu SMS/cameră: cerere permisiuni ───────────────────────────────────
class SmsService {
  static const _ch = MethodChannel('inventarplus/sms');

  static Future<void> requestPermission() async {
    try { await Permission.sms.request(); } catch (_) {}
    if (Platform.isAndroid) {
      try { await _ch.invokeMethod<void>('requestReceiveSms'); } catch (_) {}
    }
  }
}

// ─── Serviciu sincronizare bidirecțională prin SMS ────────────────────────────
//
// Protocol:
//   INV:A:{json}  — produs adăugat
//   INV:U:{json}  — produs actualizat
//   INV:D:{syncId} — produs șters
//   INV:I:{json}  — produs din sincronizare inițială (bulk)
//   INV:Z:        — sfârșitul sincronizării inițiale
//
// Câmpuri JSON compact: s=syncId, n=denumire, d=descriere, b=codBare,
//   q=stocActual, m=stocMinim, a=pragAlerta, c=createdAt, l=lastAlertLevel,
//   p1/p2/p3=phoneNumbers
class SyncService {
  static const _ch = MethodChannel('inventarplus/sms');
  static String? _partnerPhone;

  static bool get isSupported => Platform.isAndroid;
  static bool get isActive =>
      _partnerPhone != null && _partnerPhone!.isNotEmpty;
  static String? get partnerPhone => _partnerPhone;

  static Future<void> load() async {
    if (!isSupported) return;
    final prefs = await SharedPreferences.getInstance();
    _partnerPhone = prefs.getString(_kSyncPartnerKey);
  }

  static Future<void> setPartner(String phone) async {
    _partnerPhone = phone.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSyncPartnerKey, _partnerPhone!);
  }

  static Future<void> clearPartner() async {
    _partnerPhone = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSyncPartnerKey);
  }

  static Future<void> _send(String msg) async {
    if (!isActive || !isSupported) return;
    try {
      await _ch.invokeMethod<void>('sendSms', {
        'phone': _partnerPhone,
        'message': msg,
      });
    } catch (_) {}
  }

  static Future<void> sendInitialSync(List<Product> items) async {
    for (final item in items) {
      await _send('INV:I:${jsonEncode(item.toSyncJson())}');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    await _send('INV:Z:');
  }

  static Future<void> sendAdd(Product item) =>
      _send('INV:A:${jsonEncode(item.toSyncJson())}');

  static Future<void> sendUpdate(Product item) =>
      _send('INV:U:${jsonEncode(item.toSyncJson())}');

  static Future<void> sendDelete(String syncId) =>
      _send('INV:D:$syncId');

  static Future<List<String>> getPendingMessages() async {
    if (!isSupported) return [];
    try {
      final raw = await _ch.invokeMethod<String>('getSyncMessages') ?? '[]';
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.cast<String>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> clearQueue() async {
    if (!isSupported) return;
    try {
      await _ch.invokeMethod<void>('clearSyncQueue');
    } catch (_) {}
  }
}

// ─── Serviciu licențiere ──────────────────────────────────────────────────────
class LicenseService {
  static const _ch              = MethodChannel('inventarplus/license');
  static const _kTrialStartKey  = 'trial_start_date';
  static const _trialDays       = 30;

  static bool      _licensed   = false;
  static DateTime? _trialStart;

  // Fluxul nou: licență cu businessId + expirare, cumpărată de pe site
  // (identic ca format cu Fidelio). Rulează alături de vechiul flux .invtoken,
  // fără să-l înlocuiască — orice cod vechi deja emis rămâne valabil.
  static String  newLicenseStatus = 'missing';
  static String  newLicenseMessage = '';
  static String? newLicenseValidUntil;
  static int?    newLicenseDaysUntilExpiry;
  static bool    newLicenseIsLifetime = false;

  static bool get isLicensed => _licensed;

  static bool get isTrialActive {
    if (_trialStart == null) return false;
    return DateTime.now().isBefore(_trialStart!.add(const Duration(days: _trialDays)));
  }

  static int get trialDaysLeft {
    if (_trialStart == null) return 0;
    final expiry = _trialStart!.add(const Duration(days: _trialDays));
    final left   = expiry.difference(DateTime.now()).inDays;
    return left < 0 ? 0 : left;
  }

  // Non-Android: nelimitat
  static bool get canAdd => !Platform.isAndroid || _licensed || isTrialActive;

  static Future<void> load() async {
    if (!Platform.isAndroid) { _licensed = true; return; }
    try {
      _licensed = await _ch.invokeMethod<bool>('isLicensed') ?? false;
    } catch (_) {}
    await checkNewLicense();
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kTrialStartKey);
    if (saved == null) {
      _trialStart = DateTime.now();
      await prefs.setString(_kTrialStartKey, _trialStart!.toIso8601String());
    } else {
      _trialStart = DateTime.tryParse(saved);
    }
  }

  static Future<String?> getPendingToken() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<String?>('getPendingToken');
    } catch (_) {
      return null;
    }
  }

  // Copia fișierului .invtoken folosit la activare, dacă există (vezi
  // MainActivity.verifyAndActivate). Permite utilizatorului să-și retrimită
  // singur licența dacă schimbă telefonul, fără să mai contacteze suportul.
  static Future<String?> getBackupToken() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<String?>('getLicenseBackup');
    } catch (_) {
      return null;
    }
  }

  static Future<void> checkNewLicense() async {
    if (!Platform.isAndroid) return;
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('checkLicense');
      newLicenseStatus = (r?['status'] as String?) ?? 'missing';
      newLicenseMessage = (r?['message'] as String?) ?? '';
      newLicenseValidUntil = r?['validUntil'] as String?;
      newLicenseDaysUntilExpiry = r?['daysUntilExpiry'] as int?;
      newLicenseIsLifetime = (r?['isLifetime'] as bool?) ?? false;
      if (newLicenseStatus == 'active') {
        _licensed = true;
      }
    } catch (_) {}
  }

  static Future<String> getBusinessId() async {
    if (!Platform.isAndroid) return '';
    try {
      return await _ch.invokeMethod<String>('getBusinessId') ?? '';
    } catch (_) {
      return '';
    }
  }

  // Deschide selectorul nativ de fișiere, reverifică licența, și întoarce
  // true dacă fișierul ales e o licență validă și activă.
  static Future<bool> pickLicenseFile() async {
    if (!Platform.isAndroid) return false;
    try {
      await _ch.invokeMethod('pickLicenseFile');
      await checkNewLicense();
      return newLicenseStatus == 'active';
    } catch (_) {
      return false;
    }
  }

  static Future<({bool success, String message})> activate(String token) async {
    if (!Platform.isAndroid) {
      return (success: false, message: 'Nu este suportat pe această platformă.');
    }
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('verifyAndActivate',
          {'token': token});
      final success = (r?['success'] as bool?) ?? false;
      final msg     = (r?['msg']     as String?) ?? '';
      if (success) _licensed = true;
      return (success: success, message: msg);
    } catch (e) {
      return (success: false, message: e.toString());
    }
  }
}

// ─── Model ────────────────────────────────────────────────────────────────────
class Product {
  final String syncId;
  final int number;
  final String denumire;
  final String descriere;
  final String codBare;
  final int stocActual;
  final int stocMinim;
  final int pragAlerta;
  final DateTime createdAt;
  final int lastAlertLevel;
  final String? phoneNumber;
  final String? phoneNumber2;
  final String? phoneNumber3;

  const Product({
    required this.syncId,
    required this.number,
    required this.denumire,
    required this.descriere,
    required this.codBare,
    required this.stocActual,
    required this.stocMinim,
    required this.pragAlerta,
    required this.createdAt,
    this.lastAlertLevel = 0,
    this.phoneNumber,
    this.phoneNumber2,
    this.phoneNumber3,
  });

  List<String> get phones => [
        if (phoneNumber  != null && phoneNumber!.isNotEmpty)  phoneNumber!,
        if (phoneNumber2 != null && phoneNumber2!.isNotEmpty) phoneNumber2!,
        if (phoneNumber3 != null && phoneNumber3!.isNotEmpty) phoneNumber3!,
      ];

  Product copyWith({
    String? syncId,
    int? number,
    String? denumire,
    String? descriere,
    String? codBare,
    int? stocActual,
    int? stocMinim,
    int? pragAlerta,
    DateTime? createdAt,
    int? lastAlertLevel,
    String? phoneNumber,
    bool clearPhone = false,
    String? phoneNumber2,
    bool clearPhone2 = false,
    String? phoneNumber3,
    bool clearPhone3 = false,
  }) {
    return Product(
      syncId:         syncId         ?? this.syncId,
      number:         number         ?? this.number,
      denumire:       denumire       ?? this.denumire,
      descriere:      descriere      ?? this.descriere,
      codBare:        codBare        ?? this.codBare,
      stocActual:     stocActual     ?? this.stocActual,
      stocMinim:      stocMinim      ?? this.stocMinim,
      pragAlerta:     pragAlerta     ?? this.pragAlerta,
      createdAt:      createdAt      ?? this.createdAt,
      lastAlertLevel: lastAlertLevel ?? this.lastAlertLevel,
      phoneNumber:    clearPhone     ? null : (phoneNumber  ?? this.phoneNumber),
      phoneNumber2:   clearPhone2    ? null : (phoneNumber2 ?? this.phoneNumber2),
      phoneNumber3:   clearPhone3    ? null : (phoneNumber3 ?? this.phoneNumber3),
    );
  }

  Map<String, dynamic> toJson() => {
        'syncId':         syncId,
        'number':         number,
        'denumire':       denumire,
        'descriere':      descriere,
        'codBare':        codBare,
        'stocActual':     stocActual,
        'stocMinim':      stocMinim,
        'pragAlerta':     pragAlerta,
        'createdAt':      createdAt.toIso8601String(),
        'lastAlertLevel': lastAlertLevel,
        'phoneNumber':    phoneNumber,
        'phoneNumber2':   phoneNumber2,
        'phoneNumber3':   phoneNumber3,
      };

  factory Product.fromJson(Map<String, dynamic> json) => Product(
        syncId:         (json['syncId'] as String?) ?? _generateSyncId(),
        number:         json['number']      as int,
        denumire:       json['denumire']    as String,
        descriere:      json['descriere']   as String,
        codBare:        (json['codBare'] as String?) ?? '',
        stocActual:     json['stocActual']  as int,
        stocMinim:      json['stocMinim']   as int,
        pragAlerta:     json['pragAlerta']  as int,
        createdAt:      DateTime.parse(json['createdAt'] as String),
        lastAlertLevel: (json['lastAlertLevel'] as int?) ?? 0,
        phoneNumber:    json['phoneNumber']  as String?,
        phoneNumber2:   json['phoneNumber2'] as String?,
        phoneNumber3:   json['phoneNumber3'] as String?,
      );

  Map<String, dynamic> toSyncJson() => {
        's': syncId,
        'n': denumire,
        if (descriere.isNotEmpty) 'd': descriere,
        if (codBare.isNotEmpty)   'b': codBare,
        'q': stocActual,
        'm': stocMinim,
        'a': pragAlerta,
        'c': _isoShort(createdAt),
        'l': lastAlertLevel,
        if (phoneNumber  != null && phoneNumber!.isNotEmpty)  'p1': phoneNumber,
        if (phoneNumber2 != null && phoneNumber2!.isNotEmpty) 'p2': phoneNumber2,
        if (phoneNumber3 != null && phoneNumber3!.isNotEmpty) 'p3': phoneNumber3,
      };

  factory Product.fromSyncJson(Map<String, dynamic> j) => Product(
        syncId:         j['s'] as String,
        number:         0, // numărul local se asignează la merge
        denumire:       j['n'] as String,
        descriere:      (j['d'] as String?) ?? '',
        codBare:        (j['b'] as String?) ?? '',
        stocActual:     (j['q'] as int?) ?? 0,
        stocMinim:      (j['m'] as int?) ?? 0,
        pragAlerta:     (j['a'] as int?) ?? 0,
        createdAt:      DateTime.parse(j['c'] as String),
        lastAlertLevel: (j['l'] as int?) ?? 0,
        phoneNumber:    j['p1'] as String?,
        phoneNumber2:   j['p2'] as String?,
        phoneNumber3:   j['p3'] as String?,
      );
}

// ─── Buffer produse șterse (6 luni) ───────────────────────────────────────────
class DeletedProduct {
  final Product item;
  final DateTime deletedAt;

  const DeletedProduct({required this.item, required this.deletedAt});

  bool get isExpiredFromBuffer => deletedAt.isBefore(
        DateTime.now().subtract(const Duration(days: 180)));

  Map<String, dynamic> toJson() => {
        'item': item.toJson(),
        'deletedAt': deletedAt.toIso8601String(),
      };

  factory DeletedProduct.fromJson(Map<String, dynamic> json) => DeletedProduct(
        item: Product.fromJson(json['item'] as Map<String, dynamic>),
        deletedAt: DateTime.parse(json['deletedAt'] as String),
      );
}

typedef ReportEntry = ({Product item, DateTime? deletedAt});

enum SortColumn { number, name, description, stock, stockMin }

// ─── Scanare cod de bare ───────────────────────────────────────────────────────
class BarcodeScannerPage extends StatefulWidget {
  const BarcodeScannerPage({super.key});
  @override
  State<BarcodeScannerPage> createState() => _BarcodeScannerPageState();
}

class _BarcodeScannerPageState extends State<BarcodeScannerPage> {
  final _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final value = barcodes.first.rawValue;
    if (value == null || value.isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scanează cod de bare'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            tooltip: 'Blitz',
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: MobileScanner(controller: _controller, onDetect: _onDetect),
    );
  }
}

// ─── Punct de intrare ─────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AlertService.init();
  runApp(const InventarPlusApp());
}

class InventarPlusApp extends StatelessWidget {
  const InventarPlusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Inventar+',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF14304F),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF08151F),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
        ),
      ),
      home: const InventarPage(),
    );
  }
}

class InventarPage extends StatefulWidget {
  const InventarPage({super.key});
  @override
  State<InventarPage> createState() => _InventarPageState();
}

class _InventarPageState extends State<InventarPage>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  bool _searchVisible = false;

  final List<({SortColumn column, bool ascending})> _sortCriteria = [
    (column: SortColumn.number, ascending: true),
  ];
  String _searchQuery  = '';
  bool   _loading      = true;
  int    _nextNumber   = 1;

  final List<Product>        _items         = [];
  final List<DeletedProduct> _deletedBuffer = [];
  String _smsTemplate = _kDefaultSmsTemplate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AlertService.requestPermissions();
      SmsService.requestPermission();
    });
  }

  Future<void> _loadData() async {
    await SyncService.load();
    await LicenseService.load();
    await _loadItems();
    await _processSyncQueue();
    await _checkPendingLicense();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _processSyncQueue();
      _checkPendingLicense();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  // ── Persistență ─────────────────────────────────────────────────────────────
  Future<void> _loadItems() async {
    List<Product>? loaded;
    int nextNumber = 1;
    try {
      final prefs   = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kItemsKey);
      nextNumber    = prefs.getInt(_kNextNumberKey) ?? 1;
      _smsTemplate  = prefs.getString(_kSmsTemplateKey) ?? _kDefaultSmsTemplate;
      final deletedStr = prefs.getString(_kDeletedBufferKey);
      if (deletedStr != null) {
        final deletedList = (jsonDecode(deletedStr) as List<dynamic>)
            .map((e) => DeletedProduct.fromJson(e as Map<String, dynamic>))
            .where((d) => !d.isExpiredFromBuffer)
            .toList();
        _deletedBuffer.addAll(deletedList);
      }
      if (jsonStr != null) {
        loaded = (jsonDecode(jsonStr) as List<dynamic>)
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}

    if (!mounted) return;

    if (loaded != null) {
      setState(() {
        _items.addAll(loaded!);
        _nextNumber = nextNumber;
        _loading    = false;
      });
    } else {
      final seed = [
        Product(syncId: _generateSyncId(), number: 1, denumire: 'Făină albă 1kg',          descriere: 'Ambalaj hârtie',  codBare: '5941234500011', stocActual: 40, stocMinim: 10, pragAlerta: 20, createdAt: DateTime.now()),
        Product(syncId: _generateSyncId(), number: 2, denumire: 'Ulei floarea-soarelui 1L', descriere: 'Sticlă PET',      codBare: '5941234500028', stocActual: 15, stocMinim: 10, pragAlerta: 20, createdAt: DateTime.now()),
        Product(syncId: _generateSyncId(), number: 3, denumire: 'Zahăr tos 1kg',            descriere: 'Ambalaj plastic', codBare: '5941234500035', stocActual: 5,  stocMinim: 10, pragAlerta: 20, createdAt: DateTime.now()),
        Product(syncId: _generateSyncId(), number: 4, denumire: 'Orez bob lung 1kg',        descriere: 'Ambalaj plastic', codBare: '5941234500042', stocActual: 60, stocMinim: 15, pragAlerta: 25, createdAt: DateTime.now()),
        Product(syncId: _generateSyncId(), number: 5, denumire: 'Detergent vase 500ml',     descriere: 'Sticlă cu pompă', codBare: '5941234500059', stocActual: 8,  stocMinim: 8,  pragAlerta: 15, createdAt: DateTime.now()),
      ];
      setState(() {
        _items.addAll(seed.map((p) => p.copyWith(lastAlertLevel: alertLevelFor(p))));
        _nextNumber = 6;
        _loading    = false;
      });
      await _saveItems();
    }
  }

  Future<void> _saveItems() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kItemsKey,
        jsonEncode(_items.map((e) => e.toJson()).toList()));
    await prefs.setInt(_kNextNumberKey, _nextNumber);
  }

  Future<void> _saveBuffer() async {
    _deletedBuffer.removeWhere((d) => d.isExpiredFromBuffer);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kDeletedBufferKey,
      jsonEncode(_deletedBuffer.map((d) => d.toJson()).toList()),
    );
  }

  // ── Aplicare modificare produs + verificare/declanșare alertă ────────────────
  Future<void> _persistAndCheckAlert(
    int idx,
    Product before,
    Product after, {
    bool isNew = false,
  }) async {
    final newLevel = alertLevelFor(after);
    final finalProduct = after.copyWith(lastAlertLevel: newLevel);
    setState(() {
      if (idx == -1) {
        _items.add(finalProduct);
      } else {
        _items[idx] = finalProduct;
      }
    });
    await _saveItems();
    if (isNew) {
      await SyncService.sendAdd(finalProduct);
    } else {
      await SyncService.sendUpdate(finalProduct);
    }
    if (!isNew && newLevel > before.lastAlertLevel) {
      await AlertService.notify(finalProduct, newLevel, _smsTemplate);
    }
  }

  // ── Procesare coadă sincronizare ─────────────────────────────────────────────
  Future<void> _processSyncQueue() async {
    if (_loading) return;
    final messages = await SyncService.getPendingMessages();
    if (messages.isEmpty) return;

    bool changed = false;

    for (final msg in messages) {
      try {
        if (msg.startsWith('INV:A:') || msg.startsWith('INV:I:')) {
          final prefix = msg.startsWith('INV:A:') ? 'INV:A:' : 'INV:I:';
          final j = jsonDecode(msg.substring(prefix.length)) as Map<String, dynamic>;
          final incoming = Product.fromSyncJson(j);
          final idx = _items.indexWhere((e) => e.syncId == incoming.syncId);
          if (idx == -1) {
            _items.add(incoming.copyWith(number: _nextNumber++));
          } else {
            _items[idx] = incoming.copyWith(number: _items[idx].number);
          }
          changed = true;
        } else if (msg.startsWith('INV:U:')) {
          final j = jsonDecode(msg.substring(6)) as Map<String, dynamic>;
          final incoming = Product.fromSyncJson(j);
          final idx = _items.indexWhere((e) => e.syncId == incoming.syncId);
          if (idx != -1) {
            _items[idx] = incoming.copyWith(number: _items[idx].number);
          } else {
            _items.add(incoming.copyWith(number: _nextNumber++));
          }
          changed = true;
        } else if (msg.startsWith('INV:D:')) {
          final syncId = msg.substring(6).trim();
          final idx = _items.indexWhere((e) => e.syncId == syncId);
          if (idx != -1) {
            _deletedBuffer.add(
                DeletedProduct(item: _items[idx], deletedAt: DateTime.now()));
            _items.removeAt(idx);
            changed = true;
          }
        }
        // INV:Z: (sfârșitul sincronizării inițiale) — ignorat
      } catch (_) {
        // SMS corupt sau format necunoscut — ignorat
      }
    }

    if (changed) {
      for (var i = 0; i < _items.length; i++) {
        if (_items[i].number != i + 1) {
          _items[i] = _items[i].copyWith(number: i + 1);
        }
      }
      _nextNumber = _items.length + 1;
      if (mounted) setState(() {});
      await _saveItems();
      await _saveBuffer();
    }

    await SyncService.clearQueue();
  }

  // ── Activare licență prin fișier .invtoken ───────────────────────────────────
  Future<void> _checkPendingLicense() async {
    if (LicenseService.isLicensed) return;
    final token = await LicenseService.getPendingToken();
    if (token != null && mounted) {
      await _showActivationDialog(token);
    }
  }

  Future<void> _showActivationDialog(String tokenJson) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.vpn_key, color: Color(0xFF08151F)),
          SizedBox(width: 8),
          Text('Activare Licență'),
        ]),
        content: const Text(
          'A fost detectat un fișier de licență Inventar+.\n\n'
          'Doriți să activați aplicația acum?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anulează'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Activează'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final r = await LicenseService.activate(tokenJson);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(r.message),
        backgroundColor: r.success ? Colors.green.shade700 : Colors.red.shade700,
        duration: const Duration(seconds: 4),
      ),
    );
    if (r.success) setState(() {});
  }

  void _showLicenseRequiredDialog() async {
    final businessId = await LicenseService.getBusinessId();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.lock_outline, color: Colors.orange),
          SizedBox(width: 8),
          Text('Licență necesară'),
        ]),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Perioada de trial gratuită de 1 lună a expirat.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                'Cumpără o licență pe voltacademy.app/inventarplus.html folosind codul de instalare de mai jos, apoi importă fișierul descărcat:',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFC7D2FE)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        businessId,
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Color(0xFF3730A3)),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: 'Copiază codul',
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: businessId));
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Cod copiat.')),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.folder_open),
                label: const Text('Select License File'),
                onPressed: () async {
                  final ok = await LicenseService.pickLicenseFile();
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(ok
                          ? 'Licență activată cu succes!'
                          : (LicenseService.newLicenseMessage.isNotEmpty
                              ? LicenseService.newLicenseMessage
                              : 'Fișierul selectat nu este o licență validă.')),
                      backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
                    ),
                  );
                  if (ok) {
                    Navigator.pop(ctx);
                    if (mounted) setState(() {});
                  }
                },
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'Ai deja un fișier .invtoken vechi de la Volt Academy?\n'
                'Deschide-l din WhatsApp sau Files și alege "Inventar+".',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Închide'),
          ),
        ],
      ),
    );
  }

  // ── Filtrare și sortare ──────────────────────────────────────────────────────
  List<Product> get _filteredAndSorted {
    var result = _items.where((item) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return item.number.toString().contains(q) ||
          item.denumire.toLowerCase().contains(q) ||
          item.descriere.toLowerCase().contains(q) ||
          item.codBare.toLowerCase().contains(q) ||
          item.stocActual.toString().contains(q) ||
          item.stocMinim.toString().contains(q);
    }).toList();

    result.sort((a, b) {
      for (final c in _sortCriteria) {
        final cmp = _compareItems(a, b, c.column);
        if (cmp != 0) return c.ascending ? cmp : -cmp;
      }
      return 0;
    });
    return result;
  }

  String _formatDateTime(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}.'
      '${dt.month.toString().padLeft(2, '0')}.'
      '${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  int _compareItems(Product a, Product b, SortColumn col) {
    switch (col) {
      case SortColumn.number:      return a.number.compareTo(b.number);
      case SortColumn.name:        return a.denumire.compareTo(b.denumire);
      case SortColumn.description: return a.descriere.compareTo(b.descriere);
      case SortColumn.stock:       return a.stocActual.compareTo(b.stocActual);
      case SortColumn.stockMin:    return a.stocMinim.compareTo(b.stocMinim);
    }
  }

  void _onSort(SortColumn column) {
    setState(() {
      final idx = _sortCriteria.indexWhere((c) => c.column == column);
      if (idx == -1) {
        _sortCriteria.add((column: column, ascending: true));
      } else if (_sortCriteria[idx].ascending) {
        _sortCriteria[idx] = (column: column, ascending: false);
      } else {
        _sortCriteria.removeAt(idx);
      }
    });
  }

  Widget _buildSortIcon(SortColumn column) {
    final idx = _sortCriteria.indexWhere((c) => c.column == column);
    if (idx == -1) {
      return const Icon(Icons.unfold_more, size: 16, color: Colors.white54);
    }
    final isAsc   = _sortCriteria[idx].ascending;
    final showNum = _sortCriteria.length > 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isAsc ? Icons.arrow_upward : Icons.arrow_downward,
          size: 14, color: Colors.white,
        ),
        if (showNum)
          Padding(
            padding: const EdgeInsets.only(left: 1),
            child: Text(
              '${idx + 1}',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeaderCell(String label, SortColumn column, {double? width}) {
    return InkWell(
      onTap: () => _onSort(column),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ),
            const SizedBox(width: 4),
            _buildSortIcon(column),
          ],
        ),
      ),
    );
  }

  // ── Permisiune cameră ────────────────────────────────────────────────────────
  Future<bool> _ensureCameraPermission() async {
    final status = await Permission.camera.request();
    if (status.isGranted) return true;
    if (!mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Permisiunea pentru cameră este necesară pentru scanare.')),
    );
    return false;
  }

  Future<String?> _scanBarcode() async {
    final granted = await _ensureCameraPermission();
    if (!granted || !mounted) return null;
    return Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BarcodeScannerPage()),
    );
  }

  // ── Dialog adăugare / editare produs ─────────────────────────────────────────
  Future<void> _showItemDialog({Product? existing, String? prefillBarcode}) async {
    final isEdit  = existing != null;
    if (!isEdit && !LicenseService.canAdd) {
      _showLicenseRequiredDialog();
      return;
    }
    final nameCtrl    = TextEditingController(text: existing?.denumire ?? '');
    final descCtrl    = TextEditingController(text: existing?.descriere ?? '');
    final barcodeCtrl = TextEditingController(text: existing?.codBare ?? prefillBarcode ?? '');
    final minCtrl     = TextEditingController(text: (existing?.stocMinim ?? 0).toString());
    final alertCtrl   = TextEditingController(text: (existing?.pragAlerta ?? 0).toString());

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Text(isEdit ? 'Editează produsul' : 'Adaugă produs'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Denumire produs *', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Descriere', border: OutlineInputBorder()),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: barcodeCtrl,
                    decoration: InputDecoration(
                      labelText: 'Cod de bare',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.qr_code_scanner),
                        tooltip: 'Scanează',
                        onPressed: () async {
                          final code = await _scanBarcode();
                          if (code != null) setDs(() => barcodeCtrl.text = code);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Fără cod de bare, produsul nu poate fi actualizat prin butoanele +/- (scanare).',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: minCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Stoc minim *', border: OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: alertCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Prag alertă', border: OutlineInputBorder()),
                        ),
                      ),
                    ],
                  ),
                  if (isEdit) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Stoc actual: ${existing.stocActual}  (se modifică din butoanele +/- de pe ecranul principal)',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anulează'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final desc = descCtrl.text.trim();
                final code = barcodeCtrl.text.trim();
                final min  = int.tryParse(minCtrl.text.trim()) ?? 0;
                final alert = int.tryParse(alertCtrl.text.trim()) ?? min;
                if (name.isEmpty) return;

                if (code.isNotEmpty) {
                  final dup = _items.any((e) =>
                      e.codBare == code && (!isEdit || e.number != existing.number));
                  if (dup) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Acest cod de bare este deja folosit de alt produs.')),
                    );
                    return;
                  }
                }

                Navigator.pop(ctx, true);
                _commitItemDialog(
                  isEdit: isEdit,
                  existing: existing,
                  denumire: name,
                  descriere: desc,
                  codBare: code,
                  stocMinim: min,
                  pragAlerta: alert,
                );
              },
              child: Text(isEdit ? 'Salvează' : 'Adaugă'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
  }

  Future<void> _commitItemDialog({
    required bool isEdit,
    required Product? existing,
    required String denumire,
    required String descriere,
    required String codBare,
    required int stocMinim,
    required int pragAlerta,
  }) async {
    if (isEdit) {
      final idx = _items.indexWhere((e) => e.number == existing!.number);
      if (idx == -1) return;
      final before = _items[idx];
      final after = before.copyWith(
        denumire: denumire,
        descriere: descriere,
        codBare: codBare,
        stocMinim: stocMinim,
        pragAlerta: pragAlerta,
      );
      await _persistAndCheckAlert(idx, before, after);
    } else {
      final product = Product(
        syncId:     _generateSyncId(),
        number:     _nextNumber++,
        denumire:   denumire,
        descriere:  descriere,
        codBare:    codBare,
        stocActual: 0,
        stocMinim:  stocMinim,
        pragAlerta: pragAlerta,
        createdAt:  DateTime.now(),
      );
      await _persistAndCheckAlert(-1, product, product, isNew: true);
    }
  }

  // ── Dialog telefoane pentru alertă SMS ────────────────────────────────────────
  Future<void> _showAlertPhonesDialog(Product item) async {
    final phone1Ctrl = TextEditingController(text: item.phoneNumber  ?? '');
    final phone2Ctrl = TextEditingController(text: item.phoneNumber2 ?? '');
    final phone3Ctrl = TextEditingController(text: item.phoneNumber3 ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: const Text('Telefoane alertă & SMS'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.denumire,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Stoc actual: ${item.stocActual}  ·  Minim: ${item.stocMinim}  ·  Prag alertă: ${item.pragAlerta}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _phoneField(phone1Ctrl, 'Telefon 1 (opțional)', setDs),
                  const SizedBox(height: 10),
                  _phoneField(phone2Ctrl, 'Telefon 2 (opțional)', setDs),
                  const SizedBox(height: 10),
                  _phoneField(phone3Ctrl, 'Telefon 3 (opțional)', setDs),
                  const SizedBox(height: 6),
                  Text(
                    'Notificare + SMS trimise automat, o singură dată, la atingerea '
                    'pragului de alertă (galben) sau a stocului minim (roșu).',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anulează'),
            ),
            FilledButton(
              onPressed: () {
                final p1  = phone1Ctrl.text.trim();
                final p2  = phone2Ctrl.text.trim();
                final p3  = phone3Ctrl.text.trim();
                final idx = _items.indexWhere((e) => e.number == item.number);
                if (idx != -1) {
                  setState(() {
                    _items[idx] = item.copyWith(
                      phoneNumber:  p1.isNotEmpty ? p1 : null, clearPhone:  p1.isEmpty,
                      phoneNumber2: p2.isNotEmpty ? p2 : null, clearPhone2: p2.isEmpty,
                      phoneNumber3: p3.isNotEmpty ? p3 : null, clearPhone3: p3.isEmpty,
                    );
                  });
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Salvează'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      final updated = _items.firstWhere(
          (e) => e.number == item.number, orElse: () => item);
      await SyncService.sendUpdate(updated);
      await _saveItems();
    }
  }

  // ── Ștergere ─────────────────────────────────────────────────────────────────
  Future<void> _confirmDelete(Product item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Șterge produs'),
        content: Text('Ești sigur că vrei să ștergi "${item.denumire}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anulează'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Șterge'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final syncId = item.syncId;
      _deletedBuffer.add(DeletedProduct(item: item, deletedAt: DateTime.now()));
      setState(() {
        _items.removeWhere((e) => e.number == item.number);
        for (var i = 0; i < _items.length; i++) {
          if (_items[i].number != i + 1) {
            _items[i] = _items[i].copyWith(number: i + 1);
          }
        }
        _nextNumber = _items.length + 1;
      });
      await SyncService.sendDelete(syncId);
      await _saveItems();
      await _saveBuffer();
    }
  }

  // ── Scanare + ajustare stoc (butoanele globale +/-) ──────────────────────────
  Future<int?> _askQuantity({required String title, required int currentStock}) {
    final ctrl = TextEditingController(text: '1');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Stoc actual: $currentStock',
                style: TextStyle(color: Colors.grey.shade600)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Cantitate', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Anulează'),
          ),
          FilledButton(
            onPressed: () {
              final q = int.tryParse(ctrl.text.trim());
              if (q == null || q <= 0) return;
              Navigator.pop(ctx, q);
            },
            child: const Text('Confirmă'),
          ),
        ],
      ),
    );
  }

  Future<void> _scanAndAdjust(bool increase) async {
    final code = await _scanBarcode();
    if (code == null || !mounted) return;

    final idx = _items.indexWhere((e) => e.codBare == code);
    if (idx == -1) {
      final addNow = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Produs necunoscut'),
          content: Text(
              'Niciun produs nu are codul de bare "$code". Adaugi un produs nou cu acest cod?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anulează'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Adaugă produs'),
            ),
          ],
        ),
      );
      if (addNow == true && mounted) await _showItemDialog(prefillBarcode: code);
      return;
    }

    final product = _items[idx];
    final qty = await _askQuantity(
      title: '${increase ? "Adaugă" : "Scoate"} stoc — ${product.denumire}',
      currentStock: product.stocActual,
    );
    if (qty == null) return;

    final newStock = increase
        ? product.stocActual + qty
        : (product.stocActual - qty).clamp(0, 1 << 30);
    final after = product.copyWith(stocActual: newStock);
    await _persistAndCheckAlert(idx, product, after);
  }

  // ── Dialog sincronizare dispozitiv ───────────────────────────────────────────
  Future<void> _showSyncDialog() async {
    final phoneCtrl =
        TextEditingController(text: SyncService.partnerPhone ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Row(
            children: [
              Icon(
                SyncService.isActive ? Icons.sync : Icons.sync_disabled,
                color: SyncService.isActive
                    ? Colors.green.shade600
                    : Colors.grey,
                size: 22,
              ),
              const SizedBox(width: 8),
              const Text('Sincronizare dispozitiv'),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (SyncService.isActive) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle_outline,
                              color: Colors.green.shade700, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Sincronizare activă cu:\n${SyncService.partnerPhone}',
                              style: TextStyle(
                                  color: Colors.green.shade800,
                                  fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Modificările se trimit automat prin SMS la fiecare schimbare.',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ] else ...[
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Număr telefon partener *',
                        hintText: '+40712345678',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.shade100),
                      ),
                      child: Text(
                        'La prima sincronizare, toate produsele de pe acest '
                        'dispozitiv vor fi trimise prin SMS. Ulterior, fiecare '
                        'modificare va fi sincronizată automat.\n\n'
                        'Configurează sincronizarea și pe celălalt dispozitiv '
                        'pentru a primi și de acolo.',
                        style: TextStyle(
                            fontSize: 11, color: Colors.blue.shade700),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (SyncService.isActive)
              TextButton.icon(
                icon: const Icon(Icons.sync_disabled, color: Colors.red, size: 18),
                label: const Text('Desincronizează',
                    style: TextStyle(color: Colors.red)),
                onPressed: () async {
                  await SyncService.clearPartner();
                  setDs(() {});
                  if (ctx.mounted) Navigator.pop(ctx);
                  setState(() {});
                },
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Închide'),
            ),
            if (!SyncService.isActive)
              FilledButton.icon(
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('Sincronizează'),
                onPressed: () async {
                  final phone = phoneCtrl.text.trim();
                  if (phone.isEmpty) return;
                  await SyncService.setPartner(phone);
                  setDs(() {});
                  if (ctx.mounted) Navigator.pop(ctx);
                  setState(() {});
                  _performInitialSync();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _performInitialSync() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Trimitere sincronizare inițială (${_items.length} produse)...'),
        duration: Duration(seconds: _items.length * 2 + 3),
      ),
    );
    await SyncService.sendInitialSync(_items);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Sincronizare inițială trimisă!'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  // ── Dialog detalii ───────────────────────────────────────────────────────────
  void _showItemDetail(Product item) {
    final lvl = alertLevelFor(item);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.denumire),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow('Nr.', item.number.toString()),
              const SizedBox(height: 10),
              _detailRow('Descriere',
                  item.descriere.isEmpty ? '—' : item.descriere),
              const SizedBox(height: 10),
              _detailRow('Cod de bare',
                  item.codBare.isEmpty ? '—' : item.codBare),
              const SizedBox(height: 10),
              _detailRow('Stoc actual', item.stocActual.toString(),
                  valueColor: lvl == 2
                      ? Colors.red.shade700
                      : lvl == 1
                          ? Colors.orange.shade700
                          : null),
              const SizedBox(height: 10),
              _detailRow('Stoc minim', item.stocMinim.toString()),
              const SizedBox(height: 10),
              _detailRow('Prag alertă', item.pragAlerta.toString()),
              const SizedBox(height: 10),
              _detailRow('Creat la', _formatDateTime(item.createdAt)),
              if (item.phones.isNotEmpty) ...[
                const SizedBox(height: 10),
                _detailRow('SMS la', item.phones.join('\n'),
                    valueColor: Colors.blue.shade700),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showItemDialog(existing: item);
            },
            child: const Text('Editează'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Închide'),
          ),
        ],
      ),
    );
  }

  // ── Widget helpers ───────────────────────────────────────────────────────────
  Widget _detailRow(String label, String value, {Color? valueColor}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(fontSize: 14, color: valueColor ?? Colors.black87)),
      ],
    );
  }

  Widget _dataCell(String text,
      {double? width, bool critical = false, bool warning = false}) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: critical
              ? Colors.red.shade700
              : warning
                  ? Colors.orange.shade800
                  : Colors.black87,
          fontWeight: (critical || warning) ? FontWeight.w500 : FontWeight.normal,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return IconButton(
      icon: Icon(icon, size: 18, color: color),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    );
  }

  Color _rowBg(Product item, bool isEven) {
    final lvl = alertLevelFor(item);
    if (lvl == 2) return const Color(0xFFFFDADA);
    if (lvl == 1) return const Color(0xFFFEF3C7);
    return isEven ? Colors.white : const Color(0xFFF8FAFC);
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final rows = _filteredAndSorted;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventar+'),
        actions: [
          if (Platform.isAndroid)
            IconButton(
              icon: Icon(
                LicenseService.isLicensed
                    ? Icons.verified_user
                    : LicenseService.isTrialActive
                        ? Icons.lock_open_outlined
                        : Icons.lock_outline,
                color: LicenseService.isLicensed
                    ? Colors.greenAccent.shade100
                    : LicenseService.isTrialActive
                        ? Colors.orangeAccent.shade100
                        : Colors.white54,
              ),
              tooltip: LicenseService.isLicensed
                  ? 'Licență activă'
                  : LicenseService.isTrialActive
                      ? 'Trial activ · ${LicenseService.trialDaysLeft} zile rămase'
                      : 'Trial expirat · activează licența',
              onPressed: LicenseService.isLicensed
                  ? null
                  : _showLicenseRequiredDialog,
            ),
          if (SyncService.isSupported)
            IconButton(
              icon: Icon(
                SyncService.isActive ? Icons.sync : Icons.sync_disabled,
                color: SyncService.isActive
                    ? Colors.greenAccent.shade100
                    : Colors.white54,
              ),
              tooltip: SyncService.isActive
                  ? 'Sincronizare activă · ${SyncService.partnerPhone}'
                  : 'Configurează sincronizare',
              onPressed: _showSyncDialog,
            ),
          IconButton(
            icon: Icon(
              _searchVisible ? Icons.search_off : Icons.search,
              color: Colors.white,
            ),
            tooltip: _searchVisible ? 'Ascunde căutare' : 'Caută',
            onPressed: () {
              setState(() {
                _searchVisible = !_searchVisible;
                if (!_searchVisible) {
                  _searchController.clear();
                  _searchQuery = '';
                }
              });
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeInOut,
                    child: _searchVisible
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: TextField(
                              controller: _searchController,
                              autofocus: true,
                              decoration: InputDecoration(
                                hintText: 'Caută în tabel...',
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: _searchQuery.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.clear),
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(() => _searchQuery = '');
                                        },
                                      )
                                    : null,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(
                                      color: Color(0xFFCBD5E1)),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(
                                      color: Color(0xFFCBD5E1)),
                                ),
                                filled: true,
                                fillColor: Colors.white,
                              ),
                              onChanged: (v) =>
                                  setState(() => _searchQuery = v),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border:
                            Border.all(color: const Color(0xFFCBD5E1)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.07),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: 828,
                                child: Column(
                                  children: [
                                    Container(
                                      color: const Color(0xFF08151F),
                                      child: Row(
                                        children: [
                                          _buildHeaderCell('Nr.',         SortColumn.number,      width: 60),
                                          _buildHeaderCell('Denumire',    SortColumn.name,        width: 190),
                                          _buildHeaderCell('Descriere',   SortColumn.description, width: 190),
                                          _buildHeaderCell('Stoc actual', SortColumn.stock,        width: 110),
                                          _buildHeaderCell('Stoc minim',  SortColumn.stockMin,     width: 130),
                                          const SizedBox(width: 148),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: rows.isEmpty
                                          ? Center(
                                              child: Text(
                                                _searchQuery.isEmpty
                                                    ? 'Nu există produse.'
                                                    : 'Niciun rezultat pentru "$_searchQuery".',
                                                style: TextStyle(
                                                    color: Colors.grey.shade600),
                                              ),
                                            )
                                          : ListView.builder(
                                              itemCount: rows.length,
                                              itemBuilder: (ctx, index) {
                                                final item   = rows[index];
                                                final isEven = index % 2 == 0;
                                                final lvl    = alertLevelFor(item);
                                                return InkWell(
                                                  onTap: () =>
                                                      _showItemDetail(item),
                                                  child: Container(
                                                    color: _rowBg(item, isEven),
                                                    child: Row(
                                                      children: [
                                                        _dataCell(item.number.toString(), width: 60,  critical: lvl == 2, warning: lvl == 1),
                                                        _dataCell(item.denumire,           width: 190, critical: lvl == 2, warning: lvl == 1),
                                                        _dataCell(item.descriere,          width: 190, critical: lvl == 2, warning: lvl == 1),
                                                        _dataCell(item.stocActual.toString(), width: 110, critical: lvl == 2, warning: lvl == 1),
                                                        _dataCell(item.stocMinim.toString(),  width: 130, critical: lvl == 2, warning: lvl == 1),
                                                        SizedBox(
                                                          width: 148,
                                                          child: Row(
                                                            mainAxisAlignment:
                                                                MainAxisAlignment.center,
                                                            children: [
                                                              _actionBtn(
                                                                icon: Icons.edit_outlined,
                                                                tooltip: 'Editează',
                                                                onPressed: () =>
                                                                    _showItemDialog(existing: item),
                                                              ),
                                                              _actionBtn(
                                                                icon: Icons.phone_outlined,
                                                                tooltip: 'Telefoane alertă & SMS',
                                                                color: item.phones.isNotEmpty
                                                                    ? Colors.blue.shade600
                                                                    : null,
                                                                onPressed: () =>
                                                                    _showAlertPhonesDialog(item),
                                                              ),
                                                              _actionBtn(
                                                                icon: Icons.delete_outlined,
                                                                tooltip: 'Șterge',
                                                                color: Colors.red.shade400,
                                                                onPressed: () =>
                                                                    _confirmDelete(item),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            color: const Color(0xFFE2E8F0),
                            child: Row(
                              children: [
                                Text(
                                  rows.length == _items.length
                                      ? '${_items.length} produse'
                                      : '${rows.length} din ${_items.length} produse',
                                  style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 12),
                                ),
                                if (Platform.isAndroid && !LicenseService.isLicensed) ...[
                                  const SizedBox(width: 8),
                                  Icon(
                                    LicenseService.isTrialActive
                                        ? Icons.lock_open_outlined
                                        : Icons.lock_outline,
                                    size: 12,
                                    color: LicenseService.isTrialActive
                                        ? Colors.orange.shade600
                                        : Colors.red.shade600,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    LicenseService.isTrialActive
                                        ? 'Trial · ${LicenseService.trialDaysLeft} zile'
                                        : 'Trial expirat',
                                    style: TextStyle(
                                        color: LicenseService.isTrialActive
                                            ? Colors.orange.shade700
                                            : Colors.red.shade700,
                                        fontSize: 11),
                                  ),
                                ],
                                if (SyncService.isActive) ...[
                                  const SizedBox(width: 8),
                                  Icon(Icons.sync,
                                      size: 12,
                                      color: Colors.green.shade600),
                                  const SizedBox(width: 3),
                                  Text(
                                    'Sincronizat',
                                    style: TextStyle(
                                        color: Colors.green.shade600,
                                        fontSize: 11),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            children: [
              _bottomBtn(
                icon: Icons.add_circle_rounded,
                label: 'Adaugă',
                onTap: () => _showItemDialog(),
                primary: true,
              ),
              const SizedBox(width: 8),
              _stockAdjustBtn(increase: true),
              const SizedBox(width: 8),
              _stockAdjustBtn(increase: false),
              const SizedBox(width: 8),
              _bottomBtn(
                icon: Icons.bar_chart_rounded,
                label: 'Raport',
                onTap: _showReportDialog,
              ),
              const SizedBox(width: 8),
              _bottomBtn(
                icon: Icons.edit_note_rounded,
                label: 'Mesaj SMS',
                onTap: _showSmsTemplateDialog,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stockAdjustBtn({required bool increase}) {
    final color = increase ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(14),
      elevation: 2,
      child: InkWell(
        onTap: () => _scanAndAdjust(increase),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          child: Icon(increase ? Icons.add : Icons.remove,
              color: Colors.white, size: 26),
        ),
      ),
    );
  }

  Widget _bottomBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    const bg      = Color(0xFF08151F);
    const bgLight = Color(0xFFF1F5F9);
    return Expanded(
      child: Material(
        color: primary ? bg : bgLight,
        borderRadius: BorderRadius.circular(14),
        elevation: primary ? 3 : 0,
        shadowColor: primary
            ? const Color(0xFF08151F).withValues(alpha: 0.35)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: primary ? Colors.white : bg),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: primary ? Colors.white : bg,
                    letterSpacing: 0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Dialog raport ────────────────────────────────────────────────────────────
  Future<void> _showReportDialog() async {
    var filter = _ReportFilter.toate;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: const Text('Generează raport'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Selectează ce produse să apară în raport:',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(height: 12),
                RadioListTile<_ReportFilter>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Toate produsele'),
                  value: _ReportFilter.toate,
                  groupValue: filter,
                  onChanged: (v) => setDs(() => filter = v!),
                ),
                RadioListTile<_ReportFilter>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Sub prag alertă (galben + roșu)'),
                  value: _ReportFilter.subPrag,
                  groupValue: filter,
                  onChanged: (v) => setDs(() => filter = v!),
                ),
                RadioListTile<_ReportFilter>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Sub stoc minim (roșu)'),
                  value: _ReportFilter.subMinim,
                  groupValue: filter,
                  onChanged: (v) => setDs(() => filter = v!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Anulează'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _showReportResult(filter);
              },
              child: const Text('Generează'),
            ),
          ],
        ),
      ),
    );
  }

  void _showReportResult(_ReportFilter filter) {
    bool matchFilter(Product p) {
      switch (filter) {
        case _ReportFilter.toate:    return true;
        case _ReportFilter.subPrag:  return alertLevelFor(p) >= 1;
        case _ReportFilter.subMinim: return alertLevelFor(p) == 2;
      }
    }

    final activeItems = _items
        .where(matchFilter)
        .map<ReportEntry>((i) => (item: i, deletedAt: null))
        .toList();

    final deletedItems = _deletedBuffer
        .where((d) => matchFilter(d.item))
        .map<ReportEntry>((d) => (item: d.item, deletedAt: d.deletedAt))
        .toList();

    String statusLabel(Product p) {
      final lvl = alertLevelFor(p);
      return lvl == 2 ? 'CRITIC' : lvl == 1 ? 'ATENȚIE' : 'NORMAL';
    }

    String buildExportText(
        List<ReportEntry> all, String period, int actCnt, int delCnt) {
      final buf = StringBuffer();
      buf.writeln('═══════════════════════════════════════');
      buf.writeln('         RAPORT INVENTAR+');
      buf.writeln('═══════════════════════════════════════');
      buf.writeln('Filtru   : $period');
      buf.writeln('Total    : ${all.length} produse');
      buf.writeln('  Active : $actCnt');
      buf.writeln('  Șterse : $delCnt');
      buf.writeln('───────────────────────────────────────');
      for (final e in all) {
        buf.writeln('');
        final del = e.deletedAt != null ? ' [ȘTERS]' : '';
        buf.writeln('• ${e.item.denumire}$del  [${statusLabel(e.item)}]');
        buf.writeln('  Stoc    : ${e.item.stocActual} (minim ${e.item.stocMinim}, prag ${e.item.pragAlerta})');
        if (e.deletedAt != null) {
          buf.writeln('  Șters la: ${_formatDateTime(e.deletedAt!)}');
        }
        if (e.item.descriere.isNotEmpty) {
          buf.writeln('  Descriere: ${e.item.descriere}');
        }
      }
      buf.writeln('');
      buf.writeln('═══════════════════════════════════════');
      buf.writeln('Generat la: ${_formatDateTime(DateTime.now())}');
      return buf.toString();
    }

    final all = <ReportEntry>[...activeItems, ...deletedItems]
      ..sort((a, b) {
        final cmp = alertLevelFor(b.item).compareTo(alertLevelFor(a.item));
        return cmp != 0 ? cmp : a.item.denumire.compareTo(b.item.denumire);
      });

    final period = switch (filter) {
      _ReportFilter.toate    => 'Toate produsele',
      _ReportFilter.subPrag  => 'Sub prag alertă',
      _ReportFilter.subMinim => 'Sub stoc minim',
    };

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Raport stocuri'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Filtru: $period',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 2),
              RichText(
                text: TextSpan(
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                  children: [
                    TextSpan(
                        text: '${all.length} total  ',
                        style:
                            const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(
                        text: '(${activeItems.length} active',
                        style: const TextStyle(color: Colors.green)),
                    const TextSpan(text: '  +  '),
                    TextSpan(
                        text:
                            '${deletedItems.length} șterse din buffer)',
                        style:
                            TextStyle(color: Colors.red.shade700)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (all.isEmpty)
                const Text('Nu există produse pentru acest filtru.')
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: all.length,
                    separatorBuilder: (a, b) =>
                        const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final entry     = all[i];
                      final item      = entry.item;
                      final isDeleted = entry.deletedAt != null;
                      final lvl       = alertLevelFor(item);

                      return Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Container(
                              width: 8, height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isDeleted
                                    ? Colors.grey
                                    : lvl == 2
                                        ? Colors.red
                                        : lvl == 1
                                            ? Colors.orange
                                            : Colors.green,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          item.denumire,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                            color: isDeleted
                                                ? Colors.grey
                                                : Colors.black87,
                                            decoration: isDeleted
                                                ? TextDecoration.lineThrough
                                                : null,
                                          ),
                                        ),
                                      ),
                                      if (isDeleted)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.grey.shade200,
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            'ȘTERS',
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: Colors.grey.shade600,
                                                fontWeight:
                                                    FontWeight.w600),
                                          ),
                                        ),
                                    ],
                                  ),
                                  Text(
                                    'Stoc: ${item.stocActual}  (minim ${item.stocMinim}, prag ${item.pragAlerta})',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: isDeleted
                                            ? Colors.grey
                                            : lvl == 2
                                                ? Colors.red.shade700
                                                : lvl == 1
                                                    ? Colors.orange.shade800
                                                    : Colors.grey.shade600),
                                  ),
                                  if (isDeleted)
                                    Text(
                                      'Șters la: ${_formatDateTime(entry.deletedAt!)}',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade500),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.share_outlined, size: 18),
            label: const Text('Share'),
            onPressed: () {
              final text = buildExportText(
                  all, period, activeItems.length, deletedItems.length);
              SharePlus.instance.share(ShareParams(text: text, subject: 'Raport Inventar+'));
            },
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Închide'),
          ),
        ],
      ),
    );
  }

  // ── Dialog editare template SMS ───────────────────────────────────────────────
  Future<void> _showSmsTemplateDialog() async {
    final ctrl = TextEditingController(text: _smsTemplate);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Editează mesaj SMS'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Variabile disponibile:',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 4),
                _templateChip('[DENUMIRE]',    'Denumirea produsului'),
                _templateChip('[STOC]',        'Stocul actual'),
                _templateChip('[STOC_MINIM]',  'Stocul minim setat'),
                _templateChip('[PRAG_ALERTA]', 'Pragul de alertă setat'),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Template mesaj',
                    border: OutlineInputBorder(),
                    helperText:
                        'La trimitere, variabilele sunt înlocuite automat.',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('Resetează la implicit'),
                  onPressed: () => ctrl.text = _kDefaultSmsTemplate,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Anulează'),
          ),
          FilledButton(
            onPressed: () async {
              final tmpl = ctrl.text.trim();
              if (tmpl.isEmpty) return;
              setState(() => _smsTemplate = tmpl);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_kSmsTemplateKey, tmpl);
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
            },
            child: const Text('Salvează'),
          ),
        ],
      ),
    );
  }

  Widget _phoneField(
      TextEditingController ctrl, String label, StateSetter setDs) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.phone,
      onChanged: (_) => setDs(() {}),
      decoration: InputDecoration(
        labelText: label,
        hintText: '+40712345678',
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.phone_outlined, size: 18),
        isDense: true,
      ),
    );
  }

  Widget _templateChip(String tag, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2FF),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFFC7D2FE)),
            ),
            child: Text(tag,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Color(0xFF3730A3))),
          ),
          const SizedBox(width: 8),
          Text(desc,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }
}

enum _ReportFilter { toate, subPrag, subMinim }
