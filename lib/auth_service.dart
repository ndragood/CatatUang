import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';

class AuthService {
  static bool get isInitialized => Firebase.apps.isNotEmpty;

  static FirebaseAuth? get _auth => isInitialized ? FirebaseAuth.instance : null;
  static GoogleSignIn get _googleSignIn => GoogleSignIn();
  static FirebaseFirestore? get _firestore => isInitialized ? FirebaseFirestore.instance : null;

  // Stream user state
  static Stream<User?> get userStream =>
      isInitialized ? FirebaseAuth.instance.authStateChanges() : Stream.value(null);
  static User? get currentUser =>
      isInitialized ? FirebaseAuth.instance.currentUser : null;

  // ── Login Google ──────────────────────────────────────────────────────────
  static Future<User?> signInWithGoogle() async {
    if (!isInitialized || _auth == null) return null;
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return null; // user cancel

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential = await _auth!.signInWithCredential(credential);
      return userCredential.user;
    } catch (e) {
      return null;
    }
  }

  // ── Logout ────────────────────────────────────────────────────────────────
  static Future<void> signOut() async {
    if (!isInitialized || _auth == null) return;
    await _googleSignIn.signOut();
    await _auth!.signOut();
  }

  // ── Backup ke Firestore ───────────────────────────────────────────────────
  static Future<void> backupToCloud() async {
    final user = currentUser;
    if (user == null || _firestore == null) return;

    final box = Hive.box('catatuang_db');
    final Map<String, dynamic> data = {};

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

    await _firestore!
        .collection('users')
        .doc(user.uid)
        .collection('backup')
        .doc('data')
        .set({
      'data': data,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ── Restore dari Firestore ────────────────────────────────────────────────
  static Future<bool> restoreFromCloud() async {
    final user = currentUser;
    if (user == null || _firestore == null) return false;

    try {
      final doc = await _firestore!
          .collection('users')
          .doc(user.uid)
          .collection('backup')
          .doc('data')
          .get();

      if (!doc.exists || doc.data() == null) return false;

      final Map<String, dynamic> data =
      Map<String, dynamic>.from(doc.data()!['data']);
      final box = Hive.box('catatuang_db');
      await box.clear();

      for (var entry in data.entries) {
        final key = int.tryParse(entry.key) ?? entry.key;
        await box.put(key, entry.value);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  // ── Cek kapan terakhir backup ─────────────────────────────────────────────
  static Future<DateTime?> getLastBackupTime() async {
    final user = currentUser;
    if (user == null || _firestore == null) return null;

    try {
      final doc = await _firestore!
          .collection('users')
          .doc(user.uid)
          .collection('backup')
          .doc('data')
          .get();

      if (!doc.exists) return null;
      final ts = doc.data()?['updatedAt'] as Timestamp?;
      return ts?.toDate();
    } catch (e) {
      return null;
    }
  }
}