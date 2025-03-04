// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class Class {
  external Class.generative({bool defaultValue: true});
  external const Class.constGenerative({bool defaultValue: true});
}

class Class2 {
  int field;

  external Class2(int field);
}
