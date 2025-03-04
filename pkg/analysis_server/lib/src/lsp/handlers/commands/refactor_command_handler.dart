// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/lsp_protocol/protocol.dart';
import 'package:analysis_server/src/lsp/constants.dart';
import 'package:analysis_server/src/lsp/handlers/commands/simple_edit_handler.dart';
import 'package:analysis_server/src/lsp/handlers/handlers.dart';
import 'package:analysis_server/src/lsp/mapping.dart';
import 'package:analysis_server/src/lsp/progress.dart';
import 'package:analysis_server/src/lsp/source_edits.dart';
import 'package:analysis_server/src/services/refactoring/framework/refactoring_context.dart';
import 'package:analysis_server/src/services/refactoring/framework/refactoring_processor.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';

/// A command handler for any of the commands used to implement refactorings.
class RefactorCommandHandler extends SimpleEditCommandHandler {
  @override
  final String commandName;

  final ProducerGenerator generator;

  RefactorCommandHandler(super.server, this.commandName, this.generator);

  @override
  Future<ErrorOr<void>> handle(Map<String, Object?> parameters,
      ProgressReporter progress, CancellationToken cancellationToken) async {
    var filePath = parameters['filePath'];
    var offset = parameters['selectionOffset'];
    var length = parameters['selectionLength'];
    var arguments = _validateArguments(parameters['arguments']);
    if (filePath is! String ||
        offset is! int ||
        length is! int ||
        arguments == null) {
      return ErrorOr.error(ResponseError(
          code: ServerErrorCodes.InvalidCommandArguments,
          message: 'Refactoring operations require 4 parameters: '
              'filePath: String, '
              'offset: int, '
              'length: int, '
              'arguments: List<String>'));
    }

    final clientCapabilities = server.clientCapabilities;
    if (clientCapabilities == null) {
      // This should not happen unless a client misbehaves.
      return serverNotInitializedError;
    }

    final result = await requireResolvedUnit(filePath);
    return result.mapResult((result) async {
      var context = RefactoringContext(
          server: server,
          resolvedResult: result,
          selectionOffset: offset,
          selectionLength: length);
      var producer = generator(context);
      var builder = ChangeBuilder(
          workspace: context.workspace, eol: context.utils.endOfLine);
      await producer.compute(arguments, builder);

      var edits = builder.sourceChange.edits;
      if (edits.isEmpty) {
        return success(null);
      }

      var fileEdits = <FileEditInformation>[];
      for (var edit in edits) {
        var path = edit.file;
        final fileResult = context.session.getFile(path);
        if (fileResult is! FileResult) {
          return ErrorOr.error(ResponseError(
              code: ServerErrorCodes.FileAnalysisFailed,
              message: 'Could not access "$path".'));
        }
        final docIdentifier = server.getVersionedDocumentIdentifier(path);
        fileEdits.add(FileEditInformation(
            docIdentifier, fileResult.lineInfo, edit.edits));
      }
      final workspaceEdit = toWorkspaceEdit(clientCapabilities, fileEdits);
      return sendWorkspaceEditToClient(workspaceEdit);
    });
  }

  /// If the [arguments] is a list whose elements are all strings, then return
  /// them. Otherwise, return `null` to indicate that they aren't what we were
  /// expecting.
  List<String>? _validateArguments(Object? arguments) {
    if (arguments is! List<Object?>) {
      return null;
    }
    var result = <String>[];
    for (var element in arguments) {
      if (element is! String) {
        return null;
      }
      result.add(element);
    }
    return result;
  }
}
