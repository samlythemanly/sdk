// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/lsp_protocol/protocol.dart';
import 'package:analysis_server/src/lsp/handlers/handlers.dart';
import 'package:analysis_server/src/lsp/mapping.dart';
import 'package:analysis_server/src/protocol_server.dart' show NavigationTarget;
import 'package:analysis_server/src/search/element_references.dart';
import 'package:analysis_server/src/services/search/search_engine.dart'
    show SearchMatch;
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer_plugin/src/utilities/navigation/navigation.dart';
import 'package:analyzer_plugin/utilities/navigation/navigation_dart.dart';
import 'package:collection/collection.dart';

class ReferencesHandler
    extends MessageHandler<ReferenceParams, List<Location>?> {
  ReferencesHandler(super.server);
  @override
  Method get handlesMessage => Method.textDocument_references;

  @override
  LspJsonHandler<ReferenceParams> get jsonHandler =>
      ReferenceParams.jsonHandler;

  @override
  Future<ErrorOr<List<Location>?>> handle(ReferenceParams params,
      MessageInfo message, CancellationToken token) async {
    if (!isDartDocument(params.textDocument)) {
      return success(const []);
    }

    final pos = params.position;
    final path = pathOfDoc(params.textDocument);
    final unit = await path.mapResult(requireResolvedUnit);
    final offset = await unit.mapResult((unit) => toOffset(unit.lineInfo, pos));
    return offset.mapResult(
        (offset) => _getReferences(path.result, offset, params, unit.result));
  }

  List<Location> _getDeclarations(CompilationUnit unit, int offset) {
    final collector = NavigationCollectorImpl();
    computeDartNavigation(server.resourceProvider, collector, unit, offset, 0);

    return convert(collector.targets, (NavigationTarget target) {
      final targetFilePath = collector.files[target.fileIndex];
      final lineInfo = server.getLineInfo(targetFilePath);
      return lineInfo != null
          ? navigationTargetToLocation(targetFilePath, target, lineInfo)
          : null;
    }).whereNotNull().toList();
  }

  Future<ErrorOr<List<Location>?>> _getReferences(String path, int offset,
      ReferenceParams params, ResolvedUnitResult unit) async {
    var element = await server.getElementAtOffset(path, offset);
    if (element is LibraryImportElement) {
      element = element.prefix?.element;
    }
    if (element is FieldFormalParameterElement) {
      element = element.field;
    }
    if (element is PropertyAccessorElement) {
      element = element.variable;
    }
    if (element == null) {
      return success(null);
    }

    final computer = ElementReferencesComputer(server.searchEngine);
    final session = element.session ?? unit.session;
    final results = await computer.compute(element, false);

    Location? toLocation(SearchMatch result) {
      final file = session.getFile(result.file);
      if (file is! FileResult) {
        return null;
      }
      return Location(
        uri: Uri.file(result.file).toString(),
        range: toRange(
          file.lineInfo,
          result.sourceRange.offset,
          result.sourceRange.length,
        ),
      );
    }

    final referenceResults =
        convert(results, toLocation).whereNotNull().toList();

    final compilationUnit = unit.unit;
    if (params.context.includeDeclaration == true) {
      // Also include the definition for the symbol at this location.
      referenceResults.addAll(_getDeclarations(compilationUnit, offset));
    }

    return success(referenceResults);
  }
}
