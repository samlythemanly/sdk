// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.import;

import 'package:kernel/ast.dart' show LibraryDependency;

import 'builder/builder.dart';
import 'builder/library_builder.dart';
import 'builder/prefix_builder.dart';

import 'kernel/utils.dart' show toKernelCombinators;

import 'combinator.dart' show CombinatorBuilder;

import 'configuration.dart' show Configuration;

import 'source/source_library_builder.dart';

import 'scope.dart' show NameIteratorExtension;

class Import {
  /// The library that is importing [imported];
  final SourceLibraryBuilder importer;

  /// The library being imported.
  LibraryBuilder? imported;

  final PrefixBuilder? prefixBuilder;

  final bool isAugmentationImport;

  final bool deferred;

  final String? prefix;

  final List<CombinatorBuilder>? combinators;

  final List<Configuration>? configurations;

  final int charOffset;

  final int prefixCharOffset;

  // The LibraryBuilder for the imported library ('imported') may be null when
  // this field is set.
  final String? nativeImportPath;

  Import(
      this.importer,
      this.imported,
      this.isAugmentationImport,
      this.deferred,
      this.prefix,
      this.combinators,
      this.configurations,
      this.charOffset,
      this.prefixCharOffset,
      int importIndex,
      {this.nativeImportPath})
      : prefixBuilder = createPrefixBuilder(prefix, importer, imported,
            combinators, deferred, charOffset, prefixCharOffset, importIndex);

  Uri get fileUri => importer.fileUri;

  void finalizeImports(SourceLibraryBuilder importer) {
    if (nativeImportPath != null) return;
    void Function(String, Builder) add;
    if (prefixBuilder == null) {
      add = (String name, Builder member) {
        importer.addToScope(name, member, charOffset, true);
      };
    } else {
      add = (String name, Builder member) {
        prefixBuilder!.addToExportScope(name, member, charOffset);
      };
    }
    imported!.exportScope
        .filteredNameIterator(
            includeDuplicates: false, includeAugmentations: false)
        .forEach((String name, Builder member) {
      if (combinators != null) {
        for (CombinatorBuilder combinator in combinators!) {
          if (combinator.isShow && !combinator.names.contains(name)) return;
          if (combinator.isHide && combinator.names.contains(name)) return;
        }
      }
      add(name, member);
    });
    if (prefixBuilder != null) {
      Builder? existing =
          importer.addBuilder(prefix, prefixBuilder!, prefixCharOffset);
      if (existing == prefixBuilder) {
        importer.addToScope(prefix!, prefixBuilder!, prefixCharOffset, true);
      }
    }
  }
}

PrefixBuilder? createPrefixBuilder(
    String? prefix,
    SourceLibraryBuilder importer,
    LibraryBuilder? imported,
    List<CombinatorBuilder>? combinators,
    bool deferred,
    int charOffset,
    int prefixCharOffset,
    int importIndex) {
  if (prefix == null) return null;
  LibraryDependency? dependency = null;
  if (deferred) {
    dependency = new LibraryDependency.deferredImport(imported!.library, prefix,
        combinators: toKernelCombinators(combinators))
      ..fileOffset = charOffset;
  }
  return new PrefixBuilder(
      prefix, deferred, importer, dependency, prefixCharOffset, importIndex);
}
