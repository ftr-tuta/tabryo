final class PreviewCache {
  PreviewCache({this.limit = 24 * 1024 * 1024});
  final int limit;
  final _entries = <String, String>{};
  int bytes = 0;
  String? get(String key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void put(String key, String value) {
    final previous = _entries.remove(key);
    if (previous != null) bytes -= (key.length + previous.length) * 2;
    final size = (key.length + value.length) * 2;
    if (size > limit) return;
    while (bytes + size > limit && _entries.isNotEmpty) {
      final oldest = _entries.keys.first;
      bytes -= (oldest.length + _entries.remove(oldest)!.length) * 2;
    }
    _entries[key] = value;
    bytes += size;
  }

  void clear() {
    _entries.clear();
    bytes = 0;
  }
}
