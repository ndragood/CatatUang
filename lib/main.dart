import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'auth_service.dart';
import 'lock_service.dart';
import 'dart:convert';
import 'dart:io';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint("Firebase initialization warning: $e");
  }
  await initializeDateFormatting('id_ID', null); // FIX: init locale Indonesia
  await Hive.initFlutter();
  await Hive.openBox('catatuang_db');
  final box = Hive.box('catatuang_db');
  await initNotifications();

  if (box.get('savingGoal') == null)
    await box.put('savingGoal', {"title": "Dana Darurat", "target": 10000000});
  if (box.get('kategori') == null)
    await box.put('kategori', [
      {
        "nama": "Makan",
        "budget": 1000000,
        "icon": Icons.restaurant.codePoint,
        "color": Colors.orange.value,
      },
      {
        "nama": "Transport",
        "budget": 500000,
        "icon": Icons.directions_car.codePoint,
        "color": Colors.blue.value,
      },
      {
        "nama": "Belanja",
        "budget": 500000,
        "icon": Icons.shopping_bag.codePoint,
        "color": Colors.pink.value,
      },
      {
        "nama": "Hobi",
        "budget": 200000,
        "icon": Icons.sports_esports.codePoint,
        "color": Colors.purple.value,
      },
      {
        "nama": "Gaji",
        "budget": 0,
        "icon": Icons.work.codePoint,
        "color": Colors.green.value,
      },
    ]);

  if (box.get('isReminder', defaultValue: false)) {
    final hour = box.get('reminderHour', defaultValue: 20) as int;
    final minute = box.get('reminderMinute', defaultValue: 0) as int;
    await scheduleDailyNotification(hour: hour, minute: minute);
  }
  runApp(const CatatUangApp());
}

Future<void> initNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(android: androidInit),
    onDidReceiveNotificationResponse: (NotificationResponse response) {},
  );
  final androidPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  if (androidPlugin != null) {
    await androidPlugin.requestNotificationsPermission();
    await androidPlugin.requestExactAlarmsPermission();
  }
  tz.initializeTimeZones();
  try {
    final String timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZoneName));
  } catch (_) {
    tz.setLocalLocation(tz.getLocation('Asia/Jakarta'));
  }
}

Future<void> scheduleDailyNotification({int hour = 20, int minute = 0}) async {
  await flutterLocalNotificationsPlugin.cancel(0);
  await flutterLocalNotificationsPlugin.zonedSchedule(
    0,
    'Ingat CatatUang! 💰',
    'Jangan lupa catat pengeluaranmu hari ini ya.',
    _nextInstanceOf(hour, minute),
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'reminder_channel',
        'Daily Reminders',
        importance: Importance.max,
        priority: Priority.high,
      ),
    ),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
    matchDateTimeComponents: DateTimeComponents.time,
  );
}

tz.TZDateTime _nextInstanceOf(int hour, int minute) {
  final now = tz.TZDateTime.now(tz.local);
  var scheduledDate = tz.TZDateTime(
    tz.local,
    now.year,
    now.month,
    now.day,
    hour,
    minute,
  );
  if (scheduledDate.isBefore(now))
    scheduledDate = scheduledDate.add(const Duration(days: 1));
  return scheduledDate;
}

// ─── Backup & Restore ─────────────────────────────────────────────────────────

Future<void> backupData(BuildContext context) async {
  try {
    final box = Hive.box('catatuang_db');
    final Map<String, dynamic> data = {};

    // Simpan semua data Hive ke Map
    for (var key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        data[key.toString()] = Map<String, dynamic>.from(val);
      } else if (val is List) {
        data[key.toString()] = val
            .map((e) => e is Map ? Map<String, dynamic>.from(e) : e)
            .toList();
      } else {
        data[key.toString()] = val;
      }
    }

    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    final dir = await getTemporaryDirectory();
    final now = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    final file = File('${dir.path}/catatuang_backup_$now.json');
    await file.writeAsString(jsonStr);

    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'CatatUang Backup - $now',
      text: 'Backup data CatatUang kamu',
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Gagal backup: $e"),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

Future<void> restoreData(BuildContext context) async {
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.single.path == null) return;

    final file = File(result.files.single.path!);
    final jsonStr = await file.readAsString();
    final Map<String, dynamic> data = json.decode(jsonStr);

    // Konfirmasi sebelum restore
    if (context.mounted) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Konfirmasi Restore"),
          content: const Text(
            "Data saat ini akan diganti dengan data dari file backup. Lanjutkan?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Batal"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Restore"),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    final box = Hive.box('catatuang_db');
    await box.clear();

    for (var entry in data.entries) {
      final key = int.tryParse(entry.key) ?? entry.key;
      await box.put(key, entry.value);
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Data berhasil di-restore ✅"),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Gagal restore: $e"),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String rupiah(int angka) => NumberFormat.currency(
  locale: 'id_ID',
  symbol: 'Rp ',
  decimalDigits: 0,
).format(angka);

Map? getCategoryInfo(String nama) {
  final List categories = Hive.box(
    'catatuang_db',
  ).get('kategori', defaultValue: []);
  try {
    return categories.firstWhere((e) => e['nama'] == nama);
  } catch (_) {
    return null;
  }
}

class ThousandSeparatorFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldV,
    TextEditingValue newV,
  ) {
    if (newV.text.isEmpty) return newV;
    String text = newV.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (text.isEmpty) return newV.copyWith(text: '');
    final String fmt = NumberFormat.decimalPattern(
      'id_ID',
    ).format(int.parse(text));
    return newV.copyWith(
      text: fmt,
      selection: TextSelection.collapsed(offset: fmt.length),
    );
  }
}

// ─── App ──────────────────────────────────────────────────────────────────────

class CatatUangApp extends StatelessWidget {
  const CatatUangApp({super.key});
  @override
  Widget build(BuildContext context) {
    final box = Hive.box('catatuang_db');
    return ValueListenableBuilder(
      valueListenable: box.listenable(keys: ['isDark', 'sudahOnboarding']),
      builder: (context, box, _) {
        final isDark = box.get('isDark', defaultValue: false);
        final bool sudahOnboarding = box.get(
          'sudahOnboarding',
          defaultValue: false,
        );
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            brightness: isDark ? Brightness.dark : Brightness.light,
            scaffoldBackgroundColor:
                isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            colorScheme: isDark
                ? const ColorScheme.dark(
                    primary: Color(0xFF34D399),
                    surface: Color(0xFF1E293B),
                  )
                : const ColorScheme.light(
                    primary: Color(0xFF059669),
                    surface: Colors.white,
                  ),
            cardTheme: CardThemeData(
              elevation: 0,
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          home: sudahOnboarding
              ? const AppLockWrapper()
              : const OnboardingPage(),
        );
      },
    );
  }
}

// Wrapper yang cek lock sebelum tampilkan MainPage
class AppLockWrapper extends StatefulWidget {
  const AppLockWrapper({super.key});
  @override
  State<AppLockWrapper> createState() => _AppLockWrapperState();
}

class _AppLockWrapperState extends State<AppLockWrapper>
    with WidgetsBindingObserver {
  bool _locked = false;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Auto-lock saat app di-background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      LockService.isLockEnabled().then((enabled) {
        if (enabled && mounted) setState(() => _locked = true);
      });
    }
  }

  Future<void> _checkLock() async {
    final enabled = await LockService.isLockEnabled();
    setState(() {
      _locked = enabled;
      _checked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_locked)
      return LockScreen(onUnlocked: () => setState(() => _locked = false));
    return const MainPage();
  }
}

// ─── Onboarding Page ──────────────────────────────────────────────────────────

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pageC = PageController();
  final namaC = TextEditingController();
  int _page = 0;

  final List<Map<String, dynamic>> _slides = [
    {
      'icon': Icons.waving_hand_rounded,
      'title': 'Selamat Datang di\nCatatUang!',
      'subtitle':
          'Aplikasi manajemen keuangan pribadi yang simpel dan powerful.',
    },
    {
      'icon': Icons.account_balance_wallet_rounded,
      'title': 'Catat Setiap\nTransaksi',
      'subtitle': 'Pantau pemasukan & pengeluaran harian kamu dengan mudah.',
    },
    {
      'icon': Icons.insights_rounded,
      'title': 'Lihat Laporan\n& Insight',
      'subtitle':
          'Ketahui kategori paling boros dan tren keuangan bulanan kamu.',
    },
    {
      'icon': Icons.verified_user_rounded,
      'title': 'Aman & Ter-backup\nke Cloud',
      'subtitle': 'Data kamu tersimpan aman dan bisa di-backup ke akun Google.',
    },
  ];

  void _next() {
    if (_page < _slides.length) {
      _pageC.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  void _selesai() async {
    final nama = namaC.text.trim();
    if (nama.isEmpty) return;
    final box = Hive.box('catatuang_db');
    await box.put('namaUser', nama);
    await box.put('sudahOnboarding', true);

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const AppLockWrapper()),
      );
    }
  }

  @override
  void dispose() {
    _pageC.dispose();
    namaC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: PageView(
          controller: _pageC,
          onPageChanged: (i) => setState(() => _page = i),
          physics: _page < _slides.length
              ? const NeverScrollableScrollPhysics()
              : null,
          children: [
            // Slide 1-4
            ..._slides.asMap().entries.map((entry) {
              final i = entry.key;
              final s = entry.value;
              return Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    const Spacer(),
                    // Icon ilustrasi
                    Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Icon(
                          s['icon'] as IconData,
                          size: 64,
                          color: Colors.green,
                        ),
                      ),
                    ),
                    const SizedBox(height: 40),
                    Text(
                      s['title'],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      s['subtitle'],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.grey.shade500,
                        height: 1.5,
                      ),
                    ),
                    const Spacer(),
                    // Dots indicator
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                        _slides.length + 1,
                        (j) => AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: _page == j ? 24 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _page == j
                                ? Colors.green
                                : Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Tombol next
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _next,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          i == _slides.length - 1
                              ? "Mulai Setup →"
                              : "Lanjut →",
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    if (i < _slides.length - 1) ...[
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () {
                          _pageC.animateToPage(
                            _slides.length,
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeInOut,
                          );
                        },
                        child: Text(
                          "Lewati",
                          style: TextStyle(color: Colors.grey.shade500),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                  ],
                ),
              );
            }),

            // Halaman setup nama (terakhir)
            Padding(
              padding: const EdgeInsets.all(32),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: 40),
                    Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: Text("✍️", style: TextStyle(fontSize: 64)),
                      ),
                    ),
                    const SizedBox(height: 40),
                    const Text(
                      "Siapa nama kamu?",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Biar CatatUang bisa menyapa kamu dengan nama!",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.grey.shade500,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Container(
                      decoration: BoxDecoration(
                        color: isDark ? Colors.grey.shade900 : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.green, width: 1.5),
                        boxShadow: isDark
                            ? []
                            : [
                                BoxShadow(
                                  color: Colors.grey.shade100,
                                  blurRadius: 8,
                                ),
                              ],
                      ),
                      child: TextField(
                        controller: namaC,
                        textCapitalization: TextCapitalization.words,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          hintText: "Masukkan nama kamu...",
                          hintStyle: TextStyle(
                            color: Colors.grey.shade400,
                            fontWeight: FontWeight.normal,
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          prefixIcon: const Icon(
                            Icons.person_outline,
                            color: Colors.green,
                          ),
                        ),
                        onSubmitted: (_) => _selesai(),
                      ),
                    ),
                    const SizedBox(height: 40),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                        _slides.length + 1,
                        (j) => AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: _page == j ? 24 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _page == j
                                ? Colors.green
                                : Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _selesai,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          "Mulai Pakai CatatUang! 🚀",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Main Navigation ──────────────────────────────────────────────────────────

class MainPage extends StatefulWidget {
  const MainPage({super.key});
  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int curIndex = 0;
  final pages = const [
    HomePage(),
    RiwayatPage(),
    TambahPage(),
    LaporanPage(),
    SettingPage(),
  ];
  @override
  Widget build(BuildContext context) {
    final isLightPage = curIndex != 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isLightPage ? null : null,
      body: pages[curIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withOpacity(0.3)
                  : const Color(0xFF64748B).withOpacity(0.08),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: curIndex,
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: isDark
              ? const Color(0xFF34D399)
              : const Color(0xFF059669),
          unselectedItemColor: isDark
              ? const Color(0xFF64748B)
              : const Color(0xFF94A3B8),
          selectedLabelStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
          unselectedLabelStyle: const TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 12,
          ),
          onTap: (v) => setState(() => curIndex = v),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_rounded),
              label: "Home",
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.history_rounded),
              label: "Riwayat",
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.add_circle_rounded),
              label: "Tambah",
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart_rounded),
              label: "Laporan",
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings_rounded),
              label: "Setting",
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Home Page ────────────────────────────────────────────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    final box = Hive.box('catatuang_db');
    return SafeArea(
      child: StreamBuilder<User?>(
        stream: AuthService.userStream,
        builder: (context, authSnapshot) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return ValueListenableBuilder(
            valueListenable: box.listenable(),
            builder: (context, box, _) {
              int saldo = 0, masuk = 0, keluar = 0;
              Map<String, int> usedBudget = {};
              final now = DateTime.now();

              for (var item in box.values) {
                if (item is Map && item.containsKey("nominal")) {
                  int n = item["nominal"] is int
                      ? item["nominal"]
                      : int.tryParse(item["nominal"].toString()) ?? 0;
                  if (item["tipe"] == "Masuk") {
                    saldo += n;
                    masuk += n;
                  } else {
                    saldo -= n;
                    keluar += n;
                    // Hanya hitung pengeluaran bulan ini untuk budget
                    try {
                      final tgl = DateTime.parse(item["tanggal"]);
                      if (tgl.month == now.month && tgl.year == now.year) {
                        String kat = item["kategori"] ?? "Lainnya";
                        usedBudget[kat] = (usedBudget[kat] ?? 0) + n;
                      }
                    } catch (_) {}
                  }
                }
              }
              final List categories =
                  (box.get('kategori', defaultValue: []) as List).cast<Map>();
              final goal = box.get(
                'savingGoal',
                defaultValue: {"title": "Dana Darurat", "target": 10000000},
              );
              final int danaDarurat =
                  box.get('danaDarurat', defaultValue: 0) as int;
              final int target = goal['target'] as int;
              final double progress = target > 0
                  ? (danaDarurat / target).clamp(0.0, 1.0)
                  : 0;
              final int persen = (progress * 100).toInt();

              // Nama dari Google, Hive, atau default
              final user = AuthService.currentUser;
              final String namaHive =
                  box.get('namaUser', defaultValue: '') as String;
              String namaUser;
              if (user != null &&
                  user.displayName != null &&
                  user.displayName!.isNotEmpty) {
                namaUser = user.displayName!.split(' ').first;
              } else if (namaHive.isNotEmpty) {
                namaUser = namaHive;
              } else {
                namaUser = "Pengguna";
              }

              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                children: [
                  // ── Header ──
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Halo, $namaUser ",
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              DateFormat(
                                'EEEE, d MMMM yyyy',
                                'id_ID',
                              ).format(DateTime.now()),
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // ── Saldo Card (Premium Dark) ──
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      gradient: isDark
                          ? const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
                            )
                          : const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF047857), Color(0xFF10B981)],
                            ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? Colors.black.withOpacity(0.4)
                              : const Color(0xFF059669).withOpacity(0.28),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Label saldo
                        Row(
                          children: [
                            Icon(
                              Icons.account_balance_wallet_outlined,
                              color: Colors.white.withOpacity(0.6),
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              "Saldo Utama",
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          rupiah(saldo),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 20),
                        // Divider
                        Divider(
                          color: Colors.white.withOpacity(0.15),
                          height: 1,
                        ),
                        const SizedBox(height: 16),
                        // Masuk & Keluar
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.arrow_downward,
                                          color: Colors.white,
                                          size: 12,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        "Masuk bulan ini",
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.6),
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    rupiah(masuk),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              width: 1,
                              height: 36,
                              color: Colors.white.withOpacity(0.15),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(
                                              0.15,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.arrow_upward,
                                            color: Colors.white,
                                            size: 12,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          "Keluar bulan ini",
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(
                                              0.6,
                                            ),
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      rupiah(keluar),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── Budget Bulanan ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Budget Bulanan",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        DateFormat('MMM yyyy', 'id_ID').format(DateTime.now()),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  Container(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withOpacity(0.06)
                            : const Color(0xFFE2E8F0),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? Colors.black.withOpacity(0.25)
                              : const Color(0xFF64748B).withOpacity(0.06),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        ...categories
                            .where((c) => (c['budget'] as int) > 0)
                            .toList()
                            .asMap()
                            .entries
                            .map((entry) {
                              final i = entry.key;
                              final c = entry.value;
                              final int used = usedBudget[c['nama']] ?? 0;
                              final int budget = c['budget'] as int;
                              final double p = (used / budget).clamp(0.0, 1.0);
                              final Color catColor = p >= 1
                                  ? Colors.red
                                  : (p >= 0.75
                                        ? Colors.orange
                                        : Color(c['color']));
                              final bool isLast =
                                  i ==
                                  categories
                                          .where(
                                            (c) => (c['budget'] as int) > 0,
                                          )
                                          .length -
                                      1;
                              return Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      14,
                                      16,
                                      14,
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 38,
                                          height: 38,
                                          decoration: BoxDecoration(
                                            color: Color(
                                              c['color'],
                                            ).withOpacity(0.12),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                          child: Icon(
                                            IconData(
                                              c['icon'],
                                              fontFamily: 'MaterialIcons',
                                            ),
                                            color: Color(c['color']),
                                            size: 18,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Text(
                                                    c['nama'],
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                                  Text(
                                                    "${(p * 100).toInt()}%",
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: catColor,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(3),
                                                child: LinearProgressIndicator(
                                                  value: p,
                                                  color: catColor,
                                                  backgroundColor: catColor
                                                      .withOpacity(0.1),
                                                  minHeight: 4,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Text(
                                                    rupiah(used),
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: catColor,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                  Text(
                                                    "/ ${rupiah(budget)}",
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color:
                                                          Colors.grey.shade500,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (!isLast)
                                    Divider(
                                      height: 1,
                                      indent: 16,
                                      endIndent: 16,
                                      color: isDark
                                          ? Colors.grey.shade800
                                          : Colors.grey.shade100,
                                    ),
                                ],
                              );
                            }),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── Dana Darurat ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Dana Darurat",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _showEditGoalDialog(context, goal),
                        child: Text(
                          "Edit target",
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.green.shade600,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  Container(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withOpacity(0.06)
                            : const Color(0xFFE2E8F0),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? Colors.black.withOpacity(0.25)
                              : const Color(0xFF64748B).withOpacity(0.06),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Icon(
                                Icons.shield_outlined,
                                color: Colors.green,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    goal['title'] as String,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    "Terkumpul ${rupiah(danaDarurat)}",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: persen >= 100
                                    ? Colors.green.withOpacity(0.1)
                                    : Colors.orange.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                "$persen%",
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: persen >= 100
                                      ? Colors.green
                                      : Colors.orange,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 6,
                            color: persen >= 100
                                ? Colors.green
                                : (persen >= 50
                                      ? Colors.lightGreen
                                      : Colors.orange),
                            backgroundColor: Colors.grey.withOpacity(0.1),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              rupiah(danaDarurat),
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500,
                              ),
                            ),
                            Text(
                              "Target ${rupiah(target)}",
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () =>
                                    _showSisihkanDialog(context, saldo),
                                icon: const Icon(Icons.add, size: 16),
                                label: const Text(
                                  "Sisihkan",
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  elevation: 0,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: danaDarurat > 0
                                    ? () =>
                                          _showTarikDialog(context, danaDarurat)
                                    : null,
                                icon: const Icon(Icons.remove, size: 16),
                                label: const Text(
                                  "Tarik",
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red,
                                  side: const BorderSide(color: Colors.red),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 12,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              "Saat sisihkan, saldo utama akan berkurang",
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _showSisihkanDialog(BuildContext context, int saldo) {
    final nomC = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Sisihkan Dana Darurat"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Saldo tersedia: ${rupiah(saldo)}",
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nomC,
              keyboardType: TextInputType.number,
              inputFormatters: [ThousandSeparatorFormatter()],
              decoration: const InputDecoration(
                labelText: "Jumlah",
                prefixText: "Rp ",
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Batal"),
          ),
          ElevatedButton(
            onPressed: () {
              final raw = nomC.text.replaceAll(RegExp(r'[^0-9]'), '');
              if (raw.isEmpty) return;
              final jumlah = int.parse(raw);
              if (jumlah > saldo) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Saldo tidak cukup!"),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              final box = Hive.box('catatuang_db');
              final current = box.get('danaDarurat', defaultValue: 0) as int;
              box.put('danaDarurat', current + jumlah);
              // Kurangi saldo dengan mencatat transaksi keluar
              box.add({
                "tipe": "Keluar",
                "kategori": "Dana Darurat",
                "nominal": jumlah,
                "tanggal": DateTime.now().toString(),
              });
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    "${rupiah(jumlah)} disisihkan ke Dana Darurat ✅",
                  ),
                  backgroundColor: Colors.green,
                ),
              );
            },
            child: const Text("Sisihkan"),
          ),
        ],
      ),
    );
  }

  void _showTarikDialog(BuildContext context, int danaDarurat) {
    final nomC = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Tarik Dana Darurat"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Dana tersedia: ${rupiah(danaDarurat)}",
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nomC,
              keyboardType: TextInputType.number,
              inputFormatters: [ThousandSeparatorFormatter()],
              decoration: const InputDecoration(
                labelText: "Jumlah",
                prefixText: "Rp ",
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Batal"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final raw = nomC.text.replaceAll(RegExp(r'[^0-9]'), '');
              if (raw.isEmpty) return;
              final jumlah = int.parse(raw);
              if (jumlah > danaDarurat) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Dana darurat tidak cukup!"),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              final box = Hive.box('catatuang_db');
              final current = box.get('danaDarurat', defaultValue: 0) as int;
              box.put('danaDarurat', current - jumlah);
              // Masukkan kembali ke saldo
              box.add({
                "tipe": "Masuk",
                "kategori": "Dana Darurat",
                "nominal": jumlah,
                "tanggal": DateTime.now().toString(),
              });
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text("${rupiah(jumlah)} ditarik dari Dana Darurat"),
                  backgroundColor: Colors.orange,
                ),
              );
            },
            child: const Text("Tarik"),
          ),
        ],
      ),
    );
  }

  void _showEditGoalDialog(BuildContext context, Map goal) {
    final namaC = TextEditingController(text: goal['title']);
    final targetC = TextEditingController(
      text: NumberFormat.decimalPattern('id_ID').format(goal['target']),
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Edit Dana Darurat"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: namaC,
              decoration: const InputDecoration(
                labelText: "Nama",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: targetC,
              keyboardType: TextInputType.number,
              inputFormatters: [ThousandSeparatorFormatter()],
              decoration: const InputDecoration(
                labelText: "Target",
                prefixText: "Rp ",
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Batal"),
          ),
          ElevatedButton(
            onPressed: () {
              final raw = targetC.text.replaceAll(RegExp(r'[^0-9]'), '');
              if (raw.isEmpty || namaC.text.isEmpty) return;
              Hive.box('catatuang_db').put('savingGoal', {
                "title": namaC.text,
                "target": int.parse(raw),
              });
              Navigator.pop(ctx);
            },
            child: const Text("Simpan"),
          ),
        ],
      ),
    );
  }
}

// ─── Riwayat Page ─────────────────────────────────────────────────────────────

class RiwayatPage extends StatefulWidget {
  const RiwayatPage({super.key});
  @override
  State<RiwayatPage> createState() => _RiwayatPageState();
}

class _RiwayatPageState extends State<RiwayatPage> {
  String filter = "Semua";

  @override
  Widget build(BuildContext context) {
    final box = Hive.box('catatuang_db');
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: ValueListenableBuilder(
        valueListenable: box.listenable(),
        builder: (context, box, _) {
          final allKeys = box.keys
              .where((k) {
                final item = box.get(k);
                return item is Map && item.containsKey("nominal");
              })
              .toList()
              .reversed
              .toList();

          final filteredKeys = allKeys.where((k) {
            final item = box.get(k);
            return filter == "Semua" || item["tipe"] == filter;
          }).toList();

          // Hitung summary
          int totalMasuk = 0, totalKeluar = 0;
          for (var k in allKeys) {
            final item = box.get(k);
            final n = item["nominal"] is int
                ? item["nominal"]
                : int.tryParse(item["nominal"].toString()) ?? 0;
            if (item["tipe"] == "Masuk")
              totalMasuk += n as int;
            else
              totalKeluar += n as int;
          }

          // Grouping per hari
          final Map<String, List> grouped = {};
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final yesterday = today.subtract(const Duration(days: 1));

          for (var k in filteredKeys) {
            final item = box.get(k);
            DateTime? tgl;
            try {
              tgl = DateTime.parse(item["tanggal"]);
            } catch (_) {}
            String label;
            if (tgl != null) {
              final d = DateTime(tgl.year, tgl.month, tgl.day);
              if (d == today)
                label = "HARI INI";
              else if (d == yesterday)
                label = "KEMARIN";
              else
                label = DateFormat(
                  'd MMMM yyyy',
                  'id_ID',
                ).format(tgl).toUpperCase();
            } else {
              label = "LAINNYA";
            }
            grouped.putIfAbsent(label, () => []).add(k);
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Riwayat",
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      "Semua transaksi kamu",
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Summary Card
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E2235) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark
                          ? Colors.grey.shade800
                          : Colors.grey.shade200,
                    ),
                    boxShadow: isDark
                        ? []
                        : [
                            BoxShadow(
                              color: Colors.grey.shade100,
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                  ),
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 16,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Total Masuk",
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              rupiah(totalMasuk),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF0F6E56),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 32,
                        color: isDark
                            ? Colors.grey.shade800
                            : Colors.grey.shade200,
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Total Keluar",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                rupiah(totalKeluar),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFA32D2D),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 32,
                        color: isDark
                            ? Colors.grey.shade800
                            : Colors.grey.shade200,
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Transaksi",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "${allKeys.length}",
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Filter Pills
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    _FilterChip(
                      label: "Semua",
                      selected: filter == "Semua",
                      onTap: () => setState(() => filter = "Semua"),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: "Masuk",
                      selected: filter == "Masuk",
                      onTap: () => setState(() => filter = "Masuk"),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: "Keluar",
                      selected: filter == "Keluar",
                      onTap: () => setState(() => filter = "Keluar"),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Hint geser
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(
                      Icons.swipe_left_outlined,
                      size: 14,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      "Geser kiri untuk hapus transaksi",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // List grouped
              Expanded(
                child: filteredKeys.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.receipt_long_outlined,
                              size: 64,
                              color: Colors.grey.shade300,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              "Belum ada transaksi",
                              style: TextStyle(
                                color: Colors.grey.shade400,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                        children: grouped.entries.map((entry) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 12,
                                  bottom: 8,
                                ),
                                child: Text(
                                  entry.key,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade500,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                              ...entry.value.asMap().entries.map((e) {
                                final key = e.value;
                                final item = box.get(key);
                                final isMasuk = item["tipe"] == "Masuk";
                                final catInfo = getCategoryInfo(
                                  item["kategori"] ?? "",
                                );
                                final icon = catInfo != null
                                    ? IconData(
                                        catInfo['icon'],
                                        fontFamily: 'MaterialIcons',
                                      )
                                    : Icons.category;
                                final catColor = catInfo != null
                                    ? Color(catInfo['color'])
                                    : Colors.grey;
                                final n = item["nominal"] is int
                                    ? item["nominal"]
                                    : int.tryParse(
                                            item["nominal"].toString(),
                                          ) ??
                                          0;

                                DateTime? tgl;
                                try {
                                  tgl = DateTime.parse(item["tanggal"]);
                                } catch (_) {}
                                final timeStr = tgl != null
                                    ? DateFormat(
                                        'd MMM yyyy · HH.mm',
                                        'id_ID',
                                      ).format(tgl)
                                    : item["tanggal"].toString().split(' ')[0];

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Dismissible(
                                    key: Key(key.toString()),
                                    direction: DismissDirection.endToStart,
                                    onDismissed: (_) => box.delete(key),
                                    background: Container(
                                      alignment: Alignment.centerRight,
                                      padding: const EdgeInsets.only(right: 20),
                                      decoration: BoxDecoration(
                                        color: Colors.red.shade400,
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: const Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.delete_outline,
                                            color: Colors.white,
                                            size: 22,
                                          ),
                                          SizedBox(height: 2),
                                          Text(
                                            "Hapus",
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    child: Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: isDark
                                            ? Colors.grey.shade900
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: isDark
                                              ? Colors.grey.shade800
                                              : Colors.grey.shade200,
                                        ),
                                        boxShadow: isDark
                                            ? []
                                            : [
                                                BoxShadow(
                                                  color: Colors.grey.shade100,
                                                  blurRadius: 6,
                                                  offset: const Offset(0, 2),
                                                ),
                                              ],
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 42,
                                            height: 42,
                                            decoration: BoxDecoration(
                                              color: catColor.withOpacity(0.13),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Icon(
                                              icon,
                                              color: catColor,
                                              size: 20,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item["kategori"] ?? "Lainnya",
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  timeStr,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.grey.shade500,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.end,
                                            children: [
                                              Text(
                                                "${isMasuk ? '+ ' : '- '}${rupiah(n as int)}",
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 14,
                                                  color: isMasuk
                                                      ? const Color(0xFF0F6E56)
                                                      : const Color(0xFFA32D2D),
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 9,
                                                      vertical: 3,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: isMasuk
                                                      ? const Color(0xFFE1F5EE)
                                                      : const Color(0xFFFCEBEB),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                ),
                                                child: Text(
                                                  item["tipe"],
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    color: isMasuk
                                                        ? const Color(
                                                            0xFF0F6E56,
                                                          )
                                                        : const Color(
                                                            0xFFA32D2D,
                                                          ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ],
                          );
                        }).toList(),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF0F6E56)
              : (isDark ? const Color(0xFF1E2235) : Colors.grey.shade100),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? const Color(0xFF0F6E56)
                : (isDark ? Colors.grey.shade700 : Colors.grey.shade300),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: selected
                ? Colors.white
                : (isDark ? Colors.grey.shade400 : Colors.grey.shade600),
          ),
        ),
      ),
    );
  }
}

// ─── Tambah Page ──────────────────────────────────────────────────────────────

class TambahPage extends StatefulWidget {
  const TambahPage({super.key});
  @override
  State<TambahPage> createState() => _TambahPageState();
}

class _TambahPageState extends State<TambahPage> {
  final nomC = TextEditingController();
  final catatanC = TextEditingController();
  String tipe = "Masuk";
  String kat = "Makan";

  @override
  void dispose() {
    nomC.dispose();
    catatanC.dispose();
    super.dispose();
  }

  void _simpan() {
    if (nomC.text.isEmpty) return;
    final raw = nomC.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (raw.isEmpty) return;
    final entry = {
      "tipe": tipe,
      "kategori": kat,
      "nominal": int.parse(raw),
      "tanggal": DateTime.now().toString(),
    };
    if (catatanC.text.trim().isNotEmpty)
      entry["catatan"] = catatanC.text.trim();
    Hive.box('catatuang_db').add(entry);
    nomC.clear();
    catatanC.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              tipe == "Masuk" ? Icons.arrow_downward : Icons.arrow_upward,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text("Transaksi $tipe berhasil disimpan!"),
          ],
        ),
        backgroundColor: tipe == "Masuk"
            ? const Color(0xFF0F6E56)
            : Colors.red.shade600,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List categories = Hive.box(
      'catatuang_db',
    ).get('kategori', defaultValue: []);
    final isMasuk = tipe == "Masuk";
    const green = Color(0xFF0F6E56);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        children: [
          // Header
          const Text(
            "Tambah Transaksi",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(
            "Catat pemasukan atau pengeluaran",
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),

          const SizedBox(height: 24),

          // Tipe toggle
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: isDark ? Colors.grey.shade900 : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                _TipeButton(
                  label: "Masuk",
                  icon: Icons.arrow_downward_rounded,
                  selected: isMasuk,
                  color: green,
                  onTap: () => setState(() => tipe = "Masuk"),
                ),
                _TipeButton(
                  label: "Keluar",
                  icon: Icons.arrow_upward_rounded,
                  selected: !isMasuk,
                  color: Colors.red.shade600,
                  onTap: () => setState(() => tipe = "Keluar"),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Nominal input
          Text(
            "Nominal",
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E2235) : Colors.grey.shade100,
              border: Border.all(
                color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Text(
                  "Rp",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade500,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: nomC,
                    keyboardType: TextInputType.number,
                    inputFormatters: [ThousandSeparatorFormatter()],
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: "0",
                      hintStyle: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Kategori
          Text(
            "Kategori",
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 3.2,
            children: categories.map<Widget>((c) {
              final selected = kat == c['nama'];
              final catColor = Color(c['color']);
              return GestureDetector(
                onTap: () => setState(() => kat = c['nama']),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? catColor.withOpacity(0.15)
                        : (isDark
                              ? const Color(0xFF1E2235)
                              : Colors.grey.shade50),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected
                          ? catColor
                          : (isDark
                                ? Colors.grey.shade800
                                : Colors.grey.shade300),
                      width: selected ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: catColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          IconData(c['icon'], fontFamily: 'MaterialIcons'),
                          color: catColor,
                          size: 15,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          c['nama'],
                          style: TextStyle(
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: selected
                                ? catColor
                                : (isDark
                                      ? Colors.grey.shade400
                                      : Colors.grey.shade700),
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 20),

          // Catatan
          Text(
            "Catatan (opsional)",
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E2235) : Colors.grey.shade100,
              border: Border.all(
                color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: TextField(
              controller: catatanC,
              decoration: InputDecoration(
                hintText: "Tambahkan catatan...",
                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
              ),
            ),
          ),

          const SizedBox(height: 32),

          // Tombol Simpan
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: _simpan,
              style: ElevatedButton.styleFrom(
                backgroundColor: isMasuk ? green : Colors.red.shade600,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: Text(
                "Simpan $tipe",
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TipeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _TipeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? color : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? Colors.white : Colors.grey.shade500,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : Colors.grey.shade500,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Laporan Page ─────────────────────────────────────────────────────────────

class LaporanPage extends StatelessWidget {
  const LaporanPage({super.key});

  @override
  Widget build(BuildContext context) {
    final box = Hive.box('catatuang_db');
    final now = DateTime.now();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // ── Hitung data ──────────────────────────────────────────────────────────
    int bulanIniMasuk = 0, bulanIniKeluar = 0;
    int bulanLaluMasuk = 0, bulanLaluKeluar = 0;
    final Map<String, int> perKat = {};
    final Map<String, int> perKatBulanIni = {};
    final Map<int, int> perHari = {}; // 1=Senin..7=Minggu
    final Map<String, int> masukPerBulan = {};
    final Map<String, int> keluarPerBulan = {};
    final List<String> bulanList = [];

    for (int i = 5; i >= 0; i--) {
      final d = DateTime(now.year, now.month - i, 1);
      final key = DateFormat('MMM yy', 'id_ID').format(d);
      bulanList.add(key);
      masukPerBulan[key] = 0;
      keluarPerBulan[key] = 0;
    }

    for (var item in box.values) {
      if (item is! Map || !item.containsKey("nominal")) continue;
      final int n = item["nominal"] is int
          ? item["nominal"]
          : int.tryParse(item["nominal"].toString()) ?? 0;
      DateTime tgl;
      try {
        tgl = DateTime.parse(item["tanggal"]);
      } catch (_) {
        continue;
      }
      final String bulanKey = DateFormat('MMM yy', 'id_ID').format(tgl);
      final bool isBulanIni = tgl.month == now.month && tgl.year == now.year;
      final bool isBulanLalu =
          tgl.month == (now.month == 1 ? 12 : now.month - 1) &&
          tgl.year == (now.month == 1 ? now.year - 1 : now.year);

      if (item["tipe"] == "Masuk") {
        if (isBulanIni) bulanIniMasuk += n;
        if (isBulanLalu) bulanLaluMasuk += n;
        if (masukPerBulan.containsKey(bulanKey))
          masukPerBulan[bulanKey] = masukPerBulan[bulanKey]! + n;
      } else {
        if (isBulanIni) {
          bulanIniKeluar += n;
          final String kat = item["kategori"] ?? "Lainnya";
          perKatBulanIni[kat] = (perKatBulanIni[kat] ?? 0) + n;
          final int hari = tgl.weekday; // 1=Senin..7=Minggu
          perHari[hari] = (perHari[hari] ?? 0) + n;
        }
        if (isBulanLalu) bulanLaluKeluar += n;
        final String kat = item["kategori"] ?? "Lainnya";
        perKat[kat] = (perKat[kat] ?? 0) + n;
        if (keluarPerBulan.containsKey(bulanKey))
          keluarPerBulan[bulanKey] = keluarPerBulan[bulanKey]! + n;
      }
    }

    // Kategori paling boros bulan ini
    final sortedKat = perKatBulanIni.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    // Hari paling boros
    final namaHari = [
      '',
      'Senin',
      'Selasa',
      'Rabu',
      'Kamis',
      'Jumat',
      'Sabtu',
      'Minggu',
    ];
    final sortedHari = perHari.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    // Perbandingan bulan ini vs lalu
    final selisihKeluar = bulanIniKeluar - bulanLaluKeluar;
    final pctChange = bulanLaluKeluar > 0
        ? ((selisihKeluar / bulanLaluKeluar) * 100).toInt()
        : 0;

    // Max bar chart
    double maxY = 1000000;
    for (var b in bulanList) {
      if ((masukPerBulan[b] ?? 0) > maxY) maxY = masukPerBulan[b]!.toDouble();
      if ((keluarPerBulan[b] ?? 0) > maxY) maxY = keluarPerBulan[b]!.toDouble();
    }

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        children: [
          // Header
          const Text(
            "Laporan",
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          ),
          Text(
            DateFormat('MMMM yyyy', 'id_ID').format(now),
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 20),

          // ── Ringkasan Bulan Ini ──────────────────────────────────────────
          _SeksiLabel(label: "RINGKASAN BULAN INI"),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E2235) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
              ),
              boxShadow: isDark
                  ? []
                  : [
                      BoxShadow(
                        color: Colors.grey.shade100,
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.arrow_downward_rounded,
                                size: 14,
                                color: const Color(0xFF0F6E56),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                "Pemasukan",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            rupiah(bulanIniMasuk),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0F6E56),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 36,
                      color: isDark
                          ? Colors.grey.shade800
                          : Colors.grey.shade200,
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.arrow_upward_rounded,
                                  size: 14,
                                  color: Colors.red.shade600,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  "Pengeluaran",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              rupiah(bulanIniKeluar),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.red.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Divider(
                  height: 1,
                  color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Saldo bersih bulan ini",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      rupiah(bulanIniMasuk - bulanIniKeluar),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: (bulanIniMasuk - bulanIniKeluar) >= 0
                            ? const Color(0xFF0F6E56)
                            : Colors.red.shade600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── Perbandingan vs Bulan Lalu ───────────────────────────────────
          _SeksiLabel(label: "VS BULAN LALU"),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E2235) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
              ),
              boxShadow: isDark
                  ? []
                  : [
                      BoxShadow(
                        color: Colors.grey.shade100,
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Bulan lalu",
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          rupiah(bulanLaluKeluar),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          "Bulan ini",
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          rupiah(bulanIniKeluar),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 14,
                  ),
                  decoration: BoxDecoration(
                    color: selisihKeluar > 0
                        ? Colors.red.withOpacity(0.07)
                        : const Color(0xFFE1F5EE),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        selisihKeluar > 0
                            ? Icons.trending_up
                            : Icons.trending_down,
                        color: selisihKeluar > 0
                            ? Colors.red.shade600
                            : const Color(0xFF0F6E56),
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        bulanLaluKeluar == 0
                            ? "Belum ada data bulan lalu"
                            : selisihKeluar > 0
                            ? "Lebih boros ${pctChange.abs()}% dari bulan lalu"
                            : selisihKeluar < 0
                            ? "Lebih hemat ${pctChange.abs()}% dari bulan lalu"
                            : "Sama dengan bulan lalu",
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: selisihKeluar > 0
                              ? Colors.red.shade600
                              : const Color(0xFF0F6E56),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── Kategori Paling Boros ────────────────────────────────────────
          _SeksiLabel(label: "KATEGORI PALING BOROS"),
          const SizedBox(height: 10),
          if (sortedKat.isEmpty)
            _EmptyInsight(text: "Belum ada pengeluaran bulan ini")
          else
            Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E2235) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
                ),
                boxShadow: isDark
                    ? []
                    : [
                        BoxShadow(
                          color: Colors.grey.shade100,
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ...sortedKat.map((e) {
                    final catInfo = getCategoryInfo(e.key);
                    final catColor = catInfo != null
                        ? Color(catInfo['color'])
                        : Colors.grey;
                    final icon = catInfo != null
                        ? IconData(catInfo['icon'], fontFamily: 'MaterialIcons')
                        : Icons.category;
                    final maxKat = sortedKat.first.value;
                    final pct = maxKat > 0
                        ? ((e.value / bulanIniKeluar) * 100).toInt()
                        : 0;
                    final isLast = e.key == sortedKat.last.key;
                    return Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: catColor.withOpacity(0.13),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(icon, color: catColor, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        e.key,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                      Text(
                                        rupiah(e.value),
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: catColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: maxKat > 0 ? e.value / maxKat : 0,
                                      color: catColor,
                                      backgroundColor: catColor.withOpacity(
                                        0.1,
                                      ),
                                      minHeight: 5,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    "$pct% dari pengeluaran",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (!isLast) ...[
                          const SizedBox(height: 12),
                          Divider(
                            height: 1,
                            color: isDark
                                ? Colors.grey.shade800
                                : Colors.grey.shade200,
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                    );
                  }),
                ],
              ),
            ),

          const SizedBox(height: 20),

          // ── Hari Paling Boros ────────────────────────────────────────────
          _SeksiLabel(label: "HARI PALING BOROS BULAN INI"),
          const SizedBox(height: 10),
          if (sortedHari.isEmpty)
            _EmptyInsight(text: "Belum ada data")
          else
            Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E2235) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
                ),
                boxShadow: isDark
                    ? []
                    : [
                        BoxShadow(
                          color: Colors.grey.shade100,
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ...sortedHari.map((e) {
                    final maxHari = sortedHari.first.value;
                    final isFirst = e.key == sortedHari.first.key;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 52,
                            child: Text(
                              namaHari[e.key],
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isFirst
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                                color: isFirst
                                    ? Colors.orange.shade700
                                    : (isDark
                                          ? Colors.grey.shade400
                                          : Colors.grey.shade700),
                              ),
                            ),
                          ),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(5),
                              child: LinearProgressIndicator(
                                value: maxHari > 0 ? e.value / maxHari : 0,
                                color: isFirst
                                    ? Colors.orange
                                    : Colors.orange.withOpacity(0.4),
                                backgroundColor: Colors.orange.withOpacity(
                                  0.08,
                                ),
                                minHeight: 18,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            rupiah(e.value),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.orange.shade700,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),

          const SizedBox(height: 20),

          // ── Tren 6 Bulan ─────────────────────────────────────────────────
          _SeksiLabel(label: "TREN 6 BULAN"),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E2235) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
              ),
              boxShadow: isDark
                  ? []
                  : [
                      BoxShadow(
                        color: Colors.grey.shade100,
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                ...List.generate(bulanList.length, (i) {
                  final b = bulanList[i];
                  final m = masukPerBulan[b] ?? 0;
                  final k = keluarPerBulan[b] ?? 0;
                  final maxVal = maxY == 0 ? 1.0 : maxY;
                  final isLast = i == bulanList.length - 1;
                  return Column(
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 52,
                            child: Text(
                              b,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.arrow_downward,
                                      color: const Color(0xFF0F6E56),
                                      size: 11,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: LinearProgressIndicator(
                                          value: (m / maxVal).clamp(0.0, 1.0),
                                          color: const Color(0xFF0F6E56),
                                          backgroundColor: const Color(
                                            0xFFE1F5EE,
                                          ),
                                          minHeight: 14,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.arrow_upward,
                                      color: Colors.red.shade500,
                                      size: 11,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: LinearProgressIndicator(
                                          value: (k / maxVal).clamp(0.0, 1.0),
                                          color: Colors.red.shade400,
                                          backgroundColor: Colors.red
                                              .withOpacity(0.07),
                                          minHeight: 14,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 72,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  m > 0 ? _shortRupiah(m) : '-',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Color(0xFF0F6E56),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  k > 0 ? _shortRupiah(k) : '-',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.red.shade500,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (!isLast) ...[
                        const SizedBox(height: 10),
                        Divider(
                          height: 1,
                          color: isDark
                              ? Colors.grey.shade800
                              : Colors.grey.shade200,
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  );
                }),
              ],
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }

  String _shortRupiah(int n) {
    if (n >= 1000000) return 'Rp ${(n / 1000000).toStringAsFixed(1)}jt';
    if (n >= 1000) return 'Rp ${(n / 1000).toStringAsFixed(0)}rb';
    return rupiah(n);
  }
}

class _SeksiLabel extends StatelessWidget {
  final String label;
  const _SeksiLabel({required this.label});
  @override
  Widget build(BuildContext context) => Text(
    label,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Colors.grey.shade500,
      letterSpacing: 0.6,
    ),
  );
}

class _StatCard extends StatelessWidget {
  final String label, value;
  final Color color;
  final IconData icon;
  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2235) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
        ),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.grey.shade100,
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 14),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyInsight extends StatelessWidget {
  final String text;
  const _EmptyInsight({required this.text});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2235) : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
        ),
      ),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

// ─── Setting Page ─────────────────────────────────────────────────────────────

class SettingPage extends StatelessWidget {
  const SettingPage({super.key});
  @override
  Widget build(BuildContext context) {
    final box = Hive.box('catatuang_db');
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Setting",
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "Kelola preferensi aplikasi",
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                  ),
                ],
              ),
              // Avatar pojok kanan
              StreamBuilder<User?>(
                stream: AuthService.userStream,
                builder: (context, snapshot) {
                  final user = snapshot.data;
                  if (user == null) {
                    return GestureDetector(
                      onTap: () async {
                        final u = await AuthService.signInWithGoogle();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                u != null
                                    ? "Login berhasil! Halo ${u.displayName} 👋"
                                    : "Login dibatalkan",
                              ),
                              backgroundColor: u != null
                                  ? const Color(0xFF0F6E56)
                                  : Colors.grey,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          );
                        }
                      },
                      child: Stack(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: const Color(0xFFE1F5EE),
                            child: const Icon(
                              Icons.person_outline,
                              color: Color(0xFF0F6E56),
                              size: 22,
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: Colors.grey,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return Stack(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundImage: user.photoURL != null
                            ? NetworkImage(user.photoURL!)
                            : null,
                        backgroundColor: const Color(0xFFE1F5EE),
                        child: user.photoURL == null
                            ? const Icon(
                                Icons.person_outline,
                                color: Color(0xFF0F6E56),
                              )
                            : null,
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F6E56),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 20),

          // ── Akun Card (jika login) ──
          StreamBuilder<User?>(
            stream: AuthService.userStream,
            builder: (context, snapshot) {
              final user = snapshot.data;
              if (user == null) return const SizedBox();
              return Column(
                children: [
                  _SectionLabel(label: "AKUN"),
                  const SizedBox(height: 10),
                  _SettingCard(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 20,
                              backgroundImage: user.photoURL != null
                                  ? NetworkImage(user.photoURL!)
                                  : null,
                              backgroundColor: const Color(0xFFE1F5EE),
                              child: user.photoURL == null
                                  ? const Icon(
                                      Icons.person_outline,
                                      color: Color(0xFF0F6E56),
                                      size: 20,
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    user.displayName ?? "User",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    user.email ?? "",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE1F5EE),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                "Aktif",
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF0F6E56),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () async {
                                await AuthService.signOut();
                                if (context.mounted)
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text("Berhasil logout"),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                              },
                              child: Text(
                                "Logout",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.red.shade400,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              );
            },
          ),

          // ── Tampilan ──
          _SectionLabel(label: "TAMPILAN"),
          const SizedBox(height: 10),
          ValueListenableBuilder(
            valueListenable: box.listenable(keys: ['isDark']),
            builder: (context, box, _) {
              final val = box.get('isDark', defaultValue: false) as bool;
              return _SettingCard(
                children: [
                  _SettingToggleRow(
                    icon: val
                        ? Icons.dark_mode_outlined
                        : Icons.light_mode_outlined,
                    iconColor: Colors.indigo.shade400,
                    title: "Dark Mode",
                    subtitle: val
                        ? "Tampilan gelap aktif"
                        : "Tampilan terang aktif",
                    value: val,
                    onChanged: (v) => box.put('isDark', v),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 20),

          // ── Keamanan ──
          _SectionLabel(label: "KEAMANAN"),
          const SizedBox(height: 10),
          _SettingCard(
            children: [
              _SettingArrowRow(
                icon: Icons.lock_outline_rounded,
                iconColor: Colors.blue.shade400,
                title: "PIN & Biometric Lock",
                subtitle: "Proteksi dengan sidik jari atau PIN",
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LockSettingPage()),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // ── Notifikasi ──
          _SectionLabel(label: "NOTIFIKASI"),
          const SizedBox(height: 10),
          ValueListenableBuilder(
            valueListenable: box.listenable(
              keys: ['isReminder', 'reminderHour', 'reminderMinute'],
            ),
            builder: (context, box, _) {
              final isOn = box.get('isReminder', defaultValue: false) as bool;
              final hour = box.get('reminderHour', defaultValue: 20) as int;
              final minute = box.get('reminderMinute', defaultValue: 0) as int;
              final jamStr =
                  "${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}";
              return _SettingCard(
                children: [
                  _SettingToggleRow(
                    icon: Icons.notifications_outlined,
                    iconColor: Colors.orange,
                    title: "Reminder Harian",
                    subtitle: isOn
                        ? "Aktif setiap hari jam $jamStr"
                        : "Nonaktif",
                    value: isOn,
                    onChanged: (v) async {
                      await box.put('isReminder', v);
                      if (v) {
                        await scheduleDailyNotification(
                          hour: hour,
                          minute: minute,
                        );
                        if (context.mounted)
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text("Reminder aktif jam $jamStr 🔔"),
                              backgroundColor: const Color(0xFF0F6E56),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          );
                      } else {
                        await flutterLocalNotificationsPlugin.cancelAll();
                      }
                    },
                  ),
                  if (isOn) ...[
                    Divider(
                      height: 1,
                      color: isDark
                          ? Colors.grey.shade800
                          : Colors.grey.shade200,
                    ),
                    _SettingArrowRow(
                      icon: Icons.access_time_rounded,
                      iconColor: const Color(0xFF0F6E56),
                      title: "Jam Pengingat",
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE1F5EE),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          jamStr,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F6E56),
                            fontSize: 13,
                          ),
                        ),
                      ),
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay(hour: hour, minute: minute),
                          helpText: "Pilih jam pengingat",
                          builder: (context, child) => MediaQuery(
                            data: MediaQuery.of(
                              context,
                            ).copyWith(alwaysUse24HourFormat: true),
                            child: child!,
                          ),
                        );
                        if (picked != null) {
                          await box.put('reminderHour', picked.hour);
                          await box.put('reminderMinute', picked.minute);
                          await scheduleDailyNotification(
                            hour: picked.hour,
                            minute: picked.minute,
                          );
                          final newJam =
                              "${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}";
                          if (context.mounted)
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  "Reminder diperbarui ke jam $newJam ✅",
                                ),
                                backgroundColor: const Color(0xFF0F6E56),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            );
                        }
                      },
                    ),
                  ],
                ],
              );
            },
          ),

          const SizedBox(height: 20),

          // ── Data ──
          _SectionLabel(label: "DATA"),
          const SizedBox(height: 10),
          _SettingCard(
            children: [
              _SettingArrowRow(
                icon: Icons.cloud_upload_outlined,
                iconColor: Colors.blue.shade400,
                title: "Backup ke Cloud",
                subtitle: "Simpan data ke Google Drive",
                onTap: () async {
                  await AuthService.backupToCloud();
                  final lastBackup = await AuthService.getLastBackupTime();
                  if (context.mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          "Backup berhasil! ☁️ ${lastBackup != null ? DateFormat('dd MMM yyyy HH:mm', 'id_ID').format(lastBackup) : ''}",
                        ),
                        backgroundColor: Colors.blue,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    );
                },
              ),
              Divider(
                height: 1,
                color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
              ),
              _SettingArrowRow(
                icon: Icons.cloud_download_outlined,
                iconColor: Colors.orange,
                title: "Restore dari Cloud",
                subtitle: "Pulihkan data dari backup",
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text("Restore dari Cloud"),
                      content: const Text(
                        "Data lokal akan diganti. Lanjutkan?",
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: const Text("Batal"),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(d, true),
                          child: const Text("Restore"),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true) return;
                  final success = await AuthService.restoreFromCloud();
                  if (context.mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          success
                              ? "Data berhasil di-restore ✅"
                              : "Belum ada backup di cloud",
                        ),
                        backgroundColor: success
                            ? const Color(0xFF0F6E56)
                            : Colors.red,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    );
                },
              ),
              Divider(
                height: 1,
                color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
              ),
              _SettingArrowRow(
                icon: Icons.upload_file_outlined,
                iconColor: Colors.teal,
                title: "Backup Lokal",
                subtitle: "Export data ke file JSON",
                onTap: () => backupData(context),
              ),
              Divider(
                height: 1,
                color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
              ),
              _SettingArrowRow(
                icon: Icons.download_outlined,
                iconColor: Colors.deepOrange,
                title: "Restore Lokal",
                subtitle: "Import data dari file backup",
                onTap: () => restoreData(context),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // ── Kategori ──
          _SectionLabel(label: "KATEGORI"),
          const SizedBox(height: 10),
          _SettingCard(
            children: [
              _SettingArrowRow(
                icon: Icons.grid_view_rounded,
                iconColor: Colors.purple.shade400,
                title: "Kelola Kategori",
                subtitle: "Tambah, edit, atau hapus kategori",
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const KategoriPage()),
                ),
              ),
            ],
          ),

          const SizedBox(height: 36),
          Center(
            child: Text(
              "CatatUang v1.0.0",
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              "Made with by Ndragood",
              style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});
  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Colors.grey.shade500,
        letterSpacing: 0.6,
      ),
    );
  }
}

class _SettingCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingCard({required this.children});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2235) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
        ),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.grey.shade100,
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Column(children: children),
    );
  }
}

class _SettingToggleRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SettingToggleRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFF0F6E56),
          ),
        ],
      ),
    );
  }
}

class _SettingArrowRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;
  const _SettingArrowRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            trailing ??
                Icon(
                  Icons.chevron_right,
                  color: Colors.grey.shade400,
                  size: 20,
                ),
          ],
        ),
      ),
    );
  }
}

// ─── Lock Setting Page ────────────────────────────────────────────────────────

class LockSettingPage extends StatefulWidget {
  const LockSettingPage({super.key});
  @override
  State<LockSettingPage> createState() => _LockSettingPageState();
}

class _LockSettingPageState extends State<LockSettingPage> {
  bool _lockEnabled = false;
  String _lockType = 'pin';
  bool _biometricAvailable = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await LockService.isLockEnabled();
    final type = await LockService.getLockType();
    final bio = await LockService.isBiometricAvailable();
    setState(() {
      _lockEnabled = enabled;
      _lockType = type;
      _biometricAvailable = bio;
      _loading = false;
    });
  }

  void _showSetPinDialog({bool isChange = false}) {
    String pin1 = '', pin2 = '';
    int step = 1;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          return AlertDialog(
            title: Text(
              step == 1
                  ? (isChange ? "Masukkan PIN baru" : "Buat PIN")
                  : "Konfirmasi PIN",
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  step == 1 ? "Masukkan 6 digit PIN" : "Ulangi PIN kamu",
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                ),
                const SizedBox(height: 20),
                // PIN dots
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(6, (i) {
                    final current = step == 1 ? pin1 : pin2;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < current.length
                            ? Colors.green
                            : Colors.grey.shade300,
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 20),
                // Numpad
                ...[
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                ].map(
                  (row) => Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: row
                        .map(
                          (k) => GestureDetector(
                            onTap: () => setS(() {
                              if (step == 1 && pin1.length < 6) pin1 += k;
                              if (step == 2 && pin2.length < 6) pin2 += k;
                            }),
                            child: Container(
                              margin: const EdgeInsets.all(6),
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  k,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(width: 68),
                    GestureDetector(
                      onTap: () => setS(() {
                        if (step == 1 && pin1.length < 6) pin1 += '0';
                        if (step == 2 && pin2.length < 6) pin2 += '0';
                      }),
                      child: Container(
                        margin: const EdgeInsets.all(6),
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: const Center(
                          child: Text(
                            '0',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setS(() {
                        if (step == 1 && pin1.isNotEmpty)
                          pin1 = pin1.substring(0, pin1.length - 1);
                        if (step == 2 && pin2.isNotEmpty)
                          pin2 = pin2.substring(0, pin2.length - 1);
                      }),
                      child: Container(
                        margin: const EdgeInsets.all(6),
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.backspace_outlined),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Batal"),
              ),
              ElevatedButton(
                onPressed: () async {
                  final current = step == 1 ? pin1 : pin2;
                  if (current.length < 6) return;
                  if (step == 1) {
                    setS(() => step = 2);
                  } else {
                    if (pin1 != pin2) {
                      setS(() {
                        pin2 = '';
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("PIN tidak cocok, coba lagi"),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    await LockService.setPin(pin1);
                    await LockService.setLockType('pin');
                    await LockService.setLockEnabled(true);
                    setState(() {
                      _lockEnabled = true;
                      _lockType = 'pin';
                    });
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("PIN berhasil diset ✅"),
                        backgroundColor: Colors.green,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
                child: Text(step == 1 ? "Lanjut" : "Simpan"),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text("Keamanan App")),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Status lock
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _lockEnabled
                        ? Colors.green.withOpacity(0.1)
                        : Colors.grey.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _lockEnabled
                          ? Colors.green.withOpacity(0.3)
                          : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _lockEnabled ? Icons.lock : Icons.lock_open,
                        color: _lockEnabled ? Colors.green : Colors.grey,
                        size: 28,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _lockEnabled
                                  ? "App terkunci"
                                  : "App tidak terkunci",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: _lockEnabled
                                    ? Colors.green
                                    : Colors.grey,
                              ),
                            ),
                            Text(
                              _lockEnabled
                                  ? "Tipe: ${_lockType == 'biometric' ? 'Sidik Jari' : 'PIN 6 digit'}"
                                  : "Aktifkan PIN atau biometric",
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: _lockEnabled,
                        activeColor: Colors.green,
                        onChanged: (v) async {
                          if (v) {
                            _showSetPinDialog();
                          } else {
                            await LockService.setLockEnabled(false);
                            await LockService.clearAll();
                            setState(() => _lockEnabled = false);
                          }
                        },
                      ),
                    ],
                  ),
                ),

                if (_lockEnabled) ...[
                  const SizedBox(height: 20),
                  const Text(
                    "Tipe Kunci",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 10),

                  // PIN option
                  _SettingCard(
                    children: [
                      _SettingArrowRow(
                        icon: Icons.dialpad,
                        iconColor: Colors.blue,
                        title: "PIN 6 Digit",
                        subtitle: "Masukkan 6 angka untuk membuka",
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_lockType == 'pin')
                              const Icon(
                                Icons.check_circle,
                                color: Colors.green,
                                size: 20,
                              ),
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: () => _showSetPinDialog(isChange: true),
                      ),
                      if (_biometricAvailable) ...[
                        Divider(
                          height: 1,
                          color: isDark
                              ? Colors.grey.shade800
                              : Colors.grey.shade200,
                        ),
                        _SettingArrowRow(
                          icon: Icons.fingerprint,
                          iconColor: Colors.green,
                          title: "Sidik Jari / Face ID",
                          subtitle: "Buka dengan biometric",
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_lockType == 'biometric')
                                const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                  size: 20,
                                ),
                              const SizedBox(width: 4),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () async {
                            final ok =
                                await LockService.authenticateWithBiometric();
                            if (ok) {
                              await LockService.setLockType('biometric');
                              setState(() => _lockType = 'biometric');
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text("Biometric lock aktif ✅"),
                                  backgroundColor: Colors.green,
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ],
                  ),

                  const SizedBox(height: 20),
                  _SettingCard(
                    children: [
                      _SettingArrowRow(
                        icon: Icons.refresh,
                        iconColor: Colors.orange,
                        title: "Ganti PIN",
                        subtitle: "Ubah PIN kamu",
                        onTap: () => _showSetPinDialog(isChange: true),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}

// ─── Kategori Page (Tambah/Edit/Hapus) ───────────────────────────────────────

class KategoriPage extends StatefulWidget {
  const KategoriPage({super.key});
  @override
  State<KategoriPage> createState() => _KategoriPageState();
}

class _KategoriPageState extends State<KategoriPage> {
  final box = Hive.box('catatuang_db');

  List<Map> getKategori() {
    return (box.get('kategori', defaultValue: []) as List).cast<Map>();
  }

  void _simpanKategori(List<Map> list) {
    box.put('kategori', list.map((e) => Map<String, dynamic>.from(e)).toList());
    setState(() {});
  }

  void _showDialog({Map? existing, int? index}) {
    final namaC = TextEditingController(text: existing?['nama'] ?? '');
    final budgetC = TextEditingController(
      text: existing != null && existing['budget'] > 0
          ? NumberFormat.decimalPattern('id_ID').format(existing['budget'])
          : '',
    );
    IconData selectedIcon = existing != null
        ? IconData(existing['icon'], fontFamily: 'MaterialIcons')
        : Icons.category;
    Color selectedColor = existing != null
        ? Color(existing['color'])
        : Colors.blue;

    final icons = [
      Icons.restaurant,
      Icons.directions_car,
      Icons.shopping_bag,
      Icons.sports_esports,
      Icons.work,
      Icons.home,
      Icons.local_hospital,
      Icons.school,
      Icons.flight,
      Icons.fitness_center,
      Icons.movie,
      Icons.pets,
    ];
    final colors = [
      Colors.orange,
      Colors.blue,
      Colors.pink,
      Colors.purple,
      Colors.green,
      Colors.red,
      Colors.teal,
      Colors.indigo,
      Colors.amber,
      Colors.cyan,
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(existing == null ? "Tambah Kategori" : "Edit Kategori"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: namaC,
                  decoration: const InputDecoration(labelText: "Nama Kategori"),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: budgetC,
                  keyboardType: TextInputType.number,
                  inputFormatters: [ThousandSeparatorFormatter()],
                  decoration: const InputDecoration(
                    labelText: "Budget (opsional)",
                    prefixText: "Rp ",
                  ),
                ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Icon:",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: icons
                      .map(
                        (ic) => GestureDetector(
                          onTap: () => setS(() => selectedIcon = ic),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: selectedIcon == ic
                                  ? Colors.green.shade100
                                  : null,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: selectedIcon == ic
                                    ? Colors.green
                                    : Colors.grey.shade300,
                              ),
                            ),
                            child: Icon(ic, size: 24),
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Warna:",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: colors
                      .map(
                        (cl) => GestureDetector(
                          onTap: () => setS(() => selectedColor = cl),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: cl,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selectedColor == cl
                                    ? Colors.black
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Batal"),
            ),
            ElevatedButton(
              onPressed: () {
                if (namaC.text.isEmpty) return;
                final rawBudget = budgetC.text.replaceAll(
                  RegExp(r'[^0-9]'),
                  '',
                );
                final budget = rawBudget.isEmpty ? 0 : int.parse(rawBudget);
                final newKat = {
                  "nama": namaC.text,
                  "budget": budget,
                  "icon": selectedIcon.codePoint,
                  "color": selectedColor.value,
                };
                final list = getKategori();
                if (index != null)
                  list[index] = newKat;
                else
                  list.add(newKat);
                _simpanKategori(list);
                Navigator.pop(ctx);
              },
              child: const Text("Simpan"),
            ),
          ],
        ),
      ),
    );
  }

  void _hapus(int index) {
    final list = getKategori();
    list.removeAt(index);
    _simpanKategori(list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Kelola Kategori"),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showDialog(),
          ),
        ],
      ),
      body: ValueListenableBuilder(
        valueListenable: box.listenable(keys: ['kategori']),
        builder: (context, box, _) {
          final list = getKategori();
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) {
              final c = list[i];
              return ListTile(
                leading: Icon(
                  IconData(c['icon'], fontFamily: 'MaterialIcons'),
                  color: Color(c['color']),
                ),
                title: Text(c['nama']),
                subtitle: (c['budget'] as int) > 0
                    ? Text("Budget: ${rupiah(c['budget'] as int)}")
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      onPressed: () => _showDialog(existing: c, index: i),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete,
                        size: 20,
                        color: Colors.red,
                      ),
                      onPressed: () => _hapus(i),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ─── Unused widgets ───────────────────────────────────────────────────────────

class BudgetCard extends StatelessWidget {
  final String title;
  final int used, limit;
  final IconData icon;
  final Color color;
  final bool isDark;
  const BudgetCard({
    super.key,
    required this.title,
    required this.used,
    required this.limit,
    required this.icon,
    required this.color,
    required this.isDark,
  });
  @override
  Widget build(BuildContext context) => const SizedBox();
}

class SavingGoalCard extends StatelessWidget {
  final String title;
  final int current, target;
  const SavingGoalCard({
    super.key,
    required this.title,
    required this.current,
    required this.target,
  });
  @override
  Widget build(BuildContext context) => const SizedBox();
}
