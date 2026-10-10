/// Where [query] occurs in [candidate], ignoring case and the query's
/// surrounding whitespace, or `null` if it does not occur.
int? substringPosition(String query, String candidate) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return 0;
  final position = candidate.toLowerCase().indexOf(q);
  return position < 0 ? null : position;
}

/// The items whose key contains [query], best match first: matches close to
/// the start come first, then the shortest text, then the text itself.
///
/// An empty query keeps every item in its original order.
List<T> substringFilter<T>(
  String query,
  Iterable<T> items,
  String Function(T item) key,
) {
  if (query.trim().isEmpty) return items.toList();
  final matched = <(int, int, String, T)>[];
  for (final item in items) {
    final text = key(item);
    final position = substringPosition(query, text);
    if (position != null) matched.add((position, text.length, text, item));
  }
  matched.sort((a, b) {
    var c = a.$1.compareTo(b.$1);
    if (c != 0) return c;
    c = a.$2.compareTo(b.$2);
    if (c != 0) return c;
    return a.$3.compareTo(b.$3);
  });
  return [for (final m in matched) m.$4];
}

/// Where a package search hit came from.
enum MatchKind { name, summary, description }

/// Shortest query that also searches descriptions; shorter ones match too
/// much prose to be useful.
const int descriptionQueryMinLength = 3;

/// Package names matching [query]: name matches first, ranked as
/// [substringFilter] ranks them, then packages whose summary mentions it,
/// then those whose description does, each sorted by name.
///
/// [summary] and [description] return lowercased text, or `null` when
/// nothing is known about a package.
List<(String, MatchKind)> rankPackages(
  String query,
  List<String> names, {
  String? Function(String name)? summary,
  String? Function(String name)? description,
}) {
  final q = query.trim().toLowerCase();
  final byName = substringFilter(query, names, (n) => n);
  final hits = [for (final n in byName) (n, MatchKind.name)];
  if (q.isEmpty || (summary == null && description == null)) return hits;
  final matched = byName.toSet();
  final inSummary = <String>[];
  final inDescription = <String>[];
  final searchDescriptions =
      description != null && q.length >= descriptionQueryMinLength;
  for (final name in names) {
    if (matched.contains(name)) continue;
    if (summary?.call(name)?.contains(q) ?? false) {
      inSummary.add(name);
    } else if (searchDescriptions &&
        (description(name)?.contains(q) ?? false)) {
      inDescription.add(name);
    }
  }
  return [
    ...hits,
    for (final n in inSummary..sort()) (n, MatchKind.summary),
    for (final n in inDescription..sort()) (n, MatchKind.description),
  ];
}
