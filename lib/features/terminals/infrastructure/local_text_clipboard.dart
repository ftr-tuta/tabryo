import 'package:flutter/services.dart';

import '../domain/terminal_ports.dart';

final class LocalTextClipboard implements TextClipboard {
  @override
  Future<String?> readText() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  Future<void> writeText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}
