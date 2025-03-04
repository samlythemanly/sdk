// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/type_environment.dart';

import '../../base/common.dart';
import '../builder/builder.dart';
import '../builder/class_builder.dart';
import '../builder/extension_builder.dart';
import '../builder/library_builder.dart';
import '../builder/metadata_builder.dart';
import '../builder/procedure_builder.dart';
import '../builder/type_builder.dart';
import '../builder/type_variable_builder.dart';
import '../fasta_codes.dart'
    show
        messagePatchDeclarationMismatch,
        messagePatchDeclarationOrigin,
        noLength,
        templateExtensionMemberConflictsWithObjectMember;
import '../kernel/kernel_helper.dart';
import '../operator.dart';
import '../problems.dart';
import '../scope.dart';
import '../util/helpers.dart';
import 'source_field_builder.dart';
import 'source_library_builder.dart';
import 'source_member_builder.dart';
import 'source_procedure_builder.dart';

const String extensionThisName = '#this';

class SourceExtensionBuilder extends ExtensionBuilderImpl {
  final Extension _extension;

  SourceExtensionBuilder? _origin;
  SourceExtensionBuilder? patchForTesting;

  @override
  final List<TypeVariableBuilder>? typeParameters;

  @override
  final TypeBuilder onType;

  final ExtensionTypeShowHideClauseBuilder extensionTypeShowHideClauseBuilder;

  SourceExtensionBuilder(
      List<MetadataBuilder>? metadata,
      int modifiers,
      String name,
      this.typeParameters,
      this.onType,
      this.extensionTypeShowHideClauseBuilder,
      Scope scope,
      SourceLibraryBuilder parent,
      bool isExtensionTypeDeclaration,
      int startOffset,
      int nameOffset,
      int endOffset,
      Extension? referenceFrom)
      : _extension = new Extension(
            name: name,
            fileUri: parent.fileUri,
            typeParameters:
                TypeVariableBuilder.typeParametersFromBuilders(typeParameters),
            reference: referenceFrom?.reference)
          ..isExtensionTypeDeclaration = isExtensionTypeDeclaration
          ..fileOffset = nameOffset,
        super(metadata, modifiers, name, parent, nameOffset, scope);

  @override
  SourceLibraryBuilder get libraryBuilder =>
      super.libraryBuilder as SourceLibraryBuilder;

  @override
  SourceExtensionBuilder get origin => _origin ?? this;

  @override
  Extension get extension => isPatch ? origin._extension : _extension;

  /// Builds the [Extension] for this extension build and inserts the members
  /// into the [Library] of [libraryBuilder].
  ///
  /// [addMembersToLibrary] is `true` if the extension members should be added
  /// to the library. This is `false` if the extension is in conflict with
  /// another library member. In this case, the extension member should not be
  /// added to the library to avoid name clashes with other members in the
  /// library.
  Extension build(LibraryBuilder coreLibrary,
      {required bool addMembersToLibrary}) {
    _extension.onType = onType.build(libraryBuilder, TypeUse.extensionOnType);
    extensionTypeShowHideClauseBuilder.buildAndStoreTypes(
        _extension, libraryBuilder);

    SourceLibraryBuilder.checkMemberConflicts(libraryBuilder, scope,
        checkForInstanceVsStaticConflict: true,
        checkForMethodVsSetterConflict: true);

    ClassBuilder objectClassBuilder =
        coreLibrary.lookupLocalMember('Object', required: true) as ClassBuilder;

    void buildBuilders(String name, Builder declaration) {
      Builder? objectGetter = objectClassBuilder.lookupLocalMember(name);
      Builder? objectSetter =
          objectClassBuilder.lookupLocalMember(name, setter: true);
      if (objectGetter != null && !objectGetter.isStatic ||
          objectSetter != null && !objectSetter.isStatic) {
        addProblem(
            templateExtensionMemberConflictsWithObjectMember
                .withArguments(name),
            declaration.charOffset,
            name.length);
      }
      if (declaration.parent != this) {
        if (fileUri != declaration.parent!.fileUri) {
          unexpected("$fileUri", "${declaration.parent!.fileUri}", charOffset,
              fileUri);
        } else {
          unexpected(fullNameForErrors, declaration.parent!.fullNameForErrors,
              charOffset, fileUri);
        }
      } else if (declaration is SourceMemberBuilder) {
        SourceMemberBuilder memberBuilder = declaration;
        memberBuilder
            .buildOutlineNodes((Member member, BuiltMemberKind memberKind) {
          _buildMember(memberBuilder, member, memberKind,
              addMembersToLibrary: addMembersToLibrary);
        });
      } else {
        unhandled("${declaration.runtimeType}", "buildBuilders",
            declaration.charOffset, declaration.fileUri);
      }
    }

    scope.unfilteredNameIterator.forEach(buildBuilders);

    return _extension;
  }

  void _buildMember(SourceMemberBuilder memberBuilder, Member member,
      BuiltMemberKind memberKind,
      {required bool addMembersToLibrary}) {
    if (addMembersToLibrary &&
        !memberBuilder.isPatch &&
        !memberBuilder.isDuplicate &&
        !memberBuilder.isConflictingSetter) {
      ExtensionMemberKind kind;
      String name = memberBuilder.name;
      switch (memberKind) {
        case BuiltMemberKind.Constructor:
        case BuiltMemberKind.RedirectingFactory:
        case BuiltMemberKind.Field:
        case BuiltMemberKind.Method:
          unhandled("${member.runtimeType}:${memberKind}", "buildMembers",
              memberBuilder.charOffset, memberBuilder.fileUri);
        case BuiltMemberKind.ExtensionField:
        case BuiltMemberKind.LateIsSetField:
          kind = ExtensionMemberKind.Field;
          break;
        case BuiltMemberKind.ExtensionMethod:
          kind = ExtensionMemberKind.Method;
          break;
        case BuiltMemberKind.ExtensionGetter:
        case BuiltMemberKind.LateGetter:
          kind = ExtensionMemberKind.Getter;
          break;
        case BuiltMemberKind.ExtensionSetter:
        case BuiltMemberKind.LateSetter:
          kind = ExtensionMemberKind.Setter;
          break;
        case BuiltMemberKind.ExtensionOperator:
          kind = ExtensionMemberKind.Operator;
          break;
        case BuiltMemberKind.ExtensionTearOff:
          kind = ExtensionMemberKind.TearOff;
          break;
      }
      // ignore: unnecessary_null_comparison
      assert(kind != null);
      Reference memberReference;
      if (member is Field) {
        libraryBuilder.library.addField(member);
        memberReference = member.fieldReference;
      } else if (member is Procedure) {
        libraryBuilder.library.addProcedure(member);
        memberReference = member.reference;
      } else {
        unhandled("${member.runtimeType}", "buildBuilders", member.fileOffset,
            member.fileUri);
      }
      extension.members.add(new ExtensionMemberDescriptor(
          name: new Name(name, libraryBuilder.library),
          member: memberReference,
          isStatic: memberBuilder.isStatic,
          kind: kind));
    }
  }

  @override
  void applyPatch(Builder patch) {
    if (patch is SourceExtensionBuilder) {
      patch._origin = this;
      if (retainDataForTesting) {
        patchForTesting = patch;
      }
      scope.forEachLocalMember((String name, Builder member) {
        Builder? memberPatch =
            patch.scope.lookupLocalMember(name, setter: false);
        if (memberPatch != null) {
          member.applyPatch(memberPatch);
        }
      });
      scope.forEachLocalSetter((String name, Builder member) {
        Builder? memberPatch =
            patch.scope.lookupLocalMember(name, setter: true);
        if (memberPatch != null) {
          member.applyPatch(memberPatch);
        }
      });

      // TODO(johnniwinther): Check that type parameters and on-type match
      // with origin declaration.
    } else {
      libraryBuilder.addProblem(messagePatchDeclarationMismatch,
          patch.charOffset, noLength, patch.fileUri, context: [
        messagePatchDeclarationOrigin.withLocation(
            fileUri, charOffset, noLength)
      ]);
    }
  }

  int buildBodyNodes({required bool addMembersToLibrary}) {
    int count = 0;
    scope
        .filteredIterator<SourceMemberBuilder>(
            parent: this, includeDuplicates: false, includeAugmentations: true)
        .forEach((SourceMemberBuilder declaration) {
      count +=
          declaration.buildBodyNodes((Member member, BuiltMemberKind kind) {
        _buildMember(declaration, member, kind,
            addMembersToLibrary: addMembersToLibrary);
      });
    });
    return count;
  }

  void checkTypesInOutline(TypeEnvironment typeEnvironment) {
    forEach((String name, Builder builder) {
      if (builder is SourceFieldBuilder) {
        // Check fields.
        libraryBuilder.checkTypesInField(builder, typeEnvironment);
      } else if (builder is SourceProcedureBuilder) {
        // Check procedures
        libraryBuilder.checkTypesInFunctionBuilder(builder, typeEnvironment);
        if (builder.isGetter) {
          Builder? setterDeclaration =
              scope.lookupLocalMember(builder.name, setter: true);
          if (setterDeclaration != null) {
            libraryBuilder.checkGetterSetterTypes(builder,
                setterDeclaration as ProcedureBuilder, typeEnvironment);
          }
        }
      } else {
        assert(false, "Unexpected member: $builder.");
      }
    });
  }

  void buildOutlineExpressions(
      ClassHierarchy classHierarchy,
      List<DelayedActionPerformer> delayedActionPerformers,
      List<DelayedDefaultValueCloner> delayedDefaultValueCloners) {
    MetadataBuilder.buildAnnotations(isPatch ? origin.extension : extension,
        metadata, libraryBuilder, this, null, fileUri, libraryBuilder.scope);
    if (typeParameters != null) {
      for (int i = 0; i < typeParameters!.length; i++) {
        typeParameters![i].buildOutlineExpressions(libraryBuilder, this, null,
            classHierarchy, delayedActionPerformers, scope.parent!);
      }
    }

    void build(SourceMemberBuilder member) {
      member.buildOutlineExpressions(
          classHierarchy, delayedActionPerformers, delayedDefaultValueCloners);
    }

    scope
        .filteredIterator<SourceMemberBuilder>(
            parent: this, includeDuplicates: false, includeAugmentations: true)
        .forEach(build);
  }
}

class ExtensionTypeShowHideClauseBuilder {
  final List<TypeBuilder> shownSupertypes;
  final List<String> shownGetters;
  final List<String> shownSetters;
  final List<String> shownMembersOrTypes;
  final List<Operator> shownOperators;

  final List<TypeBuilder> hiddenSupertypes;
  final List<String> hiddenGetters;
  final List<String> hiddenSetters;
  final List<String> hiddenMembersOrTypes;
  final List<Operator> hiddenOperators;

  ExtensionTypeShowHideClauseBuilder(
      {required this.shownSupertypes,
      required this.shownGetters,
      required this.shownSetters,
      required this.shownMembersOrTypes,
      required this.shownOperators,
      required this.hiddenSupertypes,
      required this.hiddenGetters,
      required this.hiddenSetters,
      required this.hiddenMembersOrTypes,
      required this.hiddenOperators});

  void buildAndStoreTypes(Extension extension, LibraryBuilder libraryBuilder) {
    List<Supertype> builtShownSupertypes =
        shownSupertypes.map((t) => t.buildSupertype(libraryBuilder)!).toList();
    List<Supertype> builtHiddenSupertypes =
        hiddenSupertypes.map((t) => t.buildSupertype(libraryBuilder)!).toList();
    ExtensionTypeShowHideClause showHideClause =
        extension.showHideClause ?? new ExtensionTypeShowHideClause();
    showHideClause.shownSupertypes.addAll(builtShownSupertypes);
    showHideClause.hiddenSupertypes.addAll(builtHiddenSupertypes);
    extension.showHideClause ??= showHideClause;
  }
}
