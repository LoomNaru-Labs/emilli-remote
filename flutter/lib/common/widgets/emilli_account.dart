// Emilli Remote: the first screen before sign-in ("가입" and "로그인"), sign-up inside the app,
// "remove this PC from my account", and the per-PC switch for same-account connections.
// The account server is the one the setup configured (bind.mainGetApiServer()).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/user_model.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../utils/http_service.dart' as http;
import './dialog.dart';
import './login.dart';

const String kEmilliAccountAccess = 'emilli-account-access';

/// An invite link (or just its token) or the shared sign-up code, as people paste them.
Map<String, String> emilliSignupSecret(String raw) {
  final t = raw.trim();
  final i = t.indexOf('#i=');
  if (i >= 0) {
    return {'invite': t.substring(i + 3).trim()};
  }
  // Invite tokens are 43 characters; sign-up codes are 12 letters, maybe in groups.
  if (t.length >= 32 && !t.contains(' ')) {
    return {'invite': t};
  }
  return {'code': t};
}

Widget emilliStartCard(BuildContext context) {
  final theme = Theme.of(context);
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 16, right: 12, bottom: 8),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: theme.dividerColor),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(translate('emilli_start_title'),
            style: theme.textTheme.titleLarge),
        const SizedBox(height: 10),
        Text(translate('emilli_start_body'),
            style: theme.textTheme.bodyMedium),
        if (bind.mainGetLocalOption(key: kEmilliSignedOut) == 'Y') ...[
          const SizedBox(height: 10),
          Text(translate('emilli_signed_out_tip'),
              key: const ValueKey('emilli-signed-out'),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: Colors.red.shade700)),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            ElevatedButton(
              key: const ValueKey('emilli-signup'),
              onPressed: () => emilliSignupDialog(),
              child: Text(translate('emilli_signup')).paddingSymmetric(
                  horizontal: 18, vertical: 10),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              key: const ValueKey('emilli-signin'),
              onPressed: () => loginDialog(),
              child: Text(translate('emilli_signin')).paddingSymmetric(
                  horizontal: 18, vertical: 10),
            ),
          ],
        ),
      ],
    ),
  );
}

Future<void> emilliSignupDialog() async {
  final secret = TextEditingController();
  final name = TextEditingController();
  final pw1 = TextEditingController();
  final pw2 = TextEditingController();
  String? secretMsg;
  String? nameMsg;
  String? pwMsg;
  var inProgress = false;

  final ok = await gFFI.dialogManager.show<bool>((setState, close, context) {
    Future<void> submit() async {
      if (inProgress) return;
      setState(() {
        secretMsg = null;
        nameMsg = null;
        pwMsg = null;
      });
      if (secret.text.trim().isEmpty) {
        setState(() => secretMsg = translate('emilli_signup_missing'));
        return;
      }
      if (name.text.trim().isEmpty) {
        setState(() => nameMsg = translate('emilli_signup_missing'));
        return;
      }
      if (pw1.text.isEmpty) {
        setState(() => pwMsg = translate('emilli_signup_missing'));
        return;
      }
      if (pw1.text != pw2.text) {
        setState(() => pwMsg = translate('emilli_signup_mismatch'));
        return;
      }
      setState(() => inProgress = true);
      final user = name.text.trim().toLowerCase();
      try {
        final url = await bind.mainGetApiServer();
        final body = <String, String>{'username': user, 'password': pw1.text};
        body.addAll(emilliSignupSecret(secret.text));
        final resp = await http.post(Uri.parse('$url/api/signup'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body));
        if (resp.statusCode != 200) {
          var error = 'HTTP ${resp.statusCode}';
          try {
            final data = jsonDecode(decode_http_response(resp));
            if (data is Map && data['error'] != null) {
              error = data['error'].toString();
            }
          } catch (_) {}
          setState(() {
            inProgress = false;
            pwMsg = error;
          });
          return;
        }
        // The account exists: sign this PC in with it, as the sign-in dialog does.
        final login = await gFFI.userModel.login(LoginRequest(
            username: user,
            password: pw1.text,
            id: await bind.mainGetMyId(),
            uuid: await bind.mainGetUuid(),
            autoLogin: true,
            type: HttpType.kAuthReqTypeAccount));
        if (login.access_token != null) {
          await bind.mainSetLocalOption(
              key: 'access_token', value: login.access_token!);
          await bind.mainSetLocalOption(
              key: 'user_info', value: jsonEncode(login.user ?? {}));
        }
        close(true);
      } on RequestException catch (err) {
        setState(() {
          inProgress = false;
          pwMsg = translate(err.cause);
        });
      } catch (err) {
        setState(() {
          inProgress = false;
          pwMsg = '$err';
        });
      }
    }

    return CustomAlertDialog(
      title: Text(translate('emilli_signup_title')),
      contentBoxConstraints: const BoxConstraints(minWidth: 420, maxWidth: 520),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DialogTextField(
              title: translate('emilli_signup_secret'),
              hintText: translate('emilli_signup_secret_hint'),
              controller: secret,
              errorText: secretMsg),
          DialogTextField(
              title: translate('emilli_signup_name'),
              hintText: translate('emilli_signup_name_hint'),
              prefixIcon: DialogTextField.kUsernameIcon,
              controller: name,
              errorText: nameMsg),
          DialogTextField(
              title: translate('emilli_signup_password'),
              hintText: translate('emilli_signup_password_hint'),
              prefixIcon: DialogTextField.kPasswordIcon,
              obscureText: true,
              controller: pw1),
          DialogTextField(
              title: translate('emilli_signup_password2'),
              prefixIcon: DialogTextField.kPasswordIcon,
              obscureText: true,
              controller: pw2,
              errorText: pwMsg),
          if (inProgress) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        dialogButton('Cancel', onPressed: () => close(false), isOutline: true),
        dialogButton('emilli_signup_button', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: () => close(false),
    );
  });
  if (ok == true) {
    await UserModel.updateOtherModels();
  }
}

/// Takes this PC out of the signed-in account (the server checks the account owns it), then
/// signs out. Another account can then sign in here.
Future<void> emilliReleaseThisPc() async {
  final ok = await gFFI.dialogManager.show<bool>((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate('emilli_release_pc')),
      content: Text(translate('emilli_release_pc_tip')),
      actions: [
        dialogButton('Cancel', onPressed: () => close(false), isOutline: true),
        dialogButton('OK', onPressed: () => close(true)),
      ],
      onSubmit: () => close(true),
      onCancel: () => close(false),
    );
  });
  if (ok != true) return;
  // Signed with this PC's own key in Rust (REMOTE-EASY-3B): "" when done, else a sentence.
  final error = await bind.mainEmilliReleaseThisPc(
      token: bind.mainGetLocalOption(key: 'access_token'));
  if (error.isNotEmpty) {
    showToast(error, timeout: const Duration(seconds: 8));
    return;
  }
  showToast(translate('emilli_release_done'));
  await gFFI.userModel.logOut();
}

/// After a sign-in (or a refresh) succeeds: this PC joins the account, proven by its own key
/// (REMOTE-EASY-3B). Shows the reason when it did not.
Future<void> emilliBindThisPc(String token) async {
  if (token.isEmpty) return;
  final error = await bind.mainEmilliBindThisPc(token: token);
  if (error.isNotEmpty) {
    showToast(error, timeout: const Duration(seconds: 10));
  }
}

const kEmilliSignedOut = 'emilli-signed-out';

/// The account server ended this PC's sign-in (the password was changed, or the administrator
/// signed it out): the first screen says so until the next sign-in.
Future<void> emilliMarkSignedOut() async {
  await bind.mainSetLocalOption(key: kEmilliSignedOut, value: 'Y');
}
