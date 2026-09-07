/// Small SQL lexer used to retain physical constraints the Dart model does not
/// describe. Quoted text, comments and balanced expressions remain intact.
class SqlToken {
  const SqlToken(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
  String get keyword => text.toUpperCase();
  String get identifier {
    if (text.startsWith('"')) {
      return text.substring(1, text.length - 1).replaceAll('""', '"');
    }
    if (text.startsWith('`')) {
      return text.substring(1, text.length - 1).replaceAll('``', '`');
    }
    if (text.startsWith('[')) return text.substring(1, text.length - 1);
    return text;
  }
}

List<SqlToken> sqlTokens(String sql) {
  final result = <SqlToken>[];
  var i = 0;
  while (i < sql.length) {
    if (sql[i].trim().isEmpty) {
      i++;
      continue;
    }
    if (sql.startsWith('--', i)) {
      final end = sql.indexOf('\n', i + 2);
      i = end < 0 ? sql.length : end + 1;
      continue;
    }
    if (sql.startsWith('/*', i)) {
      final end = sql.indexOf('*/', i + 2);
      if (end < 0) throw StateError('Unterminated SQL comment');
      i = end + 2;
      continue;
    }
    final start = i;
    final c = sql[i];
    if (c == '"' || c == "'" || c == '`' || c == '[') {
      final quote = c == '[' ? ']' : c;
      i++;
      var closed = false;
      while (i < sql.length) {
        if (sql[i++] == quote) {
          if (quote != ']' && i < sql.length && sql[i] == quote) {
            i++;
          } else {
            closed = true;
            break;
          }
        }
      }
      if (!closed) throw StateError('Unterminated SQL quote');
    } else if ('(),;'.contains(c)) {
      i++;
    } else {
      while (i < sql.length &&
          sql[i].trim().isNotEmpty &&
          !'(),;\'"`['.contains(sql[i]) &&
          !sql.startsWith('--', i) &&
          !sql.startsWith('/*', i)) {
        i++;
      }
    }
    result.add(SqlToken(sql.substring(start, i), start, i));
  }
  return result;
}

String quoteIdentifier(String name) => '"${name.replaceAll('"', '""')}"';

/// Returns top-level tokens, treating each balanced expression as one token.
List<SqlToken> topLevelTokens(String sql) {
  final tokens = sqlTokens(sql);
  final result = <SqlToken>[];
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token.text != '(') {
      result.add(token);
      continue;
    }
    var depth = 1;
    var end = token.end;
    while (++i < tokens.length) {
      if (tokens[i].text == '(') depth++;
      if (tokens[i].text == ')') depth--;
      end = tokens[i].end;
      if (depth == 0) break;
    }
    if (depth != 0) throw StateError('Unbalanced SQL expression');
    result.add(SqlToken(sql.substring(token.start, end), token.start, end));
  }
  return result;
}

class TableDefinition {
  TableDefinition(String sql) {
    final body = topLevelTokens(sql).firstWhere((t) => t.text.startsWith('('));
    suffix = sql.substring(body.end).replaceFirst(RegExp(r';\s*$'), '');
    final contents = body.text.substring(1, body.text.length - 1);
    var start = 0;
    for (final token in topLevelTokens(contents)) {
      if (token.text != ',') continue;
      parts.add(contents.substring(start, token.start).trim());
      start = token.end;
    }
    parts.add(contents.substring(start).trim());
  }
  final parts = <String>[];
  late final String suffix;
  String create(String name) =>
      'CREATE TABLE ${quoteIdentifier(name)} (${parts.join(', ')})$suffix';
}

String? columnName(String definition) {
  final first = sqlTokens(definition).first;
  if (const {
    'CONSTRAINT',
    'PRIMARY',
    'UNIQUE',
    'CHECK',
    'FOREIGN',
  }.contains(first.keyword)) {
    return null;
  }
  return first.identifier;
}

/// Rewrite only modeled attributes; keep CHECK, UNIQUE, COLLATE, generated
/// expressions, named constraints, references and table options verbatim.
String rewriteColumn(
  String sql, {
  required String type,
  required bool notNull,
  required String? defaultSql,
  required bool changeType,
  required bool changeNull,
  required bool changeDefault,
}) {
  var tokens = topLevelTokens(sql);
  const constraints = {
    'CONSTRAINT',
    'PRIMARY',
    'NOT',
    'NULL',
    'UNIQUE',
    'CHECK',
    'DEFAULT',
    'COLLATE',
    'REFERENCES',
    'GENERATED',
    'AS',
  };
  var endType = 1;
  while (endType < tokens.length &&
      !constraints.contains(tokens[endType].keyword)) {
    endType++;
  }
  final constraintStart =
      endType == tokens.length ? sql.length : tokens[endType].start;
  if (changeType) {
    sql =
        '${sql.substring(0, tokens.first.end)} $type ${sql.substring(constraintStart)}';
  }
  tokens = topLevelTokens(sql);
  final removals = <({int start, int end})>[];
  for (var i = 1; i < tokens.length; i++) {
    final token = tokens[i];
    var last = i;
    if (token.keyword == 'DEFAULT') {
      if (i + 1 == tokens.length) throw StateError('Missing SQL default');
      last = i + 1;
      if (tokens[last].text == '+' || tokens[last].text == '-') last++;
      if (tokens[last].keyword == 'X' &&
          last + 1 < tokens.length &&
          tokens[last + 1].text.startsWith("'")) {
        last++;
      }
      if (!changeDefault) {
        i = last;
        continue;
      }
    } else if (changeNull &&
        token.keyword == 'NOT' &&
        i + 1 < tokens.length &&
        tokens[i + 1].keyword == 'NULL') {
      last = i + 1;
      if (last + 3 < tokens.length &&
          tokens[last + 1].keyword == 'ON' &&
          tokens[last + 2].keyword == 'CONFLICT') {
        last += 3;
      }
    } else if (!changeNull ||
        token.keyword != 'NULL' ||
        (i > 0 && tokens[i - 1].keyword == 'SET')) {
      continue;
    }
    var start = token.start;
    if (i >= 2 && tokens[i - 2].keyword == 'CONSTRAINT') {
      start = tokens[i - 2].start;
    }
    removals.add((start: start, end: tokens[last].end));
    i = last;
  }
  for (final range in removals.reversed) {
    sql = sql.replaceRange(range.start, range.end, '');
  }
  return '${sql.trimRight()}\n${changeNull && notNull ? ' NOT NULL' : ''}'
      '${!changeDefault || defaultSql == null ? '' : ' DEFAULT $defaultSql'}';
}

String? normalizeDefault(Object? value) {
  if (value == null) return null;
  var text = value.toString().trim();
  while (true) {
    final tokens = topLevelTokens(text);
    if (tokens.length != 1 || !tokens.single.text.startsWith('(')) break;
    text =
        tokens.single.text.substring(1, tokens.single.text.length - 1).trim();
  }
  return text.toUpperCase() == 'NULL' ? null : text;
}

/// SQLite omits IF NOT EXISTS from sqlite_master. Normalize that header and
/// whitespace without folding case inside SQL string literals.
String normalizeTriggerSql(String sql) {
  final tokens = sqlTokens(sql).map((t) => t.text).toList();
  final trigger = tokens.indexWhere((t) => t.toUpperCase() == 'TRIGGER');
  if (trigger >= 0 &&
      trigger < 3 &&
      tokens.length > trigger + 3 &&
      tokens.sublist(trigger + 1, trigger + 4).join(' ').toUpperCase() ==
          'IF NOT EXISTS') {
    tokens.removeRange(trigger + 1, trigger + 4);
  }
  while (tokens.isNotEmpty && tokens.last == ';') {
    tokens.removeLast();
  }
  return tokens.join(' ');
}
