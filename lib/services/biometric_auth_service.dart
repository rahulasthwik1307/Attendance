import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class BiometricAuthService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );
  static const _keyRoll = 'biometric_roll';
  static const _keyPass = 'biometric_pass';
  static const _keySaved = 'biometric_saved';

  static final LocalAuthentication _localAuth = LocalAuthentication();

  // ── Check if device supports biometric ──────────────────
  static Future<bool> isAvailable() async {
    try {
      final bool canCheck = await _localAuth.canCheckBiometrics;
      final bool isDeviceSupported = await _localAuth.isDeviceSupported();
      if (!canCheck || !isDeviceSupported) return false;
      final List<BiometricType> available = await _localAuth
          .getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // ── Check if credentials are saved ──────────────────────
  static Future<bool> hasCredentials() async {
    try {
      final saved = await _storage.read(key: _keySaved);
      return saved == 'true';
    } catch (_) {
      return false;
    }
  }

  // ── Save credentials after successful manual sign in ────
  static Future<void> saveCredentials(
    String rollNumber,
    String password,
  ) async {
    try {
      await _storage.write(key: _keyRoll, value: rollNumber);
      await _storage.write(key: _keyPass, value: password);
      await _storage.write(key: _keySaved, value: 'true');
    } catch (_) {}
  }

  // ── Clear saved credentials ──────────────────────────────
  static Future<void> clearCredentials() async {
    try {
      await _storage.delete(key: _keyRoll);
      await _storage.delete(key: _keyPass);
      await _storage.delete(key: _keySaved);
    } catch (_) {}
  }

  // ── Authenticate with biometric ──────────────────────────
  // Returns roll number + password if success, null if failed/cancelled
  static Future<Map<String, String>?> authenticate() async {
    try {
      final bool authenticated = await _localAuth.authenticate(
        localizedReason: 'Scan your fingerprint to sign in',
      );
      if (!authenticated) return null;

      final roll = await _storage.read(key: _keyRoll);
      final pass = await _storage.read(key: _keyPass);

      if (roll == null || pass == null) return null;
      return {'roll': roll, 'password': pass};
    } catch (_) {
      return null;
    }
  }
}
