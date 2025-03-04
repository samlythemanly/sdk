// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'dwarf_container.dart';
import 'elf.dart';
import 'macho.dart';
import 'reader.dart';

const String _debugStringTableKey = 'debugStringTable';
const String _debugLineStringTableKey = 'debugLineStringTable';

int _initialLengthValue(Reader reader) {
  final length = reader.readBytes(4);
  if (length == 0xffffffff) {
    throw FormatException('64-bit DWARF format detected');
  } else if (length > 0xfffffff0) {
    throw FormatException('Unrecognized reserved initial length value');
  }
  return length;
}

enum _Tag {
  // Snake case used to match DWARF specification.
  compile_unit(0x11),
  inlined_subroutine(0x1d),
  subprogram(0x2e);

  final int code;

  const _Tag(this.code);

  static const _prefix = 'DW_TAG';

  static _Tag fromReader(Reader reader) {
    final code = reader.readLEB128EncodedInteger();
    for (final name in values) {
      if (name.code == code) {
        return name;
      }
    }
    throw FormatException(
        'Unexpected $_prefix code 0x${code.toRadixString(16)}');
  }

  @override
  String toString() => '${_prefix}_$name';
}

enum _AttributeName {
  // Snake case used to match DWARF specification.
  sibling(0x01),
  // Avoiding conflict with enum 'name' property
  nameValue(0x03),
  stmt_list(0x10),
  low_pc(0x11),
  high_pc(0x12),
  comp_dir(0x1b),
  inline(0x20),
  producer(0x25),
  abstract_origin(0x31),
  artificial(0x34),
  decl_column(0x39),
  decl_file(0x3a),
  decl_line(0x3b),
  call_column(0x57),
  call_file(0x58),
  call_line(0x59);

  final int code;

  const _AttributeName(this.code);

  static const _prefix = 'DW_AT';

  static _AttributeName? fromReader(Reader reader) {
    final code = reader.readLEB128EncodedInteger();
    if (code == 0x00) return null; // Used as end marker in some cases.
    for (final name in values) {
      if (name.code == code) {
        return name;
      }
    }
    throw FormatException(
        'Unexpected $_prefix code 0x${code.toRadixString(16)}');
  }

  @override
  String toString() => '${_prefix}_${this == nameValue ? 'name' : name}';
}

enum _AttributeForm {
  // Snake case used to match DWARF specification.
  addr(0x01),
  data2(0x05),
  data4(0x06),
  data8(0x07),
  string(0x08),
  data1(0x0b),
  flag(0x0c),
  strp(0x0e),
  udata(0x0f),
  ref4(0x13),
  sec_offset(0x17),
  data16(0x1e),
  line_strp(0x1f);

  final int code;

  const _AttributeForm(this.code);

  static const _prefix = 'DW_FORM';

  static _AttributeForm? fromReader(Reader reader) {
    final code = reader.readLEB128EncodedInteger();
    if (code == 0x00) return null; // Used as end marker in some cases.
    for (final name in values) {
      if (name.code == code) {
        return name;
      }
    }
    throw FormatException('Unexpected $_prefix code '
        '0x${code.toRadixString(16)}');
  }

  Object read(Reader reader, {int? addressSize}) {
    switch (this) {
      case _AttributeForm.string:
        return reader.readNullTerminatedString();
      case _AttributeForm.strp:
        final offset = reader.readBytes(4); // Assumed 32-bit DWARF
        final debugStringTable =
            Zone.current[_debugStringTableKey] as DwarfContainerStringTable?;
        if (debugStringTable == null) {
          throw FormatException('No .debug_str available');
        }
        return debugStringTable[offset]!;
      case _AttributeForm.line_strp:
        final offset = reader.readBytes(4); // Assumed 32-bit DWARF
        final debugLineStringTable = Zone.current[_debugLineStringTableKey]
            as DwarfContainerStringTable?;
        if (debugLineStringTable == null) {
          throw FormatException('No .debug_line_str available');
        }
        return debugLineStringTable[offset]!;
      case _AttributeForm.flag:
        return reader.readByte() != 0;
      case _AttributeForm.addr:
        if (addressSize == null) {
          throw FormatException('No address size available');
        }
        return reader.readBytes(addressSize);
      case _AttributeForm.data1:
        return reader.readByte();
      case _AttributeForm.data2:
        return reader.readBytes(2);
      case _AttributeForm.sec_offset: // Assumed 32-bit DWARF
      case _AttributeForm.data4:
      case _AttributeForm.ref4:
        return reader.readBytes(4);
      case _AttributeForm.data8:
        return reader.readBytes(8);
      case _AttributeForm.udata:
        return reader.readLEB128EncodedInteger();
      case _AttributeForm.data16:
        return reader.readRawBytes(16);
    }
  }

  String valueToString(Object value,
      {CompilationUnit? unit, int? addressSize}) {
    switch (this) {
      case _AttributeForm.string:
      case _AttributeForm.strp:
      case _AttributeForm.line_strp:
        return value as String;
      case _AttributeForm.flag:
        return value.toString();
      case _AttributeForm.addr:
        return '0x${paddedHex(value as int, addressSize ?? 0)}';
      case _AttributeForm.sec_offset:
        return paddedHex(value as int, 4); // Assumed 32-bit DWARF
      case _AttributeForm.data1:
      case _AttributeForm.data2:
      case _AttributeForm.data4:
      case _AttributeForm.data8:
      case _AttributeForm.udata:
        return value.toString();
      case _AttributeForm.ref4:
        final intValue = value as int;
        final unresolvedValue = paddedHex(intValue, 4);
        final name = unit?.nameOfOrigin(intValue) ?? '<unresolved>';
        return '0x$unresolvedValue (origin: $name)';
      case _AttributeForm.data16:
        final bdata = value as ByteData;
        final buffer = StringBuffer();
        for (int i = 0; i < 16; i++) {
          buffer.write(bdata.getUint8(i).toRadixString(16));
        }
        return buffer.toString();
    }
  }

  @override
  String toString() => '${_prefix}_$name';
}

class _Attribute {
  final _AttributeName name;
  final _AttributeForm form;

  _Attribute._(this.name, this.form);

  static _Attribute? fromReader(Reader reader) {
    final name = _AttributeName.fromReader(reader);
    final form = _AttributeForm.fromReader(reader);
    if (name == null || form == null) {
      // If one is null, the other should be null.
      assert(name == null && form == null);
      return null;
    }
    return _Attribute._(name, form);
  }

  Object read(Reader reader, {int? addressSize}) =>
      form.read(reader, addressSize: addressSize);

  String valueToString(Object value,
          {CompilationUnit? unit, int? addressSize}) =>
      form.valueToString(value, unit: unit, addressSize: addressSize);
}

class _Abbreviation {
  final int code;
  final _Tag tag;
  final bool children;
  final List<_Attribute> attributes;

  _Abbreviation._(this.code, this.tag, this.children, this.attributes);

  // Constants from the DWARF specification.
  static const _dwChildrenNo = 0x00;
  static const _dwChildrenYes = 0x01;

  static _Abbreviation? fromReader(Reader reader) {
    final code = reader.readLEB128EncodedInteger();
    if (code == 0) return null;
    final tag = _Tag.fromReader(reader);
    final childrenByte = reader.readByte();
    if (childrenByte != _dwChildrenNo && childrenByte != _dwChildrenYes) {
      throw FormatException('Expected DW_CHILDREN_no or DW_CHILDREN_yes: '
          '$childrenByte');
    }
    final children = childrenByte == _dwChildrenYes;
    final attributes = reader.readRepeated(_Attribute.fromReader).toList();
    return _Abbreviation._(code, tag, children, attributes);
  }

  void writeToStringBuffer(StringBuffer buffer) {
    buffer
      ..write('    Tag: ')
      ..writeln(tag)
      ..write('    Children: ')
      ..writeln(children ? 'DW_CHILDREN_yes' : 'DW_CHILDREN_no')
      ..writeln('    Attributes:');
    for (final attribute in attributes) {
      buffer
        ..write('      ')
        ..write(attribute.name)
        ..write(': ')
        ..writeln(attribute.form);
    }
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

class _AbbreviationsTable {
  final Map<int, _Abbreviation> _abbreviations;

  _AbbreviationsTable._(this._abbreviations);

  bool containsKey(int code) => _abbreviations.containsKey(code);
  _Abbreviation? operator [](int code) => _abbreviations[code];

  static _AbbreviationsTable? fromReader(Reader reader) {
    final abbreviations = Map.fromEntries(reader
        .readRepeated(_Abbreviation.fromReader)
        .map((abbr) => MapEntry(abbr.code, abbr)));
    return _AbbreviationsTable._(abbreviations);
  }

  void writeToStringBuffer(StringBuffer buffer) {
    buffer
      ..writeln('Abbreviations table:')
      ..writeln();
    _abbreviations.forEach((key, abbreviation) {
      buffer
        ..write('  ')
        ..write(key)
        ..writeln(':');
      abbreviation.writeToStringBuffer(buffer);
      buffer.writeln();
    });
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

/// A DWARF Debug Information Entry (DIE).
class DebugInformationEntry {
  // The index of the entry in the abbreviation table for this DIE.
  final int code;
  // ignore: library_private_types_in_public_api
  final Map<_Attribute, Object> attributes;
  final Map<int, DebugInformationEntry> children;

  DebugInformationEntry._(this.code, this.attributes, this.children);

  static DebugInformationEntry? fromReader(
      Reader reader, CompilationUnitHeader header) {
    final code = reader.readLEB128EncodedInteger();
    // DIEs with an abbreviation table index of 0 are list end markers.
    if (code == 0) return null;
    if (!header.abbreviations.containsKey(code)) {
      throw FormatException('Unknown abbreviation code 0x${paddedHex(code)}');
    }
    final abbreviation = header.abbreviations[code]!;
    final attributes = <_Attribute, Object>{};
    for (final attribute in abbreviation.attributes) {
      attributes[attribute] =
          attribute.read(reader, addressSize: header.addressSize);
    }
    final children = <int, DebugInformationEntry>{};
    if (abbreviation.children) {
      children.addEntries(reader.readRepeatedWithOffsets(
          (r) => DebugInformationEntry.fromReader(r, header),
          absolute: true));
    }
    return DebugInformationEntry._(code, attributes, children);
  }

  _Attribute? _namedAttribute(_AttributeName name) {
    for (final attribute in attributes.keys) {
      if (attribute.name == name) {
        return attribute;
      }
    }
    return null;
  }

  // ignore: library_private_types_in_public_api
  bool containsKey(_AttributeName name) => _namedAttribute(name) != null;

  // ignore: library_private_types_in_public_api
  Object? operator [](_AttributeName name) => attributes[_namedAttribute(name)];

  int? get sectionOffset => this[_AttributeName.stmt_list] as int?;

  int? get abstractOrigin => this[_AttributeName.abstract_origin] as int?;

  int? get lowPC => this[_AttributeName.low_pc] as int?;

  int? get highPC => this[_AttributeName.high_pc] as int?;

  bool get isArtificial => (this[_AttributeName.artificial] ?? false) as bool;

  bool containsPC(int virtualAddress) =>
      (lowPC ?? 0) <= virtualAddress && virtualAddress < (highPC ?? -1);

  String? get name => this[_AttributeName.nameValue] as String?;

  int? get callFileIndex => this[_AttributeName.call_file] as int?;

  int? get callLine => this[_AttributeName.call_line] as int?;

  int? get callColumn => this[_AttributeName.call_column] as int?;

  List<CallInfo>? callInfo(
      CompilationUnit unit, LineNumberProgram lineNumberProgram, int address) {
    String callFilename(int index) =>
        lineNumberProgram.header.filesInfo[index]?.name ?? '<unknown file>';
    if (!containsPC(address)) return null;

    final tag = unit.header.abbreviations[code]!.tag;
    final inlined = tag == _Tag.inlined_subroutine;
    for (final child in children.values) {
      final callInfo = child.callInfo(unit, lineNumberProgram, address);
      if (callInfo == null) continue;

      if (tag == _Tag.compile_unit) return callInfo;

      return callInfo
        ..add(DartCallInfo(
            function: unit.nameOfOrigin(abstractOrigin ?? -1),
            inlined: inlined,
            internal: isArtificial,
            filename: callFilename(child.callFileIndex ?? -1),
            line: child.callLine ?? 0,
            column: child.callColumn ?? 0));
    }

    if (tag == _Tag.compile_unit) return null;

    final filename = lineNumberProgram.filename(address)!;
    final line = lineNumberProgram.lineNumber(address)!;
    final column = lineNumberProgram.column(address)!;
    return [
      DartCallInfo(
          function: unit.nameOfOrigin(abstractOrigin ?? -1),
          inlined: inlined,
          internal: isArtificial,
          filename: filename,
          line: line,
          column: column)
    ];
  }

  void writeToStringBuffer(StringBuffer buffer,
      {CompilationUnit? unit, String indent = ''}) {
    buffer
      ..write(indent)
      ..write('Abbreviation code: ')
      ..write(code)
      ..writeln('):');
    attributes.forEach((attribute, value) {
      buffer
        ..write(indent)
        ..write('  ')
        ..write(attribute.name)
        ..write(' => ')
        ..writeln(attribute.valueToString(value, unit: unit));
    });
    if (children.isNotEmpty) {
      buffer
        ..write(indent)
        ..write('Children (')
        ..write(children.length)
        ..writeln('):');
      final sortedChildren = children.entries.toList()
        ..sort((kv1, kv2) => Comparable.compare(kv1.key, kv2.key));
      for (var i = 0; i < sortedChildren.length; i++) {
        final offset = sortedChildren[i].key;
        final child = sortedChildren[i].value;
        buffer
          ..write(indent)
          ..write('Child ')
          ..write(i)
          ..write(' (at offset 0x')
          ..write(paddedHex(offset))
          ..writeln('):');
        child.writeToStringBuffer(buffer, unit: unit, indent: '$indent  ');
      }
    }
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

class CompilationUnitHeader {
  final int size;
  final int version;
  final int abbreviationsOffset;
  final int addressSize;
  // ignore: library_private_types_in_public_api
  final _AbbreviationsTable abbreviations;

  CompilationUnitHeader._(this.size, this.version, this.abbreviationsOffset,
      this.addressSize, this.abbreviations);

  static CompilationUnitHeader? fromReader(
      Reader reader,
      // ignore: library_private_types_in_public_api
      Map<int, _AbbreviationsTable> abbreviationsTables) {
    final size = _initialLengthValue(reader);
    // An empty unit is an ending marker.
    if (size == 0) return null;
    final version = reader.readBytes(2);
    if (version != 2) {
      throw FormatException('Expected DWARF version 2, got $version');
    }
    final abbreviationsOffset = reader.readBytes(4);
    final abbreviationsTable = abbreviationsTables[abbreviationsOffset];
    if (abbreviationsTable == null) {
      throw FormatException('No abbreviation table found for offset '
          '0x${paddedHex(abbreviationsOffset, 4)}');
    }
    final addressSize = reader.readByte();
    return CompilationUnitHeader._(
        size, version, abbreviationsOffset, addressSize, abbreviationsTable);
  }

  void writeToStringBuffer(StringBuffer buffer) {
    buffer
      ..writeln('Compilation unit:')
      ..write('  Size: ')
      ..writeln(size)
      ..write('  Version: ')
      ..writeln(version)
      ..write('  Abbreviations offset: 0x')
      ..writeln(paddedHex(abbreviationsOffset, 4))
      ..write('  Address size: ')
      ..writeln(addressSize)
      ..writeln();
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

/// A class representing a DWARF compilation unit.
class CompilationUnit {
  CompilationUnitHeader header;
  Map<int, DebugInformationEntry> referenceTable;

  CompilationUnit._(this.header, this.referenceTable);

  static CompilationUnit? fromReader(
      Reader reader,
      // ignore: library_private_types_in_public_api
      Map<int, _AbbreviationsTable> abbreviationsTables) {
    final header =
        CompilationUnitHeader.fromReader(reader, abbreviationsTables);
    if (header == null) return null;

    final referenceTable = Map.fromEntries(reader.readRepeatedWithOffsets(
        (r) => DebugInformationEntry.fromReader(r, header),
        absolute: true));
    _addChildEntries(referenceTable);
    return CompilationUnit._(header, referenceTable);
  }

  static void _addChildEntries(Map<int, DebugInformationEntry> table) {
    final workList = Queue<MapEntry<int, DebugInformationEntry>>();
    for (final die in table.values) {
      workList.addAll(die.children.entries);
    }
    while (workList.isNotEmpty) {
      final kv = workList.removeFirst();
      final offset = kv.key;
      final child = kv.value;
      table[offset] = child;
      workList.addAll(child.children.entries);
    }
  }

  Iterable<CallInfo>? callInfo(LineNumberInfo lineNumberInfo, int address) {
    for (final die in referenceTable.values) {
      final lineNumberProgram = lineNumberInfo[die.sectionOffset ?? -1];
      if (lineNumberProgram == null) continue;
      final callInfo = die.callInfo(this, lineNumberProgram, address);
      if (callInfo != null) return callInfo;
    }
    return null;
  }

  String nameOfOrigin(int offset) {
    final origin = referenceTable[offset];
    if (origin == null) {
      throw ArgumentError(
          '${paddedHex(offset)} is not the offset of an abbreviated unit');
    }
    return origin[_AttributeName.nameValue] as String;
  }

  void writeToStringBuffer(StringBuffer buffer) {
    header.writeToStringBuffer(buffer);
    referenceTable.forEach((offset, die) {
      buffer
        ..write('Debug information entry at offset 0x')
        ..write(paddedHex(offset))
        ..writeln(':');
      die.writeToStringBuffer(buffer, unit: this);
      buffer.writeln();
    });
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

/// A class representing a DWARF `.debug_info` section.
class DebugInfo {
  final List<CompilationUnit> units;

  DebugInfo._(this.units);

  static DebugInfo fromReader(
      Reader reader,
      // ignore: library_private_types_in_public_api
      Map<int, _AbbreviationsTable> abbreviationsTable) {
    final units = reader
        .readRepeated(
            (r) => CompilationUnit.fromReader(reader, abbreviationsTable))
        .toList();
    return DebugInfo._(units);
  }

  Iterable<CallInfo>? callInfo(LineNumberInfo lineNumberInfo, int address) {
    for (final unit in units) {
      final callInfo = unit.callInfo(lineNumberInfo, address);
      if (callInfo != null) return callInfo;
    }
    return null;
  }

  void writeToStringBuffer(StringBuffer buffer) {
    for (final unit in units) {
      unit.writeToStringBuffer(buffer);
      buffer.writeln();
    }
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

enum _LineNumberContentType {
  path(0x01),
  directory_index(0x02),
  timestamp(0x03),
  size(0x04),
  md5(0x05);

  final int code;

  const _LineNumberContentType(this.code);

  static const String _prefix = 'DW_LNCT';

  static _LineNumberContentType fromReader(Reader reader) {
    final code = reader.readLEB128EncodedInteger();
    for (final type in values) {
      if (type.code == code) {
        return type;
      }
    }
    throw FormatException('Unexpected $_prefix code '
        '0x${code.toRadixString(16)}');
  }

  void validate(_AttributeForm form) {
    switch (this) {
      case _LineNumberContentType.path:
        if (form == _AttributeForm.string || form == _AttributeForm.line_strp) {
          return;
        }
        break;
      case _LineNumberContentType.directory_index:
        if (form == _AttributeForm.data1 ||
            form == _AttributeForm.data2 ||
            form == _AttributeForm.udata) {
          return;
        }
        break;
      case _LineNumberContentType.timestamp:
        if (form == _AttributeForm.data4 ||
            form == _AttributeForm.data8 ||
            form == _AttributeForm.udata) {
          return;
        }
        break;
      case _LineNumberContentType.size:
        if (form == _AttributeForm.data1 ||
            form == _AttributeForm.data2 ||
            form == _AttributeForm.data4 ||
            form == _AttributeForm.data8 ||
            form == _AttributeForm.udata) {
          return;
        }
        break;
      case _LineNumberContentType.md5:
        if (form == _AttributeForm.data16) {
          return;
        }
        break;
    }
    throw FormatException('Unexpected form $form for $this');
  }

  @override
  String toString() => '${_prefix}_${this == md5 ? 'MD5' : name}';
}

class FileEntry {
  final String name;
  final int directoryIndex;
  final int lastModified;
  final int size;

  FileEntry._(this.name, this.directoryIndex, this.lastModified, this.size);

  static FileEntry? fromReader(Reader reader) {
    final name = reader.readNullTerminatedString();
    // An empty null-terminated string marks the table end.
    if (name == '') return null;
    final directoryIndex = reader.readLEB128EncodedInteger();
    final lastModified = reader.readLEB128EncodedInteger();
    final size = reader.readLEB128EncodedInteger();
    return FileEntry._(name, directoryIndex, lastModified, size);
  }

  @override
  String toString() => 'File name: $name\n'
      '  Directory index: $directoryIndex\n'
      '  Last modified: $lastModified\n'
      '  Size: $size\n';
}

class FileInfo {
  final Map<int, FileEntry> _files;

  FileInfo._(this._files);

  static FileInfo fromReader(Reader reader) {
    final offsetFiles = reader.readRepeated(FileEntry.fromReader).toList();
    final files = <int, FileEntry>{};
    for (var i = 0; i < offsetFiles.length; i++) {
      // File entries are one-based, not zero-based.
      files[i + 1] = offsetFiles[i];
    }
    return FileInfo._(files);
  }

  static FileInfo fromReaderDwarf5(Reader reader, {int? addressSize}) {
    final entryFormatCount = reader.readByte();
    final entryFormatTypes = <_LineNumberContentType>[];
    final entryFormatForms = <_AttributeForm>[];
    int? sizeIndex;
    int? directoryIndexIndex;
    int? timestampIndex;
    int? nameIndex;

    for (int i = 0; i < entryFormatCount; i++) {
      final type = _LineNumberContentType.fromReader(reader);
      final form = _AttributeForm.fromReader(reader)!;
      type.validate(form);
      entryFormatTypes.add(type);
      entryFormatForms.add(form);
      switch (type) {
        case _LineNumberContentType.path:
          if (nameIndex != null) {
            throw FormatException('Multiple $type entries in format');
          }
          nameIndex = i;
          break;
        case _LineNumberContentType.directory_index:
          if (directoryIndexIndex != null) {
            throw FormatException('Multiple $type entries in format');
          }
          directoryIndexIndex = i;
          break;
        case _LineNumberContentType.timestamp:
          if (timestampIndex != null) {
            throw FormatException('Multiple $type entries in format');
          }
          timestampIndex = i;
          break;
        case _LineNumberContentType.size:
          if (sizeIndex != null) {
            throw FormatException('Multiple $type entries in format');
          }
          sizeIndex = i;
          break;
        case _LineNumberContentType.md5:
          break;
      }
    }
    if (nameIndex == null) {
      throw FormatException(
          'Missing ${_LineNumberContentType.path} entry in format');
    }

    final fileNamesCount = reader.readLEB128EncodedInteger();
    if (entryFormatCount == 0 && fileNamesCount != 0) {
      throw FormatException('Missing entry format(s)');
    }
    final files = <int, FileEntry>{};
    for (int i = 0; i < fileNamesCount; i++) {
      final values = <Object>[];
      for (int j = 0; j < entryFormatCount; j++) {
        final form = entryFormatForms[j];
        final value = form.read(reader, addressSize: addressSize);
        values.add(value);
      }
      final name = values[nameIndex] as String;
      // For any missing values, just use 0.
      final size = sizeIndex == null ? 0 : values[sizeIndex] as int;
      final directoryIndex =
          directoryIndexIndex == null ? 0 : values[directoryIndexIndex] as int;
      final timestamp =
          timestampIndex == null ? 0 : values[timestampIndex] as int;
      // In DWARF5, file entries are zero-based, as the current compilation file
      // name is provided first instead of implicit.
      files[i] = FileEntry._(name, directoryIndex, timestamp, size);
    }
    return FileInfo._(files);
  }

  bool containsKey(int index) => _files.containsKey(index);
  FileEntry? operator [](int index) => _files[index];

  void writeToStringBuffer(StringBuffer buffer) {
    if (_files.isEmpty) {
      buffer.writeln('No file information.');
      return;
    }

    final indexHeader = 'Entry';
    final dirIndexHeader = 'Dir';
    final modifiedHeader = 'Time';
    final sizeHeader = 'Size';
    final nameHeader = 'Name';

    final indexStrings = _files
        .map((int i, FileEntry f) => MapEntry<int, String>(i, i.toString()));
    final dirIndexStrings = _files.map((int i, FileEntry f) =>
        MapEntry<int, String>(i, f.directoryIndex.toString()));
    final modifiedStrings = _files.map((int i, FileEntry f) =>
        MapEntry<int, String>(i, f.lastModified.toString()));
    final sizeStrings = _files.map(
        (int i, FileEntry f) => MapEntry<int, String>(i, f.size.toString()));

    final maxIndexLength = indexStrings.values
        .fold(indexHeader.length, (int acc, String s) => max(acc, s.length));
    final maxDirIndexLength = dirIndexStrings.values
        .fold(dirIndexHeader.length, (int acc, String s) => max(acc, s.length));
    final maxModifiedLength = modifiedStrings.values
        .fold(modifiedHeader.length, (int acc, String s) => max(acc, s.length));
    final maxSizeLength = sizeStrings.values
        .fold(sizeHeader.length, (int acc, String s) => max(acc, s.length));

    buffer.writeln('File information:');

    buffer
      ..write(' ')
      ..write(indexHeader.padRight(maxIndexLength));
    buffer
      ..write(' ')
      ..write(dirIndexHeader.padRight(maxDirIndexLength));
    buffer
      ..write(' ')
      ..write(modifiedHeader.padRight(maxModifiedLength));
    buffer
      ..write(' ')
      ..write(sizeHeader.padRight(maxSizeLength));
    buffer
      ..write(' ')
      ..writeln(nameHeader);

    for (final index in _files.keys) {
      buffer
        ..write(' ')
        ..write(indexStrings[index]!.padRight(maxIndexLength));
      buffer
        ..write(' ')
        ..write(dirIndexStrings[index]!.padRight(maxDirIndexLength));
      buffer
        ..write(' ')
        ..write(modifiedStrings[index]!.padRight(maxModifiedLength));
      buffer
        ..write(' ')
        ..write(sizeStrings[index]!.padRight(maxSizeLength));
      buffer
        ..write(' ')
        ..writeln(_files[index]!.name);
    }
  }

  @override
  String toString() {
    var buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

class LineNumberState {
  final bool defaultIsStatement;

  late int address;
  late int opIndex;
  late int fileIndex;
  late int line;
  late int column;
  late bool isStatement;
  late bool basicBlock;
  late bool endSequence;
  late bool prologueEnd;
  late bool epilogueBegin;
  late int isa;
  late int discriminator;

  LineNumberState(this.defaultIsStatement) {
    reset();
  }

  void reset() {
    address = 0;
    opIndex = 0;
    fileIndex = 1;
    line = 1;
    column = 0;
    isStatement = defaultIsStatement;
    basicBlock = false;
    endSequence = false;
    prologueEnd = false;
    epilogueBegin = false;
    isa = 0;
    discriminator = 0;
  }

  LineNumberState clone() {
    final clone = LineNumberState(defaultIsStatement);
    clone.address = address;
    clone.opIndex = opIndex;
    clone.fileIndex = fileIndex;
    clone.line = line;
    clone.column = column;
    clone.isStatement = isStatement;
    clone.basicBlock = basicBlock;
    clone.endSequence = endSequence;
    clone.prologueEnd = prologueEnd;
    clone.epilogueBegin = epilogueBegin;
    clone.isa = isa;
    clone.discriminator = discriminator;
    return clone;
  }

  @override
  String toString() => 'Current line number state machine registers:\n'
      '  Address: ${paddedHex(address)}\n'
      '  Op index: $opIndex\n'
      '  File index: $fileIndex\n'
      '  Line number: $line\n'
      '  Column number: $column\n'
      "  Is ${isStatement ? "" : "not "}a statement.\n"
      "  Is ${basicBlock ? "" : "not "}at the beginning of a basic block.\n"
      "  Is ${endSequence ? "" : "not "}just after the end of a sequence.\n"
      "  Is ${prologueEnd ? "" : "not "}at a function entry breakpoint.\n"
      "  Is ${epilogueBegin ? "" : "not "}at a function exit breakpoint.\n"
      '  Applicable instruction set architecture: $isa\n'
      '  Block discrimator: $discriminator\n';
}

class LineNumberProgramHeader {
  final int size;
  final int version;
  final int headerLength;
  final int minimumInstructionLength;
  final bool defaultIsStatement;
  final int lineBase;
  final int lineRange;
  final int opcodeBase;
  final Map<int, int> standardOpcodeLengths;
  final List<String> includeDirectories;
  final FileInfo filesInfo;
  final int _fullHeaderSize;

  LineNumberProgramHeader._(
      this.size,
      this.version,
      this.headerLength,
      this.minimumInstructionLength,
      this.defaultIsStatement,
      this.lineBase,
      this.lineRange,
      this.opcodeBase,
      this.standardOpcodeLengths,
      this.includeDirectories,
      this.filesInfo,
      this._fullHeaderSize);

  static LineNumberProgramHeader? fromReader(Reader reader) {
    final size = _initialLengthValue(reader);
    if (size == 0) return null;
    final headerStart = reader.offset;
    final version = reader.readBytes(2);

    // Only used for DWARF5.
    int? addressSize;
    if (version == 5) {
      // These fields are DWARF5 specific.
      addressSize = reader.readByte();
      final segmentSelectorSize = reader.readByte();
      // We don't support segmented memory addresses here;
      assert(segmentSelectorSize == 0);
    }

    final headerLength = reader.readBytes(4);
    // We'll need this later as a double-check that we've read the entire
    // header.
    final offsetAfterHeaderLength = reader.offset;
    final minimumInstructionLength = reader.readByte();
    final isStmtByte = reader.readByte();
    if (isStmtByte < 0 || isStmtByte > 1) {
      throw FormatException(
          'Unexpected value for default_is_stmt: $isStmtByte');
    }
    final defaultIsStatement = isStmtByte == 1;
    final lineBase = reader.readByte(signed: true);
    final lineRange = reader.readByte();
    final opcodeBase = reader.readByte();
    final standardOpcodeLengths = <int, int>{};
    // Standard opcode numbering starts at 1.
    for (var i = 1; i < opcodeBase; i++) {
      standardOpcodeLengths[i] = reader.readLEB128EncodedInteger();
    }
    final includeDirectories = <String>[];
    if (version == 5) {
      final directoryEntryFormatCount = reader.readByte();
      if (directoryEntryFormatCount > 1) {
        throw FormatException(
            'Multiple directory formats not currently handled');
      }
      final contentType = _LineNumberContentType.fromReader(reader);
      if (contentType != _LineNumberContentType.path) {
        throw FormatException('Unexpected content type $contentType');
      }
      final form = _AttributeForm.fromReader(reader)!;
      contentType.validate(form);
      final directoryCount = reader.readLEB128EncodedInteger();
      for (int i = 0; i < directoryCount; i++) {
        final value = form.read(reader, addressSize: addressSize);
        includeDirectories.add(value as String);
      }
    } else {
      while (!reader.done) {
        final directory = reader.readNullTerminatedString();
        if (directory == '') break;
        includeDirectories.add(directory);
      }
      if (reader.done) {
        throw FormatException('Unterminated directory entry');
      }
    }
    final filesInfo = version == 5
        ? FileInfo.fromReaderDwarf5(reader, addressSize: addressSize)
        : FileInfo.fromReader(reader);

    // Header length doesn't include anything up to the header length field.
    if (reader.offset != offsetAfterHeaderLength + headerLength) {
      throw FormatException('At offset ${reader.offset} after header, '
          'expected to be at offset ${headerStart + headerLength}');
    }

    // We also keep note of the full header size internally so we can adjust
    // readers as necessary later.
    final fullHeaderSize = reader.offset - headerStart;
    return LineNumberProgramHeader._(
        size,
        version,
        headerLength,
        minimumInstructionLength,
        defaultIsStatement,
        lineBase,
        lineRange,
        opcodeBase,
        standardOpcodeLengths,
        includeDirectories,
        filesInfo,
        fullHeaderSize);
  }

  void writeToStringBuffer(StringBuffer buffer) {
    buffer
      ..write('  Size: ')
      ..writeln(size)
      ..write('  Version: ')
      ..writeln(version)
      ..write('  Header length: ')
      ..writeln(headerLength)
      ..write('  Min instruction length: ')
      ..writeln(minimumInstructionLength)
      ..write('  Default value of is_stmt: ')
      ..writeln(defaultIsStatement)
      ..write('  Line base: ')
      ..writeln(lineBase)
      ..write('  Line range: ')
      ..writeln(lineRange)
      ..write('  Opcode base: ')
      ..writeln(opcodeBase)
      ..writeln('Standard opcode lengths:');
    for (var i = 1; i < opcodeBase; i++) {
      buffer
        ..write('    Opcode ')
        ..write(i)
        ..write(': ')
        ..writeln(standardOpcodeLengths[i]);
    }

    if (includeDirectories.isEmpty) {
      buffer.writeln('No include directories.');
    } else {
      buffer.writeln('Include directories:');
      for (final dir in includeDirectories) {
        buffer
          ..write('    ')
          ..writeln(dir);
      }
    }

    filesInfo.writeToStringBuffer(buffer);
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

/// A class representing a DWARF line number program.
class LineNumberProgram {
  final LineNumberProgramHeader header;
  final List<LineNumberState> calculatedMatrix;
  final Map<int, LineNumberState> cachedLookups;

  LineNumberProgram._(this.header, this.calculatedMatrix) : cachedLookups = {};

  static LineNumberProgram? fromReader(Reader reader) {
    final header = LineNumberProgramHeader.fromReader(reader);
    if (header == null) return null;
    final calculatedMatrix = _readOpcodes(reader, header).toList();
    // Sometimes the assembler will generate an empty DWARF LNP, so don't check
    // for non-empty LNPs.
    return LineNumberProgram._(header, calculatedMatrix);
  }

  static Iterable<LineNumberState> _readOpcodes(
      Reader originalReader, LineNumberProgramHeader header) sync* {
    final state = LineNumberState(header.defaultIsStatement);
    final programSize = header.size - header._fullHeaderSize;
    final reader = originalReader.refocusedCopy(
        originalReader.start + originalReader.offset, programSize);

    void applySpecialOpcode(int opcode) {
      final adjustedOpcode = opcode - header.opcodeBase;
      final addrDiff = (adjustedOpcode ~/ header.lineRange) *
          header.minimumInstructionLength;
      final lineDiff = header.lineBase + (adjustedOpcode % header.lineRange);
      state.address += addrDiff;
      state.line += lineDiff;
    }

    while (!reader.done) {
      final opcode = reader.readByte();
      if (opcode >= header.opcodeBase) {
        applySpecialOpcode(opcode);
        yield state.clone();
        state.basicBlock = false;
        state.prologueEnd = false;
        state.epilogueBegin = false;
        state.discriminator = 0;
        continue;
      }
      switch (opcode) {
        case 0: // Extended opcodes
          final extendedLength = reader.readByte();
          final subOpcode = reader.readByte();
          switch (subOpcode) {
            case 0:
              throw FormatException('Attempted to execute extended opcode 0');
            case 1: // DW_LNE_end_sequence
              state.endSequence = true;
              yield state.clone();
              state.reset();
              continue;
            case 2: // DW_LNE_set_address
              // The length includes the subopcode.
              final valueLength = extendedLength - 1;
              assert(valueLength == 4 || valueLength == 8);
              final newAddress = reader.readBytes(valueLength);
              state.address = newAddress;
              break;
            case 3: // DW_LNE_define_file
              throw FormatException(
                  'DW_LNE_define_file instruction not handled');
            default:
              throw FormatException(
                  'Extended opcode $subOpcode not in DWARF 2');
          }
          break;
        case 1: // DW_LNS_copy
          yield state.clone();
          state.basicBlock = false;
          state.prologueEnd = false;
          state.epilogueBegin = false;
          state.discriminator = 0;
          break;
        case 2: // DW_LNS_advance_pc
          final increment = reader.readLEB128EncodedInteger();
          state.address += header.minimumInstructionLength * increment;
          break;
        case 3: // DW_LNS_advance_line
          state.line += reader.readLEB128EncodedInteger(signed: true);
          break;
        case 4: // DW_LNS_set_file
          state.fileIndex = reader.readLEB128EncodedInteger();
          break;
        case 5: // DW_LNS_set_column
          state.column = reader.readLEB128EncodedInteger();
          break;
        case 6: // DW_LNS_negate_stmt
          state.isStatement = !state.isStatement;
          break;
        case 7: // DW_LNS_set_basic_block
          state.basicBlock = true;
          break;
        case 8: // DW_LNS_const_add_pc
          state.address += ((255 - header.opcodeBase) ~/ header.lineRange) *
              header.minimumInstructionLength;
          break;
        case 9: // DW_LNS_fixed_advance_pc
          state.address += reader.readBytes(2);
          break;
        case 10: // DW_LNS_set_prologue_end (DWARF5)
          state.prologueEnd = true;
          break;
        case 11: // DW_LNS_set_epilogue_begin (DWARF5)
          state.epilogueBegin = true;
          break;
        case 12: // DW_LNS_set_isa (DWARF5)
          state.isa = reader.readLEB128EncodedInteger();
          break;
        default:
          throw FormatException('Standard opcode $opcode not in DWARF 2');
      }
    }
    // Adjust the original reader to be at the same offset.
    originalReader.seek(programSize);
  }

  bool containsKey(int address) {
    assert(calculatedMatrix.last.endSequence);
    return address >= calculatedMatrix.first.address &&
        address < calculatedMatrix.last.address;
  }

  LineNumberState? operator [](int address) {
    if (cachedLookups.containsKey(address)) return cachedLookups[address];

    if (!containsKey(address)) return null;

    // Since the addresses are generated in increasing order, we can do a
    // binary search to find the right state.
    assert(calculatedMatrix.isNotEmpty);
    var minIndex = 0;
    var maxIndex = calculatedMatrix.length - 1;
    while (true) {
      if (minIndex == maxIndex || minIndex + 1 == maxIndex) {
        final found = calculatedMatrix[minIndex];
        cachedLookups[address] = found;
        return found;
      }
      final index = minIndex + ((maxIndex - minIndex) ~/ 2);
      final compared = calculatedMatrix[index].address.compareTo(address);
      if (compared == 0) {
        return calculatedMatrix[index];
      } else if (compared < 0) {
        minIndex = index;
      } else if (compared > 0) {
        maxIndex = index;
      }
    }
  }

  String? filename(int address) =>
      header.filesInfo[this[address]?.fileIndex ?? -1]?.name;

  int? lineNumber(int address) => this[address]?.line;

  int? column(int address) => this[address]?.column;

  void writeToStringBuffer(StringBuffer buffer) {
    header.writeToStringBuffer(buffer);

    buffer.writeln('Results of line number program:');
    for (final state in calculatedMatrix) {
      buffer.writeln(state);
    }
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

/// A class representing a DWARF .debug_line section.
class LineNumberInfo {
  final Map<int, LineNumberProgram> programs;

  LineNumberInfo._(this.programs);

  static LineNumberInfo fromReader(Reader reader) {
    final programs = Map.fromEntries(
        reader.readRepeatedWithOffsets(LineNumberProgram.fromReader));
    return LineNumberInfo._(programs);
  }

  bool containsKey(int address) => programs.containsKey(address);
  LineNumberProgram? operator [](int address) => programs[address];

  void writeToStringBuffer(StringBuffer buffer) {
    programs.forEach((offset, program) {
      buffer
        ..write('Line number program @ 0x')
        ..writeln(paddedHex(offset));
      program.writeToStringBuffer(buffer);
    });
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

/// Represents the information for a call site.
abstract class CallInfo {
  /// Whether this call site is considered internal (i.e. not located in either
  /// user or library Dart source code).
  bool get isInternal => true;
}

/// Represents the information for a call site located in Dart source code.
class DartCallInfo extends CallInfo {
  final bool inlined;
  final bool internal;
  final String function;
  final String filename;
  final int line;
  final int column;

  DartCallInfo(
      {this.inlined = false,
      this.internal = false,
      required this.function,
      required this.filename,
      required this.line,
      required this.column});

  @override
  bool get isInternal => internal;

  @override
  int get hashCode => Object.hash(
        inlined,
        internal,
        function,
        filename,
        line,
        column,
      );

  @override
  bool operator ==(Object other) =>
      other is DartCallInfo &&
      inlined == other.inlined &&
      internal == other.internal &&
      function == other.function &&
      filename == other.filename &&
      line == other.line &&
      column == other.column;

  void writeToStringBuffer(StringBuffer buffer) {
    buffer
      ..write(function)
      ..write(' (')
      ..write(filename);
    if (line > 0) {
      buffer
        ..write(':')
        ..write(line);
      if (column > 0) {
        buffer
          ..write(':')
          ..write(column);
      }
    }
    buffer.write(')');
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}

/// Represents the information for a call site located in a Dart stub.
class StubCallInfo extends CallInfo {
  final String name;
  final int offset;

  StubCallInfo({required this.name, required this.offset});

  @override
  int get hashCode => Object.hash(name, offset);

  @override
  bool operator ==(Object other) =>
      other is StubCallInfo && name == other.name && offset == other.offset;

  @override
  String toString() => '$name+0x${offset.toRadixString(16)}';
}

/// The instructions section in which a program counter address is located.
enum InstructionsSection { none, vm, isolate }

/// A program counter address viewed as an offset into the appropriate
/// instructions section of a Dart snapshot. Includes other information
/// parsed from the corresponding stack trace header when possible.
class PCOffset {
  /// The offset into the corresponding instructions section.
  final int offset;

  /// The instructions section into which this is an offset.
  final InstructionsSection section;

  /// The operating system on which the stack trace was generated, when
  /// available.
  final String? os;

  /// The architecture on which the stack trace was generated, when
  /// available.
  final String? architecture;

  /// Whether compressed pointers were enabled, when available.
  final bool? compressedPointers;

  /// Whether the architecture was being simulated, when available.
  final bool? usingSimulator;

  PCOffset(this.offset, this.section,
      {this.os,
      this.architecture,
      this.compressedPointers,
      this.usingSimulator});

  /// The virtual address for this [PCOffset] in [dwarf].
  int virtualAddressIn(Dwarf dwarf) => dwarf.virtualAddressOf(this);

  /// The call information found for this [PCOffset] in [dwarf].
  ///
  /// Returns null if the PCOffset is invalid for the given DWARF information.
  ///
  /// If [includeInternalFrames] is false, then only information corresponding
  /// to user or library code is returned.
  Iterable<CallInfo>? callInfoFrom(Dwarf dwarf,
          {bool includeInternalFrames = false}) =>
      dwarf.callInfoForPCOffset(this,
          includeInternalFrames: includeInternalFrames);

  @override
  int get hashCode => Object.hash(offset, section);

  @override
  bool operator ==(Object other) =>
      other is PCOffset &&
      offset == other.offset &&
      section == other.section &&
      os == other.os &&
      architecture == other.architecture &&
      compressedPointers == other.compressedPointers &&
      usingSimulator == other.usingSimulator;

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer
      ..write('PCOffset(')
      ..write(section)
      ..write(', 0x')
      ..write(offset.toRadixString(16));
    if (os != null) {
      buffer
        ..write(', ')
        ..write(os!);
    }
    if (architecture != null) {
      if (usingSimulator ?? false) {
        buffer.write('SIM');
      }
      buffer.write(architecture!.toUpperCase());
      if (compressedPointers ?? false) {
        buffer.write('C');
      }
    }
    return buffer.toString();
  }
}

/// The DWARF debugging information for a Dart snapshot.
class Dwarf {
  final DwarfContainer _container;
  final Map<int, _AbbreviationsTable> _abbreviationsTables;
  final DebugInfo _debugInfo;
  final LineNumberInfo _lineNumberInfo;

  /// Virtual address of the start of the VM instructions section in the DWARF
  /// information.
  final int vmStartAddress;

  /// Virtual address of the start of the isolate instructions section in the
  /// DWARF information.
  final int isolateStartAddress;

  Dwarf._(this._container, this._abbreviationsTables, this._debugInfo,
      this._lineNumberInfo, this.vmStartAddress, this.isolateStartAddress);

  static Dwarf fromDwarfContainer(Reader reader, DwarfContainer container) =>
      // We use Zone values to pass around the string tables that may be used
      // when parsing different sections.
      runZoned(() {
        final abbrevReader = container.abbreviationsTableReader(reader);
        final abbreviationsTables = Map.fromEntries(abbrevReader
            .readRepeatedWithOffsets(_AbbreviationsTable.fromReader));

        final debugInfo = DebugInfo.fromReader(
            container.debugInfoReader(reader), abbreviationsTables);

        final lineNumberInfo =
            LineNumberInfo.fromReader(container.lineNumberInfoReader(reader));

        return Dwarf._(
            container,
            abbreviationsTables,
            debugInfo,
            lineNumberInfo,
            container.vmStartAddress,
            container.isolateStartAddress);
      }, zoneValues: {
        _debugStringTableKey: container.debugStringTable,
        _debugLineStringTableKey: container.debugLineStringTable,
      });

  /// Attempts to load the DWARF debugging information from the reader.
  ///
  /// Returns a [Dwarf] object if the load succeeds, otherwise returns null.
  static Dwarf? fromReader(Reader reader) {
    final elf = Elf.fromReader(reader);
    if (elf != null) {
      return Dwarf.fromDwarfContainer(reader, elf);
    }
    final macho = MachO.fromReader(reader);
    if (macho != null) {
      return Dwarf.fromDwarfContainer(reader, macho);
    }
    return null;
  }

  /// Attempts to load the DWARF debugging information from the given bytes.
  ///
  /// Returns a [Dwarf] object if the load succeeds, otherwise returns null.
  static Dwarf? fromBytes(Uint8List bytes) =>
      Dwarf.fromReader(Reader.fromTypedData(bytes));

  /// Attempts to load the DWARF debugging information from the file at [path].
  ///
  /// Returns a [Dwarf] object if the load succeeds, otherwise returns null.
  static Dwarf? fromFile(String path) =>
      Dwarf.fromReader(Reader.fromFile(MachO.handleDSYM(path)));

  /// The build ID for the debugging information.
  ///
  /// Returns null if there is no build ID information recorded.
  String? get buildId => _container.buildId;

  /// The call information for the given virtual address. There may be
  /// multiple [CallInfo] objects returned for a single virtual address when
  /// code has been inlined.
  ///
  /// Returns null if the given address is invalid for the DWARF information.
  ///
  /// If [includeInternalFrames] is false, then only information corresponding
  /// to user or library code is returned.
  Iterable<CallInfo>? callInfoFor(int address,
      {bool includeInternalFrames = false}) {
    var calls = _debugInfo.callInfo(_lineNumberInfo, address);
    if (calls == null) {
      final symbol = _container.staticSymbolAt(address);
      if (symbol != null) {
        final offset = address - symbol.value;
        calls = <CallInfo>[StubCallInfo(name: symbol.name, offset: offset)];
      }
    }
    if (!includeInternalFrames) {
      return calls?.where((CallInfo c) => !c.isInternal);
    }
    return calls;
  }

  /// The call information for the given [PCOffset]. There may be multiple
  /// [CallInfo] objects returned for a single [PCOffset] when code has been
  /// inlined.
  ///
  /// Returns null if the given address is invalid for the DWARF information.
  ///
  /// If [includeInternalFrames] is false, then only information corresponding
  /// to user or library code is returned.
  Iterable<CallInfo>? callInfoForPCOffset(PCOffset pcOffset,
          {bool includeInternalFrames = false}) =>
      callInfoFor(virtualAddressOf(pcOffset),
          includeInternalFrames: includeInternalFrames);

  /// The virtual address in this DWARF information for the given [PCOffset].
  int virtualAddressOf(PCOffset pcOffset) {
    switch (pcOffset.section) {
      case InstructionsSection.none:
        // This address is already virtualized, so we don't need to change it.
        return pcOffset.offset;
      case InstructionsSection.vm:
        return pcOffset.offset + vmStartAddress;
      case InstructionsSection.isolate:
        return pcOffset.offset + isolateStartAddress;
      default:
        throw 'Unexpected value for instructions section';
    }
  }

  void writeToStringBuffer(StringBuffer buffer) {
    buffer
      ..writeln('----------------------------------------')
      ..writeln('         Abbreviation tables')
      ..writeln('----------------------------------------')
      ..writeln();
    _abbreviationsTables.forEach((offset, table) {
      buffer
        ..write('(Offset ')
        ..write(paddedHex(offset, 4))
        ..write(') ');
      table.writeToStringBuffer(buffer);
    });
    buffer
      ..writeln('----------------------------------------')
      ..writeln('          Debug information')
      ..writeln('----------------------------------------')
      ..writeln();
    _debugInfo.writeToStringBuffer(buffer);
    buffer
      ..writeln('----------------------------------------')
      ..writeln('        Line number information')
      ..writeln('----------------------------------------')
      ..writeln();
    _lineNumberInfo.writeToStringBuffer(buffer);
  }

  String dumpFileInfo() {
    final buffer = StringBuffer();
    _container.writeToStringBuffer(buffer);
    buffer.writeln();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    writeToStringBuffer(buffer);
    return buffer.toString();
  }
}
