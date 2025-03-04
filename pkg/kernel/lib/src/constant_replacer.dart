// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

import '../ast.dart';

/// Replacement visitor to clone a Constant if a subnode is replaced, and
/// otherwise returns `null`.
class ConstantReplacer implements ConstantVisitor<Constant?> {
  ConstantReplacer();
  final Map<Constant, Constant?> cache = {};

  /// Like with Constants, `null` is used to signal that the [type] has not
  /// changed.
  DartType? visitDartType(DartType type) => null;

  /// Unlike Constants and DartTypes, TreeNodes' equality checks are not
  /// structural and therefore can be checked directly without needing `null`.
  TreeNode visitTreeNode(TreeNode node) => node;

  /// Returns a new type list that contains the recursively visited [types].
  ///
  /// Returns `null` if a recursive visit of [types] does not change the list.
  List<DartType>? visitDartTypeList(List<DartType> types) {
    List<DartType>? newTypes;
    for (int i = 0; i < types.length; i++) {
      DartType? result = visitDartType(types[i]);
      if (result != null) {
        (newTypes ??= List.of(types))[i] = result;
      }
    }
    return newTypes;
  }

  /// Returns a new Constant list that contains the recursively visited
  /// [constants].
  ///
  /// Returns `null` if a recursive visit of [constants] does not change the
  /// list.
  List<Constant>? visitConstantList(List<Constant> constants) {
    List<Constant>? newConstants;
    for (int i = 0; i < constants.length; i++) {
      Constant? result = visitConstant(constants[i]);
      if (result != null) {
        (newConstants ??= List.of(constants))[i] = result;
      }
    }
    return newConstants;
  }

  /// By default, don't change the [node].
  @override
  Constant? defaultConstant(Constant node) => null;

  /// Visits [node] if not already visited to compute a value for [node].
  ///
  /// If the value has already been computed the cached value is returned
  /// immediately.
  ///
  /// Call this method to compute values for subnodes recursively, while only
  /// visiting each subnode once.
  Constant? visitConstant(Constant node) {
    if (cache.containsKey(node)) return cache[node];
    return cache[node] = node.accept(this);
  }

  @override
  Constant? visitBoolConstant(BoolConstant node) => defaultConstant(node);

  @override
  Constant? visitConstructorTearOffConstant(ConstructorTearOffConstant node) =>
      defaultConstant(node);

  @override
  Constant? visitDoubleConstant(DoubleConstant node) => defaultConstant(node);

  @override
  Constant? visitIntConstant(IntConstant node) => defaultConstant(node);

  @override
  Constant? visitNullConstant(NullConstant node) => defaultConstant(node);

  @override
  Constant? visitRedirectingFactoryTearOffConstant(
          RedirectingFactoryTearOffConstant node) =>
      defaultConstant(node);

  @override
  Constant? visitStaticTearOffConstant(StaticTearOffConstant node) =>
      defaultConstant(node);

  @override
  Constant? visitStringConstant(StringConstant node) => defaultConstant(node);

  @override
  Constant? visitSymbolConstant(SymbolConstant node) => defaultConstant(node);

  @override
  Constant? visitInstanceConstant(InstanceConstant node) {
    List<DartType>? typeArguments = visitDartTypeList(node.typeArguments);
    Map<Reference, Constant>? fieldValues;
    for (Reference reference in node.fieldValues.keys) {
      Constant? result = visitConstant(node.fieldValues[reference]!);
      if (result != null) {
        (fieldValues ??= Map.of(node.fieldValues))[reference] = result;
      }
    }
    if (typeArguments == null && fieldValues == null) {
      return null;
    } else {
      return InstanceConstant(node.classReference,
          typeArguments ?? node.typeArguments, fieldValues ?? node.fieldValues);
    }
  }

  @override
  Constant? visitInstantiationConstant(InstantiationConstant node) {
    List<DartType>? types = visitDartTypeList(node.types);
    Constant? tearOffConstant = visitConstant(node.tearOffConstant);
    if (types == null && tearOffConstant == null) {
      return null;
    } else {
      return InstantiationConstant(
          tearOffConstant ?? node.tearOffConstant, types ?? node.types);
    }
  }

  @override
  Constant? visitListConstant(ListConstant node) {
    DartType? typeArgument = visitDartType(node.typeArgument);
    List<Constant>? entries = visitConstantList(node.entries);
    if (typeArgument == null && entries == null) {
      return null;
    } else {
      return ListConstant(
          typeArgument ?? node.typeArgument, entries ?? node.entries);
    }
  }

  @override
  Constant? visitMapConstant(MapConstant node) {
    DartType? keyType = visitDartType(node.keyType);
    DartType? valueType = visitDartType(node.valueType);
    List<ConstantMapEntry>? entries;
    for (int i = 0; i < node.entries.length; i++) {
      ConstantMapEntry entry = node.entries[i];
      Constant? key = visitConstant(entry.key);
      Constant? value = visitConstant(entry.value);
      if (key != null || value != null) {
        (entries ??= List.of(node.entries))[i] =
            ConstantMapEntry(key ?? entry.key, value ?? entry.value);
      }
    }
    if (keyType == null && valueType == null && entries == null) {
      return null;
    } else {
      return MapConstant(keyType ?? node.keyType, valueType ?? node.valueType,
          entries ?? node.entries);
    }
  }

  @override
  Constant? visitSetConstant(SetConstant node) {
    DartType? typeArgument = visitDartType(node.typeArgument);
    List<Constant>? entries = visitConstantList(node.entries);
    if (typeArgument == null && entries == null) {
      return null;
    } else {
      return SetConstant(
          typeArgument ?? node.typeArgument, entries ?? node.entries);
    }
  }

  @override
  Constant? visitTypeLiteralConstant(TypeLiteralConstant node) {
    DartType? type = visitDartType(node.type);
    return type == null ? null : TypeLiteralConstant(type);
  }

  @override
  Constant? visitTypedefTearOffConstant(TypedefTearOffConstant node) {
    TearOffConstant? tearOffConstant =
        visitConstant(node.tearOffConstant) as TearOffConstant?;
    List<DartType>? types = visitDartTypeList(node.types);
    List<TypeParameter>? parameters;
    for (int i = 0; i < node.parameters.length; i++) {
      TypeParameter result = visitTreeNode(node.parameters[i]) as TypeParameter;
      if (result != node.parameters[i]) {
        (parameters ??= List.of(node.parameters))[i] = result;
      }
    }
    if (tearOffConstant == null && types == null && parameters == null) {
      return null;
    } else {
      return TypedefTearOffConstant(parameters ?? node.parameters,
          tearOffConstant ?? node.tearOffConstant, types ?? node.types);
    }
  }

  @override
  Constant? visitUnevaluatedConstant(UnevaluatedConstant node) {
    Expression expression = visitTreeNode(node.expression) as Expression;
    if (expression == node.expression) {
      return null;
    } else {
      return UnevaluatedConstant(expression);
    }
  }
}
