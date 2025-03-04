// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'class_test.dart' as class_;
import 'enum_test.dart' as enum_;
import 'library_test.dart' as library_;

/// Tests suggestions produced for various kinds of declarations.
void main() {
  defineReflectiveSuite(() {
    class_.main();
    enum_.main();
    library_.main();
  });
}
