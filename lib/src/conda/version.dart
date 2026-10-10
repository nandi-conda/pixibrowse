/// Conda version ordering, following conda's `VersionOrder`.
///
/// A version is split into an epoch (`1!`), the main part and a local part
/// (`+local`). Each part is split on `.` and `_` into components, and every
/// component into runs of digits and letters. Numbers compare numerically,
/// strings lexicographically, a string sorts before a number, `dev` sorts
/// before everything and `post` after everything. Missing components count
/// as `0`.
library;

class CondaVersion implements Comparable<CondaVersion> {
  CondaVersion._(this.source, this._epoch, this._main, this._local);

  factory CondaVersion.parse(String source) {
    var text = source.trim().toLowerCase();
    var epoch = 0;
    final bang = text.indexOf('!');
    if (bang >= 0) {
      epoch = int.tryParse(text.substring(0, bang)) ?? 0;
      text = text.substring(bang + 1);
    }
    var local = '';
    final plus = text.indexOf('+');
    if (plus >= 0) {
      local = text.substring(plus + 1);
      text = text.substring(0, plus);
    }
    return CondaVersion._(source, epoch, _split(text), _split(local));
  }

  final String source;
  final int _epoch;
  final List<List<Object>> _main;
  final List<List<Object>> _local;

  static final RegExp _run = RegExp(r'\d+|[a-z]+|\*');

  static List<List<Object>> _split(String text) {
    if (text.isEmpty) return const [];
    final components = <List<Object>>[];
    for (final part in text.split(RegExp(r'[._-]'))) {
      final atoms = <Object>[];
      for (final match in _run.allMatches(part)) {
        final token = match.group(0)!;
        final number = int.tryParse(token);
        atoms.add(number ?? token);
      }
      if (atoms.isEmpty) atoms.add(0);
      // A component starting with letters gets an implicit leading 0, so
      // that `1.0a1` compares as 1.0.0a1 below 1.0.0.
      if (atoms.first is String) atoms.insert(0, 0);
      components.add(atoms);
    }
    return components;
  }

  // Ranks: dev < other strings < numbers < post.
  static int _rank(Object atom) {
    if (atom is int) return 2;
    if (atom == 'dev') return 0;
    if (atom == 'post') return 3;
    return 1;
  }

  static int _compareAtom(Object a, Object b) {
    final ra = _rank(a);
    final rb = _rank(b);
    if (ra != rb) return ra.compareTo(rb);
    if (a is int && b is int) return a.compareTo(b);
    return (a as String).compareTo(b as String);
  }

  static int _compareParts(List<List<Object>> a, List<List<Object>> b) {
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final ca = i < a.length ? a[i] : const <Object>[0];
      final cb = i < b.length ? b[i] : const <Object>[0];
      final m = ca.length > cb.length ? ca.length : cb.length;
      for (var j = 0; j < m; j++) {
        final x = j < ca.length ? ca[j] : 0;
        final y = j < cb.length ? cb[j] : 0;
        final c = _compareAtom(x, y);
        if (c != 0) return c;
      }
    }
    return 0;
  }

  @override
  int compareTo(CondaVersion other) {
    if (_epoch != other._epoch) return _epoch.compareTo(other._epoch);
    final c = _compareParts(_main, other._main);
    if (c != 0) return c;
    return _compareParts(_local, other._local);
  }

  @override
  bool operator ==(Object other) =>
      other is CondaVersion && compareTo(other) == 0;

  @override
  int get hashCode => _epoch.hashCode;

  @override
  String toString() => source;
}
