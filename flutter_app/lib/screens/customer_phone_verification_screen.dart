import 'package:flutter/material.dart';

import '../services/app_notification_service.dart';
import '../services/customer_api_service.dart';
import '../services/customer_phone_auth_service.dart';

class CustomerPhoneVerificationScreen extends StatefulWidget {
  const CustomerPhoneVerificationScreen({super.key, required this.api});

  final CustomerApiService api;

  @override
  State<CustomerPhoneVerificationScreen> createState() =>
      _CustomerPhoneVerificationScreenState();
}

class _CustomerPhoneVerificationScreenState
    extends State<CustomerPhoneVerificationScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _auth = CustomerPhoneAuthService();
  String? _verificationId;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final phone = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (!RegExp(r'^[6-9]\d{9}$').hasMatch(phone)) {
      setState(() => _error = 'Enter a valid 10-digit Indian mobile number.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await _auth.sendOtp(
      phone: phone,
      onCodeSent: (id) {
        if (mounted) {
          setState(() {
            _verificationId = id;
            _busy = false;
          });
        }
      },
      onFailure: (message) {
        if (mounted) {
          setState(() {
            _error = message;
            _busy = false;
          });
        }
      },
      onVerified: _finishVerification,
    );
  }

  Future<void> _verifyCode() async {
    final id = _verificationId;
    if (id == null || !RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      setState(() => _error = 'Enter the 6-digit code we sent you.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _finishVerification(
          await _auth.verifyOtp(verificationId: id, code: _code.text.trim()));
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _busy = false;
        });
      }
    }
  }

  Future<void> _finishVerification(String token) async {
    try {
      await widget.api.verifyPhone(firebaseIdToken: token);
      await AppNotificationService.instance.configureCustomer(widget.api);
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final codeStep = _verificationId != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Verify your phone')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(codeStep ? 'Enter the code' : 'Confirm your mobile number',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(codeStep
              ? 'We sent a 6-digit code to +91 ${_phone.text}.'
              : 'We use it to protect bookings and keep you updated.'),
          const SizedBox(height: 24),
          if (!codeStep)
            TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                decoration: const InputDecoration(
                    prefixText: '+91 ', labelText: 'Mobile number')),
          if (codeStep)
            TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                decoration: const InputDecoration(labelText: '6-digit code')),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          const Spacer(),
          FilledButton(
              onPressed: _busy ? null : (codeStep ? _verifyCode : _sendCode),
              child: Text(_busy
                  ? 'Please wait…'
                  : (codeStep ? 'Verify phone' : 'Send code'))),
          if (codeStep)
            TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _verificationId = null;
                          _code.clear();
                        }),
                child: const Text('Use a different number')),
        ]),
      ),
    );
  }
}
