import 'package:firebase_auth/firebase_auth.dart';

class CustomerPhoneAuthService {
  CustomerPhoneAuthService({FirebaseAuth? firebaseAuth})
      : _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance;

  final FirebaseAuth _firebaseAuth;

  Future<void> sendOtp({
    required String phone,
    required void Function(String verificationId) onCodeSent,
    required void Function(String message) onFailure,
    required Future<void> Function(String idToken) onVerified,
  }) {
    return _firebaseAuth.verifyPhoneNumber(
      phoneNumber: '+91$phone',
      timeout: const Duration(seconds: 60),
      verificationCompleted: (credential) async {
        try {
          final result = await _firebaseAuth.signInWithCredential(credential);
          final token = await result.user?.getIdToken();
          if (token == null) {
            throw StateError('Firebase did not return an ID token.');
          }
          await onVerified(token);
        } catch (error) {
          onFailure(error.toString());
        }
      },
      verificationFailed: (error) =>
          onFailure(error.message ?? 'Could not send the verification code.'),
      codeSent: (verificationId, _) => onCodeSent(verificationId),
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  Future<String> verifyOtp(
      {required String verificationId, required String code}) async {
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: code,
    );
    final result = await _firebaseAuth.signInWithCredential(credential);
    final token = await result.user?.getIdToken();
    if (token == null) throw StateError('Firebase did not return an ID token.');
    return token;
  }

  Future<void> signOut() => _firebaseAuth.signOut();
}
