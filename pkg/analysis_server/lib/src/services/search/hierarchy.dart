// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:analysis_server/src/services/search/element_visitors.dart';
import 'package:analysis_server/src/services/search/search_engine.dart';
import 'package:analyzer/dart/element/element.dart';

/// Returns direct children of [parent].
List<Element> getChildren(Element parent, [String? name]) {
  var children = <Element>[];
  visitChildren(parent, (Element element) {
    if (name == null || _getBaseName(element) == name) {
      children.add(element);
    }
    return false;
  });
  return children;
}

/// Returns direct non-synthetic children of the given [ClassElement].
///
/// Includes: fields, accessors and methods.
/// Excludes: constructors and synthetic elements.
List<Element> getClassMembers(InterfaceElement clazz, [String? name]) {
  var members = <Element>[];
  visitChildren(clazz, (Element element) {
    if (element.isSynthetic) {
      return false;
    }
    if (element is ConstructorElement) {
      return false;
    }
    if (name != null && element.displayName != name) {
      return false;
    }
    if (element is ExecutableElement) {
      members.add(element);
    }
    if (element is FieldElement) {
      members.add(element);
    }
    return false;
  });
  return members;
}

/// Returns a [Set] with direct subclasses of [seed].
Future<Set<ClassElement>> getDirectSubClasses(
    SearchEngine searchEngine, InterfaceElement seed) async {
  var matches = await searchEngine.searchSubtypes(seed);
  return matches.map((match) => match.element).cast<ClassElement>().toSet();
}

/// Return the non-synthetic children of the given [extension]. This includes
/// fields, accessors and methods, but excludes synthetic elements.
List<Element> getExtensionMembers(ExtensionElement extension, [String? name]) {
  var members = <Element>[];
  visitChildren(extension, (Element element) {
    if (element.isSynthetic) {
      return false;
    }
    if (name != null && element.displayName != name) {
      return false;
    }
    if (element is ExecutableElement) {
      members.add(element);
    }
    if (element is FieldElement) {
      members.add(element);
    }
    return false;
  });
  return members;
}

/// Return all implementations of the given [member], its superclasses, and
/// their subclasses.
Future<Set<ClassMemberElement>> getHierarchyMembers(
    SearchEngine searchEngine, ClassMemberElement member) async {
  Set<ClassMemberElement> result = HashSet<ClassMemberElement>();
  // extension member
  var enclosingElement = member.enclosingElement3;
  if (enclosingElement is ExtensionElement) {
    result.add(member);
    return Future.value(result);
  }
  // static elements
  if (member.isStatic || member is ConstructorElement) {
    result.add(member);
    return Future.value(result);
  }
  // method, field, etc
  if (enclosingElement is ClassElement) {
    var name = member.displayName;
    var searchClasses = [
      ...enclosingElement.allSupertypes.map((e) => e.element2),
      enclosingElement,
    ];
    for (var superClass in searchClasses) {
      // ignore if super- class does not declare member
      if (getClassMembers(superClass, name).isEmpty) {
        continue;
      }
      // check all sub- classes
      var subClasses = await searchEngine.searchAllSubtypes(superClass);
      subClasses.add(superClass);
      for (var subClass in subClasses) {
        var subClassMembers = getChildren(subClass, name);
        for (var member in subClassMembers) {
          if (member is ClassMemberElement) {
            result.add(member);
          }
        }
      }
    }
  }

  return result;
}

/// If the [element] is a named parameter in a [MethodElement], return all
/// corresponding named parameters in the method hierarchy.
Future<List<ParameterElement>> getHierarchyNamedParameters(
    SearchEngine searchEngine, ParameterElement element) async {
  if (element.isNamed) {
    var method = element.enclosingElement3;
    if (method is MethodElement) {
      var hierarchyParameters = <ParameterElement>[];
      var hierarchyMembers = await getHierarchyMembers(searchEngine, method);
      for (var hierarchyMethod in hierarchyMembers) {
        if (hierarchyMethod is MethodElement) {
          for (var hierarchyParameter in hierarchyMethod.parameters) {
            if (hierarchyParameter.isNamed &&
                hierarchyParameter.name == element.name) {
              hierarchyParameters.add(hierarchyParameter);
              break;
            }
          }
        }
      }
      return hierarchyParameters;
    }
  }
  return [element];
}

/// Returns non-synthetic members of the given [ClassElement] and its super
/// classes.
///
/// Includes: fields, accessors and methods.
///
/// Excludes: constructors and synthetic elements.
List<Element> getMembers(InterfaceElement clazz) {
  var classElements = [
    ...clazz.allSupertypes.map((e) => e.element2),
    clazz,
  ];
  var members = <Element>[];
  for (var superClass in classElements) {
    members.addAll(getClassMembers(superClass));
  }
  return members;
}

/// If the given [element] is a synthetic [PropertyAccessorElement] returns
/// its variable, otherwise returns [element].
Element getSyntheticAccessorVariable(Element element) {
  if (element is PropertyAccessorElement) {
    if (element.isSynthetic) {
      return element.variable;
    }
  }
  return element;
}

String? _getBaseName(Element element) {
  if (element is PropertyAccessorElement && element.isSetter) {
    var name = element.name;
    return name.substring(0, name.length - 1);
  }
  return element.name;
}
