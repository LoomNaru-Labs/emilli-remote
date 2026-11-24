// Emilli Remote (REMOTE-EASY-4): updates from Emilli's own download host. The installed program's
// service-side process checks and installs (src/emilli_update.rs); this file shows its state in
// Settings > About and on the home page, sends the one press, and says once what the last update
// did (done, or put back to the previous version).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

import '../../common.dart';

const String kEmilliAutoUpdate = 'emilli-auto-update';

/// Asks the updater: "state", "check", "install" or "ack". Returns its state ({} when unknown).
Future<Map<String, dynamic>> emilliUpdate(String op) async {
  try {
    final answer = await bind.mainEmilliUpdate(request: jsonEncode({'op': op}));
    final v = jsonDecode(answer);
    if (v is Map<String, dynamic>) return v;
  } catch (_) {}
  return {};
}

String _fill(String key, List<String> values) {
  var text = translate(key);
  for (final v in values) {
    text = text.replaceFirst('{}', v);
  }
  return text;
}

String _notes(Map<String, dynamic> s) {
  final ko = (s['notes_ko'] ?? '').toString();
  final en = (s['notes_en'] ?? '').toString();
  final korean = bind.mainGetLocalOption(key: 'lang') == 'ko' ||
      (bind.mainGetLocalOption(key: 'lang').isEmpty &&
          Get.deviceLocale?.languageCode == 'ko');
  if (korean && ko.isNotEmpty) return ko;
  return en.isNotEmpty ? en : ko;
}

String emilliUpdateErrorText(String code) {
  switch (code) {
    case '':
      return '';
    case 'unreachable':
      return translate('emilli_update_err_unreachable');
    case 'no-rollback':
      return translate('emilli_update_err_no_rollback');
    case 'unsigned':
    case 'bad-signature':
    case 'wrong-app':
    case 'wrong-platform':
    case 'bad-file':
    case 'bad-size':
    case 'bad-hash':
    case 'malformed':
      return translate('emilli_update_err_refused');
    default:
      return translate('emilli_update_err_other');
  }
}

/// The sentence for the last update's result, or null when there is none to show.
String? emilliUpdateResultText(dynamic r) {
  if (r is! Map) return null;
  final from = (r['from'] ?? '').toString();
  final to = (r['to'] ?? '').toString();
  switch (r['result']) {
    case 'updated':
      return _fill('emilli_update_done', [to]);
    case 'rolled_back':
      return _fill('emilli_update_rolled_back', [to, from]);
    case 'failed':
      return translate('emilli_update_failed');
  }
  return null;
}

/// One line for what the updater is doing or found.
String emilliUpdateStatusText(Map<String, dynamic> s) {
  if (s['service'] == false || s['installed'] == false) {
    return translate('emilli_update_not_installed');
  }
  switch (s['busy']) {
    case 'checking':
      return translate('emilli_update_checking');
    case 'downloading':
      return translate('emilli_update_downloading');
    case 'installing':
      return translate('emilli_update_installing');
  }
  switch (s['status']) {
    case 'available':
      return _fill('emilli_update_available', [(s['version'] ?? '').toString()]);
    case 'up-to-date':
      return translate('emilli_update_up_to_date');
    case 'error':
      return emilliUpdateErrorText((s['error'] ?? '').toString());
  }
  final error = (s['error'] ?? '').toString();
  return error.isNotEmpty ? emilliUpdateErrorText(error) : '';
}

/// At start: what the last update did, once (then the updater is told it was shown).
Future<void> emilliShowUpdateResult() async {
  final s = await emilliUpdate('state');
  final r = s['result'];
  if (r is! Map || r['shown'] == 1) return;
  final text = emilliUpdateResultText(r);
  if (text == null) return;
  await gFFI.dialogManager.show<bool>((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate('emilli_update_title')),
      content: Text(text, key: const ValueKey('emilli-update-result')),
      actions: [dialogButton('OK', onPressed: () => close(true))],
      onSubmit: () => close(true),
      onCancel: () => close(true),
    );
  });
  await emilliUpdate('ack');
}

/// Settings > About: version check, the one press, and the automatic switch.
class EmilliUpdateSection extends StatefulWidget {
  const EmilliUpdateSection({Key? key}) : super(key: key);

  @override
  State<EmilliUpdateSection> createState() => _EmilliUpdateSectionState();
}

class _EmilliUpdateSectionState extends State<EmilliUpdateSection> {
  Map<String, dynamic> _s = {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ask('state');
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _ask('state'));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _ask(String op) async {
    final s = await emilliUpdate(op);
    if (mounted) setState(() => _s = s);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usable = _s['service'] != false &&
        _s['installed'] == true &&
        _s['configured'] == true;
    final busy = (_s['busy'] ?? '').toString().isNotEmpty;
    final available = _s['status'] == 'available' && !busy;
    final status = emilliUpdateStatusText(_s);
    final result = emilliUpdateResultText(_s['result']);
    return Column(
      key: const ValueKey('emilli-update'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(translate('emilli_update_title'),
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        if (status.isNotEmpty)
          Text(status, key: const ValueKey('emilli-update-status'))
              .marginSymmetric(vertical: 4),
        if (available && _notes(_s).isNotEmpty)
          Text(_notes(_s), style: theme.textTheme.bodySmall)
              .marginSymmetric(vertical: 2),
        if (usable)
          Row(children: [
            if (available)
              ElevatedButton(
                key: const ValueKey('emilli-update-install'),
                onPressed: () => _ask('install'),
                child: Text(translate('emilli_update_button')),
              ).marginOnly(right: 12),
            OutlinedButton(
              key: const ValueKey('emilli-update-check'),
              onPressed: busy ? null : () => _ask('check'),
              child: Text(translate('emilli_update_check')),
            ),
          ]).marginSymmetric(vertical: 6),
        if (usable)
          Row(children: [
            Checkbox(
              value: _s['auto'] == true,
              onChanged: (v) async {
                await bind.mainSetOption(
                    key: kEmilliAutoUpdate, value: v == true ? 'Y' : 'N');
                await _ask('state');
              },
            ),
            Expanded(
                child: Text(translate('emilli_update_auto'),
                    key: const ValueKey('emilli-update-auto'))),
          ]),
        if (usable)
          Text(translate('emilli_update_auto_tip'),
                  style: theme.textTheme.bodySmall)
              .marginOnly(left: 12, bottom: 4),
        if (result != null)
          Text(result, style: theme.textTheme.bodySmall)
              .marginSymmetric(vertical: 4),
      ],
    );
  }
}
