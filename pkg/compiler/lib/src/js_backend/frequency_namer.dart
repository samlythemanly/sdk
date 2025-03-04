// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.10

part of js_backend.namer;

class FrequencyBasedNamer extends Namer
    with _MinifiedFieldNamer, _MinifiedOneShotInterceptorNamer
    implements jsAst.TokenFinalizer {
  @override
  _FieldNamingRegistry fieldRegistry;
  List<TokenName> tokens = [];

  final Map<NamingScope, TokenScope> _tokenScopes = {};

  @override
  String get genericInstantiationPrefix => r'$I';

  FrequencyBasedNamer(JClosedWorld closedWorld, FixedNames fixedNames)
      : super(closedWorld, fixedNames) {
    fieldRegistry = _FieldNamingRegistry(this);
  }

  TokenScope newScopeFor(NamingScope scope) {
    if (scope == instanceScope) {
      Set<String> illegalNames = Set<String>.from(jsReserved);
      for (String illegal in MinifyNamer._reservedNativeProperties) {
        illegalNames.add(illegal);
        if (MinifyNamer._hasBannedPrefix(illegal)) {
          illegalNames.add(illegal.substring(1));
        }
      }
      return TokenScope(illegalNames: illegalNames);
    } else {
      return TokenScope(illegalNames: jsReserved);
    }
  }

  @override
  jsAst.Name getFreshName(NamingScope scope, String proposedName,
      {bool sanitizeForNatives = false, bool sanitizeForAnnotations = false}) {
    // Grab the scope for this token
    TokenScope tokenScope =
        _tokenScopes.putIfAbsent(scope, () => newScopeFor(scope));

    // Get the name the normal namer would use as a key.
    String proposed = _generateFreshStringForName(proposedName, scope,
        sanitizeForNatives: sanitizeForNatives,
        sanitizeForAnnotations: sanitizeForAnnotations);

    TokenName name = TokenName(tokenScope, proposed);
    tokens.add(name);
    return name;
  }

  @override
  jsAst.Name instanceFieldPropertyName(FieldEntity element) {
    jsAst.Name proposed = _minifiedInstanceFieldPropertyName(element);
    if (proposed != null) {
      return proposed;
    }
    return super.instanceFieldPropertyName(element);
  }

  @override
  void finalizeTokens() {
    int compareReferenceCount(TokenName a, TokenName b) {
      int result = b._rc - a._rc;
      if (result == 0) result = a.key.compareTo(b.key);
      return result;
    }

    List<TokenName> usedNames =
        tokens.where((TokenName a) => a._rc > 0).toList();
    usedNames.sort(compareReferenceCount);
    usedNames.forEach((TokenName token) => token.finalize());
  }
}

class TokenScope {
  int initialChar;
  List<int> _nextName;
  final Set<String> illegalNames;

  TokenScope({this.illegalNames = const {}, this.initialChar = $a}) {
    _nextName = [initialChar];
  }

  /// Increments the letter at [pos] in the current name. Also takes care of
  /// overflows to the left. Returns the carry bit, i.e., it returns `true`
  /// if all positions to the left have wrapped around.
  ///
  /// If [_nextName] is initially 'a', this will generate the sequence
  ///
  /// [a-zA-Z]
  /// [a-zA-Z][_0-9a-zA-Z]
  /// [a-zA-Z][_0-9a-zA-Z][_0-9a-zA-Z]
  /// ...
  bool _incrementPosition(int pos) {
    bool overflow = false;
    if (pos < 0) return true;
    int value = _nextName[pos];
    if (value == $_) {
      value = $0;
    } else if (value == $9) {
      value = $a;
    } else if (value == $z) {
      value = $A;
    } else if (value == $Z) {
      overflow = _incrementPosition(pos - 1);
      value = (pos > 0) ? $_ : initialChar;
    } else {
      value++;
    }
    _nextName[pos] = value;
    return overflow;
  }

  _incrementName() {
    if (_incrementPosition(_nextName.length - 1)) {
      _nextName.add($_);
    }
  }

  String getNextName() {
    String proposal;
    do {
      proposal = String.fromCharCodes(_nextName);
      _incrementName();
    } while (MinifyNamer._hasBannedPrefix(proposal) ||
        illegalNames.contains(proposal));

    return proposal;
  }
}
