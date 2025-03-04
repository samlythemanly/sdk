// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class Benchmarker {
  final List<PhaseTiming> _phaseTimings =
      new List<PhaseTiming>.generate(BenchmarkPhases.values.length, (index) {
    assert(BenchmarkPhases.values[index].index == index);
    return new PhaseTiming(BenchmarkPhases.values[index]);
  }, growable: false);

  final Stopwatch _totalStopwatch = new Stopwatch()..start();
  final Stopwatch _phaseStopwatch = new Stopwatch()..start();
  final Stopwatch _subdivideStopwatch = new Stopwatch()..start();

  BenchmarkPhases _currentPhase = BenchmarkPhases.implicitInitialization;
  BenchmarkSubdivides? _subdivide;
  int _subdivideLayer = 0;

  void reset() {
    _totalStopwatch.start();
    _totalStopwatch.reset();
    _phaseStopwatch.start();
    _phaseStopwatch.reset();
    _subdivideStopwatch.start();
    _subdivideStopwatch.reset();
    for (int i = 0; i < _phaseTimings.length; i++) {
      assert(BenchmarkPhases.values[i].index == i);
      _phaseTimings[i] = new PhaseTiming(BenchmarkPhases.values[i]);
    }
    _currentPhase = BenchmarkPhases.implicitInitialization;
    _subdivide = null;
    _subdivideLayer = 0;
  }

  void beginSubdivide(final BenchmarkSubdivides phase) {
    _subdivideLayer++;
    if (_subdivideLayer != 1) return;
    BenchmarkSubdivides? subdivide = _subdivide;
    assert(subdivide == null);
    _subdivideStopwatch.reset();
    _subdivide = phase;
  }

  void endSubdivide() {
    _subdivideLayer--;
    assert(_subdivideLayer >= 0);
    if (_subdivideLayer != 0) return;
    BenchmarkSubdivides? subdivide = _subdivide;
    if (subdivide == null) throw "Can't end a nonexistent subdivide";
    _phaseTimings[_currentPhase.index]
        .subdivides[subdivide.index]
        .addRuntime(_subdivideStopwatch.elapsedMicroseconds);
    _subdivide = null;
  }

  void enterPhase(BenchmarkPhases phase) {
    if (_currentPhase == phase) return;
    if (_subdivide != null) throw "Can't enter a phase while in a subdivide";

    _phaseTimings[_currentPhase.index]
        .addRuntime(_phaseStopwatch.elapsedMicroseconds);
    _phaseStopwatch.reset();
    _currentPhase = phase;
  }

  void stop() {
    enterPhase(BenchmarkPhases.end);
    _totalStopwatch.stop();
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      "totalTime": _totalStopwatch.elapsedMicroseconds,
      "phases": _phaseTimings,
    };
  }
}

class PhaseTiming {
  final BenchmarkPhases phase;
  int _runtime = 0;

  final List<SubdivideTiming> subdivides = new List<SubdivideTiming>.generate(
      BenchmarkSubdivides.values.length, (index) {
    assert(BenchmarkSubdivides.values[index].index == index);
    return new SubdivideTiming(BenchmarkSubdivides.values[index]);
  }, growable: false);

  PhaseTiming(this.phase);

  void addRuntime(int runtime) {
    _runtime += runtime;
  }

  Map<String, Object?> toJson() {
    List<SubdivideTiming> enteredSubdivides =
        subdivides.where((element) => element._count > 0).toList();
    return <String, Object?>{
      "phase": phase.name,
      "runtime": _runtime,
      if (enteredSubdivides.isNotEmpty) "subdivides": enteredSubdivides,
    };
  }
}

class SubdivideTiming {
  final BenchmarkSubdivides phase;
  int _runtime = 0;
  int _count = 0;

  SubdivideTiming(this.phase);

  void addRuntime(int runtime) {
    _runtime += runtime;
    _count++;
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      "phase": phase.name,
      "runtime": _runtime,
      "count": _count,
    };
  }
}

enum BenchmarkPhases {
  implicitInitialization,
  loadSDK,
  loadAdditionalDills,

  dill_buildOutlines,
  dill_finalizeExports,

  outline_kernelBuildOutlines,
  outline_becomeCoreLibrary,
  outline_resolveParts,
  outline_computeMacroDeclarations,
  outline_computeLibraryScopes,
  outline_computeMacroApplications,
  outline_setupTopAndBottomTypes,
  outline_resolveTypes,
  outline_computeVariances,
  outline_computeDefaultTypes,
  outline_applyTypeMacros,
  outline_buildMacroTypesForPhase1,
  outline_checkSemantics,
  outline_finishTypeVariables,
  outline_createTypeInferenceEngine,
  outline_buildComponent,
  outline_installDefaultSupertypes,
  outline_installSyntheticConstructors,
  outline_resolveConstructors,
  outline_link,
  outline_computeCoreTypes,
  outline_buildClassHierarchy,
  outline_checkSupertypes,
  outline_applyDeclarationMacros,
  outline_buildMacroDeclarationsForPhase1,
  outline_buildMacroDeclarationsForPhase2,
  outline_buildClassHierarchyMembers,
  outline_computeHierarchy,
  outline_computeShowHideElements,
  outline_installTypedefTearOffs,
  outline_performTopLevelInference,
  outline_checkOverrides,
  outline_checkAbstractMembers,
  outline_addNoSuchMethodForwarders,
  outline_checkMixins,
  outline_buildOutlineExpressions,
  outline_checkTypes,
  outline_checkRedirectingFactories,
  outline_finishSynthesizedParameters,
  outline_checkMainMethods,
  outline_installAllComponentProblems,

  body_buildBodies,
  body_checkMixinSuperAccesses,
  body_finishSynthesizedParameters,
  body_finishDeferredLoadTearoffs,
  body_finishNoSuchMethodForwarders,
  body_collectSourceClasses,
  body_applyDefinitionMacros,
  body_buildMacroDefinitionsForPhase1,
  body_buildMacroDefinitionsForPhase2,
  body_buildMacroDefinitionsForPhase3,
  body_finishNativeMethods,
  body_finishPatchMethods,
  body_finishAllConstructors,
  body_runBuildTransformations,
  body_verify,
  body_installAllComponentProblems,

  printComponentText,
  omitPlatform,
  writeComponent,
  benchmarkAstVisit,

  incremental_setupPackages,
  incremental_ensurePlatform,
  incremental_invalidate,
  incremental_experimentalInvalidation,
  incremental_rewriteEntryPointsIfPart,
  incremental_invalidatePrecompiledMacros,
  incremental_cleanup,
  incremental_loadEnsureLoadedComponents,
  incremental_setupInLoop,
  incremental_precompileMacros,
  incremental_experimentalInvalidationPatchUpScopes,
  incremental_hierarchy,
  incremental_performDillUsageTracking,
  incremental_releaseAncillaryResources,
  incremental_experimentalCompilationPostCompilePatchup,
  incremental_calculateOutputLibrariesAndIssueLibraryProblems,
  incremental_convertSourceLibraryBuildersToDill,
  incremental_end,

  precompileMacros,

  // add more here
  //
  end,
  unknown,
  unknownDillTarget,
  unknownComputeNeededPrecompilations,
  unknownBuildOutlines,
  unknownBuildComponent,
  unknownGenerateKernelInternal,
}

enum BenchmarkSubdivides {
  tokenize,

  body_buildBody_benchmark_specific_diet_parser,
  body_buildBody_benchmark_specific_parser,

  inferImplicitFieldType,
  inferFieldInitializer,
  inferFunctionBody,
  inferInitializer,
  inferMetadata,
  inferParameterInitializer,
  inferRedirectingFactoryTypeArguments,

  buildOutlineExpressions,
  delayedActionPerformer,

  computeMacroApplications_macroExecutorProvider,
  macroApplications_macroExecutorLoadMacro,
  macroApplications_macroExecutorInstantiateMacro,
}
