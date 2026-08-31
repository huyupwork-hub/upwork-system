import 'package:flutter/cupertino.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../data/repositories.dart';
import 'theme.dart';

/// Sign in, per the approved Figma direction: white ground, shield mark, one
/// grouped card, one filled action.
///
/// The mockup also shows "Sign in with Face ID" and a password-reset link.
/// Neither is in SPEC.md, so neither is implemented — biometric auth and
/// password recovery are product features, not visual direction (D13).
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.auth});

  final AuthRepository auth;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;

    final email = _email.text.trim();
    if (email.isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.auth.signIn(email: email, password: _password.text);
      // Success is observed through the auth stream; nothing to do here.
    } on AuthException catch (e) {
      // Surface the real reason. A failed sign-in is never reported as success.
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.card,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: AppColors.blueTint,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      alignment: Alignment.center,
                      child: const ShieldMark(size: 44),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'FieldProof',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: AppColors.label,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Field inspection, simplified.',
                      style: TextStyle(fontSize: 15, color: AppColors.label2),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
              child: Column(
                children: [
                  InsetCard(
                    horizontalMargin: 20,
                    separatorInset: 106,
                    children: [
                      FormRow(
                        label: 'Email',
                        controller: _email,
                        placeholder: 'you@example.com',
                        keyboardType: TextInputType.emailAddress,
                        labelWidth: 90,
                        height: AppMetrics.signInRowHeight,
                      ),
                      FormRow(
                        label: 'Password',
                        controller: _password,
                        placeholder: 'Required',
                        obscureText: true,
                        labelWidth: 90,
                        height: AppMetrics.signInRowHeight,
                      ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Text(
                        _error!,
                        key: const Key('signin-error'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.red,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: PrimaryButton(
                      label: 'Sign In',
                      busy: _busy,
                      onPressed: _submit,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
