// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/protocol_server.dart' as protocol;
import 'package:analysis_server/src/provisional/completion/dart/completion_dart.dart';
import 'package:analysis_server/src/services/completion/dart/suggestion_builder.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer_plugin/src/utilities/visitors/local_declaration_visitor.dart';

/// A contributor that produces suggestions based on the instance members of a
/// given type, whether declared by that type directly or inherited from a
/// superinterface. More concretely, this class produces suggestions for
/// expressions of the form `o.^`, where `o` is an expression denoting an
/// instance of a type.
class TypeMemberContributor extends DartCompletionContributor {
  TypeMemberContributor(super.request, super.builder);

  @override
  Future<void> computeSuggestions() async {
    // Recompute the target because resolution might have changed it.
    var expression = request.target.dotTarget;
    if (expression == null ||
        expression.isSynthetic ||
        expression is ExtensionOverride) {
      return;
    }
    if (expression is Identifier) {
      var elem = expression.staticElement;
      if (elem is ClassElement) {
        // Suggestions provided by StaticMemberContributor.
        return;
      }
      if (elem is PrefixElement) {
        // Suggestions provided by LibraryMemberContributor.
        return;
      }
    }

    // Determine the target expression's type.
    final expressionType = expression.staticType;
    var type = expressionType != null
        ? request.libraryElement.typeSystem.resolveToBound(expressionType)
        : null;
    if (type == null || type.isDynamic) {
      // If the expression does not provide a good type, then attempt to get a
      // better type from the element.
      if (expression is Identifier) {
        var elem = expression.staticElement;
        if (elem is FunctionTypedElement) {
          type = elem.returnType;
        } else if (elem is ParameterElement) {
          type = elem.type;
        } else if (elem is LocalVariableElement) {
          type = elem.type;
        }
        if ((type == null || type.isDynamic) &&
            expression is SimpleIdentifier) {
          // If the element does not provide a good type, then attempt to get a
          // better type from a local declaration.
          var visitor = _LocalBestTypeVisitor(expression.name, request.offset);
          if (visitor.visit(expression) && visitor.typeFound != null) {
            type = visitor.typeFound;
          }
        }
      }
    }
    List<InterfaceType>? mixins;
    List<InterfaceType>? superclassConstraints;
    if (expression is SuperExpression && type is InterfaceType) {
      // Suggest members from superclass if target is "super".
      mixins = type.mixins;
      superclassConstraints = type.superclassConstraints;
      type = type.superclass;
    }
    if (type is FunctionType) {
      builder.suggestFunctionCall();
      type = request.objectType;
    } else if (type == null || type.isDynamic) {
      // Suggest members from object if target is "dynamic".
      type = request.objectType;
    }

    // Build the suggestions.
    if (type is InterfaceType) {
      var memberBuilder = _SuggestionBuilder(request, builder);
      memberBuilder.buildSuggestions(type,
          mixins: mixins, superclassConstraints: superclassConstraints);
    }
  }
}

/// An [AstVisitor] which looks for a declaration with the given name and if
/// found, tries to determine a type for that declaration.
class _LocalBestTypeVisitor extends LocalDeclarationVisitor {
  /// The name for the declaration to be found.
  final String targetName;

  /// The best type for the found declaration, or `null` if no declaration found
  /// or failed to determine a type.
  DartType? typeFound;

  /// Construct a new instance to search for a declaration.
  _LocalBestTypeVisitor(this.targetName, int offset) : super(offset);

  @override
  void declaredClass(ClassDeclaration declaration) {
    if (declaration.name2.lexeme == targetName) {
      // no type
      finished();
    }
  }

  @override
  void declaredClassTypeAlias(ClassTypeAlias declaration) {
    if (declaration.name2.lexeme == targetName) {
      // no type
      finished();
    }
  }

  @override
  void declaredField(FieldDeclaration fieldDecl, VariableDeclaration varDecl) {
    if (varDecl.name2.lexeme == targetName) {
      // Type provided by the element in computeFull above
      finished();
    }
  }

  @override
  void declaredFunction(FunctionDeclaration declaration) {
    if (declaration.name2.lexeme == targetName) {
      var returnType = declaration.returnType;
      if (returnType != null) {
        var type = returnType.type;
        if (type != null) {
          typeFound = type;
        }
      }
      finished();
    }
  }

  @override
  void declaredFunctionTypeAlias(FunctionTypeAlias declaration) {
    if (declaration.name2.lexeme == targetName) {
      var returnType = declaration.returnType;
      if (returnType != null) {
        var type = returnType.type;
        if (type != null) {
          typeFound = type;
        }
      }
      finished();
    }
  }

  @override
  void declaredGenericTypeAlias(GenericTypeAlias declaration) {
    if (declaration.name2.lexeme == targetName) {
      var returnType = declaration.functionType?.returnType;
      if (returnType != null) {
        var type = returnType.type;
        if (type != null) {
          typeFound = type;
        }
      }
      finished();
    }
  }

  @override
  void declaredLabel(Label label, bool isCaseLabel) {
    if (label.label.name == targetName) {
      // no type
      finished();
    }
  }

  @override
  void declaredLocalVar(
    Token name,
    TypeAnnotation? type,
    LocalVariableElement declaredElement,
  ) {
    if (name.lexeme == targetName) {
      typeFound = declaredElement.type;
      finished();
    }
  }

  @override
  void declaredMethod(MethodDeclaration declaration) {
    if (declaration.name2.lexeme == targetName) {
      var returnType = declaration.returnType;
      if (returnType != null) {
        var type = returnType.type;
        if (type != null) {
          typeFound = type;
        }
      }
      finished();
    }
  }

  @override
  void declaredParam(Token name, Element? element, TypeAnnotation? type) {
    if (name.lexeme == targetName) {
      // Type provided by the element in computeFull above.
      finished();
    }
  }

  @override
  void declaredTopLevelVar(
      VariableDeclarationList varList, VariableDeclaration varDecl) {
    if (varDecl.name2.lexeme == targetName) {
      // Type provided by the element in computeFull above.
      finished();
    }
  }
}

/// This class provides suggestions based upon the visible instance members in
/// an interface type.
class _SuggestionBuilder extends MemberSuggestionBuilder {
  /// Initialize a newly created suggestion builder.
  _SuggestionBuilder(super.request, super.builder);

  /// Return completion suggestions for 'dot' completions on the given [type].
  /// If the 'dot' completion is a super expression, then [containingMethodName]
  /// is the name of the method in which the completion is requested.
  void buildSuggestions(InterfaceType type,
      {List<InterfaceType>? mixins,
      List<InterfaceType>? superclassConstraints}) {
    // Visit all of the types in the class hierarchy, collecting possible
    // completions.  If multiple elements are found that complete to the same
    // identifier, addSuggestion will discard all but the first (with a few
    // exceptions to handle getter/setter pairs).
    var types = _getTypeOrdering(type);
    if (mixins != null) {
      types.addAll(mixins);
    }
    if (superclassConstraints != null) {
      types.addAll(superclassConstraints);
    }
    for (var targetType in types) {
      var inheritanceDistance = request.featureComputer
          .inheritanceDistanceFeature(type.element2, targetType.element2);
      for (var method in targetType.methods) {
        // Exclude static methods when completion on an instance.
        if (!method.isStatic) {
          addSuggestionForMethod(
            method: method,
            kind: protocol.CompletionSuggestionKind.INVOCATION,
            inheritanceDistance: inheritanceDistance,
          );
        }
      }
      for (var accessor in targetType.accessors) {
        if (!accessor.isStatic) {
          addSuggestionForAccessor(
              accessor: accessor, inheritanceDistance: inheritanceDistance);
        }
      }
      if (targetType.isDartCoreFunction) {
        builder.suggestFunctionCall();
      }
    }
  }

  /// Get a list of [InterfaceType]s that should be searched to find the
  /// possible completions for an object having type [type].
  List<InterfaceType> _getTypeOrdering(InterfaceType type) {
    // Candidate completions can come from [type] as well as any types above it
    // in the class hierarchy (including mixins, superclasses, and interfaces).
    // If a given completion identifier shows up in multiple types, we should
    // use the element that is nearest in the superclass chain, so we will
    // visit [type] first, then its mixins, then its superclass, then its
    // superclass's mixins, etc., and only afterwards visit interfaces.
    //
    // We short-circuit loops in the class hierarchy by keeping track of the
    // classes seen (not the interfaces) so that we won't be fooled by nonsense
    // like "class C<T> extends C<List<T>> {}"
    var result = <InterfaceType>[];
    final classesSeen = <InterfaceElement>{};
    var typesToVisit = <InterfaceType>[type];
    while (typesToVisit.isNotEmpty) {
      var nextType = typesToVisit.removeLast();
      if (!classesSeen.add(nextType.element2)) {
        // Class had already been seen, so ignore this type.
        continue;
      }
      result.add(nextType);
      // typesToVisit is a stack, so push on the interfaces first, then the
      // superclass, then the mixins.  This will ensure that they are visited
      // in the reverse order.
      typesToVisit.addAll(nextType.interfaces);
      var superclass = nextType.superclass;
      if (superclass != null) {
        typesToVisit.add(superclass);
      }
      typesToVisit.addAll(nextType.superclassConstraints);
      typesToVisit.addAll(nextType.mixins);
    }
    return result;
  }
}
