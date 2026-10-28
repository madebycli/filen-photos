import 'dart:async';

import 'package:email_validator/email_validator.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:filen_sdk/filen_sdk.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/account_configured_event.dart';
import 'package:photos/filen/filen_account.dart';
import 'package:photos/filen/ui/onboarding_page_scaffold.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Sign-in with a Filen account, in Ente's onboarding look. Email and password go straight to
/// Filen's SDK (nothing is sent to Ente); a 2FA field appears when the account requires it.
class FilenLoginPage extends StatefulWidget {
  const FilenLoginPage({super.key});

  @override
  State<FilenLoginPage> createState() => _FilenLoginPageState();
}

class _FilenLoginPageState extends State<FilenLoginPage> {
  static final _logger = Logger('FilenLoginPage');
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _needsCode = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      EmailValidator.validate(_email.text.trim()) &&
      _password.text.isNotEmpty &&
      (!_needsCode || _code.text.trim().length >= 6);

  @override
  Widget build(BuildContext context) {
    return OnboardingPageScaffold(
      title: 'Log in to Filen',
      illustration: OnboardingIllustration.login,
      body: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextInputComponent(
              key: const ValueKey('filenEmailField'),
              label: context.strings.email,
              hintText: context.strings.emailHint,
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              autocorrect: false,
              autofocus: true,
              isRequired: true,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 16),
            TextInputComponent(
              key: const ValueKey('filenPasswordField'),
              label: context.strings.password,
              hintText: context.strings.enterYourPasswordHint,
              controller: _password,
              isPasswordInput: true,
              autofillHints: const [AutofillHints.password],
              autocorrect: false,
              isRequired: true,
              onChanged: (_) => setState(() => _error = null),
              onSubmit: (_) => _submit(),
            ),
            if (_needsCode) ...[
              const SizedBox(height: 16),
              TextInputComponent(
                key: const ValueKey('filenCodeField'),
                label: 'Two-factor code',
                hintText: '123456',
                controller: _code,
                keyboardType: TextInputType.number,
                autocorrect: false,
                autofocus: true,
                isRequired: true,
                onChanged: (_) => setState(() => _error = null),
                onSubmit: (_) => _submit(),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        ButtonComponent(
          key: const ValueKey('filenLogInButton'),
          label: context.strings.logInLabel,
          shouldShowSuccessState: false,
          isDisabled: !_canSubmit || _busy,
          onTap: _canSubmit && !_busy ? _submit : null,
        ),
        OnboardingAccountPrompt(
          question: "Don't have a Filen account?",
          actionLabel: context.strings.signUp,
          onTap: () => launchUrlString(
            'https://app.filen.io/#/register',
            mode: LaunchMode.externalApplication,
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_busy || !_canSubmit) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FilenAccount.instance.signIn(
        email: _email.text,
        password: _password.text,
        twoFactorCode: _needsCode ? _code.text.trim() : null,
      );
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      Bus.instance.fire(AccountConfiguredEvent());
    } on FilenException catch (e) {
      _logger.info('Filen login failed: ${e.code}');
      if (!mounted) return;
      setState(() {
        switch (e.code) {
          case 'TWO_FACTOR_REQUIRED':
            _needsCode = true;
            _error = 'This account uses two-factor authentication.';
          case 'TWO_FACTOR_WRONG':
            _error = 'The two-factor code is wrong.';
          case 'BAD_CREDENTIALS':
            _error = 'Wrong email or password.';
          case 'NETWORK':
            _error = 'Could not reach Filen. Check your connection.';
          default:
            _error = 'Login failed (${e.code}).';
        }
      });
    } catch (e, s) {
      _logger.severe('Unexpected login failure', e, s);
      if (mounted) setState(() => _error = 'Login failed unexpectedly.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
