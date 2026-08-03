import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LockService {
  static final LocalAuthentication _auth = LocalAuthentication();
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _pinKey = 'app_pin';
  static const String _lockEnabledKey = 'lock_enabled';
  static const String _lockTypeKey = 'lock_type';

  static Future<bool> isBiometricAvailable() async {
    try {
      final bool canAuth = await _auth.canCheckBiometrics;
      final bool isDeviceSupported = await _auth.isDeviceSupported();
      return canAuth && isDeviceSupported;
    } catch (_) { return false; }
  }

  static Future<List<BiometricType>> getAvailableBiometrics() async {
    try { return await _auth.getAvailableBiometrics(); } catch (_) { return []; }
  }

  static Future<bool> authenticateWithBiometric() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Buka CatatUang dengan sidik jari',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
    } catch (_) { return false; }
  }

  static Future<void> setPin(String pin) async => await _storage.write(key: _pinKey, value: pin);
  static Future<String?> getPin() async => await _storage.read(key: _pinKey);
  static Future<bool> verifyPin(String input) async {
    final String? stored = await getPin();
    return stored != null && stored == input;
  }
  static Future<void> deletePin() async => await _storage.delete(key: _pinKey);
  static Future<void> setLockEnabled(bool enabled) async => await _storage.write(key: _lockEnabledKey, value: enabled.toString());
  static Future<bool> isLockEnabled() async { final val = await _storage.read(key: _lockEnabledKey); return val == 'true'; }
  static Future<void> setLockType(String type) async => await _storage.write(key: _lockTypeKey, value: type);
  static Future<String> getLockType() async => await _storage.read(key: _lockTypeKey) ?? 'pin';
  static Future<void> clearAll() async => await _storage.deleteAll();
}

// ── Lock Screen Widget ────────────────────────────────────────────────────────

class LockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const LockScreen({super.key, required this.onUnlocked});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _input = '';
  bool _error = false;
  bool _loading = true;
  String _lockType = 'pin';
  bool _biometricAvailable = false;

  @override
  void initState() { super.initState(); _init(); }

  Future<void> _init() async {
    _lockType = await LockService.getLockType();
    _biometricAvailable = await LockService.isBiometricAvailable();
    setState(() => _loading = false);
    if (_lockType == 'biometric' && _biometricAvailable) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    final success = await LockService.authenticateWithBiometric();
    if (success && mounted) widget.onUnlocked();
  }

  void _onKey(String key) {
    if (_input.length >= 6) return;
    setState(() { _input += key; _error = false; });
    if (_input.length == 6) _verify();
  }

  void _onDelete() {
    if (_input.isEmpty) return;
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  Future<void> _verify() async {
    final ok = await LockService.verifyPin(_input);
    if (ok) { widget.onUnlocked(); }
    else { setState(() { _error = true; _input = ''; }); }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 24),
              // Logo
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), shape: BoxShape.circle),
                child: const Icon(Icons.lock_outline, color: Colors.green, size: 44),
              ),
              const SizedBox(height: 16),
              const Text("Masukkan PIN", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text("Buka CatatUang kamu", style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
              const SizedBox(height: 24),

              // PIN dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(6, (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  width: 16, height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _input.length
                        ? (_error ? Colors.red : Colors.green)
                        : (isDark ? Colors.grey.shade700 : Colors.grey.shade300),
                  ),
                )),
              ),

              if (_error) ...[
                const SizedBox(height: 10),
                Text("PIN salah, coba lagi", style: TextStyle(color: Colors.red.shade400, fontSize: 13)),
              ],

              const SizedBox(height: 24),

              // Numpad
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Column(children: [
                  ...[['1','2','3'], ['4','5','6'], ['7','8','9']].map((row) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: row.map((k) => _NumKey(label: k, onTap: () => _onKey(k))).toList(),
                    ),
                  )),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    _lockType == 'biometric' && _biometricAvailable
                        ? _NumKey(icon: Icons.fingerprint, onTap: _tryBiometric)
                        : const SizedBox(width: 72),
                    _NumKey(label: '0', onTap: () => _onKey('0')),
                    _NumKey(icon: Icons.backspace_outlined, onTap: _onDelete),
                  ]),
                ]),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _NumKey extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;
  const _NumKey({this.label, this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72, height: 72,
        decoration: BoxDecoration(
          color: isDark ? Colors.grey.shade700 : const Color(0xFFE0E0E0),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: label != null
              ? Text(label!, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w500, color: isDark ? Colors.white : Colors.black))
              : Icon(icon, size: 24, color: isDark ? Colors.white : Colors.black),
        ),
      ),
    );
  }
}