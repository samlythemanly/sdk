// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/protocol/protocol_generated.dart'
    show HoverInformation;
import 'package:analysis_server/src/computer/computer_overrides.dart';
import 'package:analysis_server/src/utilities/extensions/ast.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/ast/element_locator.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';
import 'package:analyzer/src/dartdoc/dartdoc_directive_info.dart';
import 'package:path/path.dart' as path;

/// A computer for the hover at the specified offset of a Dart
/// [CompilationUnit].
class DartUnitHoverComputer {
  final DartdocDirectiveInfo _dartdocInfo;
  final CompilationUnit _unit;
  final int _offset;

  DartUnitHoverComputer(this._dartdocInfo, this._unit, this._offset);

  /// Returns the computed hover, maybe `null`.
  HoverInformation? compute() {
    var node = NodeLocator(_offset).searchWithin(_unit);
    if (node == null) {
      return null;
    }
    var parent = node.parent;
    var grandParent = parent?.parent;
    if (parent is NamedType &&
        grandParent is ConstructorName &&
        grandParent.parent is InstanceCreationExpression) {
      node = grandParent.parent;
    } else if (parent is ConstructorName &&
        grandParent is InstanceCreationExpression) {
      node = grandParent;
    }
    if (node is Expression) {
      var expression = node;
      // For constructor calls the whole expression is selected (above) but this
      // results in the range covering the whole call so narrow it to just the
      // ConstructorName.
      var hover = expression is InstanceCreationExpression
          ? HoverInformation(
              expression.constructorName.offset,
              expression.constructorName.length,
            )
          : HoverInformation(expression.offset, expression.length);
      // element
      var element = ElementLocator.locate(expression);
      if (element != null) {
        // variable, if synthetic accessor
        if (element is PropertyAccessorElement) {
          if (element.isSynthetic) {
            element = element.variable;
          }
        }
        // description
        var description = _elementDisplayString(element);
        hover.elementDescription = description;
        if (description != null &&
            node is InstanceCreationExpression &&
            node.keyword == null) {
          var prefix = node.isConst ? '(const) ' : '(new) ';
          hover.elementDescription = prefix + description;
        }
        hover.elementKind = element.kind.displayName;
        hover.isDeprecated = element.hasDeprecated;
        // not local element
        if (element.enclosingElement3 is! ExecutableElement) {
          // containing class
          var containingClass = element.thisOrAncestorOfType<ClassElement>();
          if (containingClass != null && containingClass != element) {
            hover.containingClassDescription = containingClass.displayName;
          }
          // containing library
          var library = element.library;
          if (library != null) {
            var uri = library.source.uri;
            var analysisSession = _unit.declaredElement?.session;
            if (uri.isScheme('file') && analysisSession != null) {
              // for 'file:' URIs, use the path after the project root
              var context = analysisSession.resourceProvider.pathContext;
              var projectRootDir =
                  analysisSession.analysisContext.contextRoot.root.path;
              var relativePath =
                  context.relative(context.fromUri(uri), from: projectRootDir);
              if (context.style == path.Style.windows) {
                var pathList = context.split(relativePath);
                hover.containingLibraryName = pathList.join('/');
              } else {
                hover.containingLibraryName = relativePath;
              }
            } else {
              hover.containingLibraryName = uri.toString();
            }
            hover.containingLibraryPath = library.source.fullName;
          }
        }
        // documentation
        hover.dartdoc = computeDocumentation(_dartdocInfo, element)?.full;
      }
      // parameter
      hover.parameter = _elementDisplayString(
        expression.staticParameterElement,
      );
      // types
      {
        var parent = expression.parent;
        DartType? staticType;
        if (element == null || element is VariableElement) {
          staticType = _getTypeOfDeclarationOrReference(node);
        }
        if (parent is MethodInvocation && parent.methodName == expression) {
          staticType = parent.staticInvokeType;
          if (staticType != null && staticType.isDynamic) {
            staticType = null;
          }
        }
        hover.staticType = _typeDisplayString(staticType);
      }
      // done
      return hover;
    }
    // not an expression
    return null;
  }

  String? _elementDisplayString(Element? element) {
    return element?.getDisplayString(
      withNullability: _unit.isNonNullableByDefault,
      multiline: true,
    );
  }

  String? _typeDisplayString(DartType? type) {
    return type?.getDisplayString(
        withNullability: _unit.isNonNullableByDefault);
  }

  static Documentation? computeDocumentation(
      DartdocDirectiveInfo dartdocInfo, Element elementBeingDocumented,
      {bool includeSummary = false}) {
    // TODO(dantup) We're reusing this in parameter information - move it
    // somewhere shared?
    Element? element = elementBeingDocumented;
    if (element is FieldFormalParameterElement) {
      element = element.field;
    }
    if (element is ParameterElement) {
      element = element.enclosingElement3;
    }
    if (element == null) {
      // This can happen when the code is invalid, such as having a field formal
      // parameter for a field that does not exist.
      return null;
    }

    Element? documentedElement;
    Element? documentedGetter;

    // Look for documentation comments of overridden members
    var overridden = findOverriddenElements(element);
    for (var candidate in [
      element,
      ...overridden.superElements,
      ...overridden.interfaceElements
    ]) {
      if (candidate.documentationComment != null) {
        documentedElement = candidate;
        break;
      }
      if (documentedGetter == null &&
          candidate is PropertyAccessorElement &&
          candidate.isSetter) {
        var getter = candidate.correspondingGetter;
        if (getter != null && getter.documentationComment != null) {
          documentedGetter = getter;
        }
      }
    }

    // Use documentation of a corresponding getter if setters don't have it
    documentedElement ??= documentedGetter;
    if (documentedElement == null) {
      return null;
    }

    var rawDoc = documentedElement.documentationComment;
    if (rawDoc == null) {
      return null;
    }
    var result =
        dartdocInfo.processDartdoc(rawDoc, includeSummary: includeSummary);

    var documentedElementClass = documentedElement.enclosingElement3;
    if (documentedElementClass != null &&
        documentedElementClass != element.enclosingElement3) {
      var documentedClass = documentedElementClass.displayName;
      result.full = '${result.full}\n\nCopied from `$documentedClass`.';
    }

    return result;
  }

  static DartType? _getTypeOfDeclarationOrReference(Expression node) {
    if (node is SimpleIdentifier) {
      var element = node.staticElement;
      if (element is VariableElement) {
        if (node.inDeclarationContext()) {
          return element.type;
        }
        var parent2 = node.parent?.parent;
        if (parent2 is NamedExpression && parent2.name.label == node) {
          return element.type;
        }
      }
    }
    return node.staticType;
  }
}
