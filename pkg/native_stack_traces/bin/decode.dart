// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:args/args.dart' show ArgParser, ArgResults;
import 'package:native_stack_traces/native_stack_traces.dart';
import 'package:path/path.dart' as path;

ArgParser _createBaseDebugParser(ArgParser parser) => parser
  ..addOption('debug',
      abbr: 'd',
      help: 'Filename containing debugging information (REQUIRED)',
      valueHelp: 'FILE')
  ..addFlag('verbose',
      abbr: 'v',
      negatable: false,
      help: 'Translate all frames, not just user or library code frames');

final ArgParser _dumpParser = ArgParser(allowTrailingOptions: true)
  ..addOption('output',
      abbr: 'o', help: 'Filename for generated output', valueHelp: 'FILE');

final ArgParser _translateParser =
    _createBaseDebugParser(ArgParser(allowTrailingOptions: true))
      ..addOption('input',
          abbr: 'i', help: 'Filename for processed input', valueHelp: 'FILE')
      ..addOption('output',
          abbr: 'o', help: 'Filename for generated output', valueHelp: 'FILE');

final ArgParser _findParser =
    _createBaseDebugParser(ArgParser(allowTrailingOptions: true))
      ..addMultiOption('location',
          abbr: 'l', help: 'PC address to find', valueHelp: 'PC')
      ..addFlag('force_hexadecimal',
          abbr: 'x',
          negatable: false,
          help: 'Always parse integers as hexadecimal')
      ..addOption('vm_start',
          help: 'Absolute address for start of VM instructions',
          valueHelp: 'PC')
      ..addOption('isolate_start',
          help: 'Absolute address for start of isolate instructions',
          valueHelp: 'PC');

final ArgParser _helpParser = ArgParser(allowTrailingOptions: true);

final ArgParser _argParser = ArgParser(allowTrailingOptions: true)
  ..addCommand('dump', _dumpParser)
  ..addCommand('help', _helpParser)
  ..addCommand('find', _findParser)
  ..addCommand('translate', _translateParser)
  ..addFlag('help',
      abbr: 'h',
      negatable: false,
      help: 'Print usage information for this or a particular subcommand');

final String _mainUsage = '''
Usage: decode <command> [options] ...

Commands:
${_argParser.commands.keys.join("\n")}

Options shared by all commands:
${_argParser.usage}''';

final String _helpUsage = '''
Usage: decode help [<command>]

Returns usage for the decode utility or a particular command.

Commands:
${_argParser.commands.keys.join("\n")}''';

final String _translateUsage = '''
Usage: decode translate [options]

The translate command takes text that includes non-symbolic stack traces
generated by the VM when executing a snapshot compiled with the
--dwarf-stack-traces flag. It outputs almost the same text, but with any
non-symbolic stack traces converted to symbolic stack traces that contain
function names, file names, and line numbers.

Options shared by all commands:
${_argParser.usage}

Options specific to the translate command:
${_translateParser.usage}''';

final String _findUsage = '''
Usage: decode find [options] <PC> ...

The find command looks up program counter (PC) addresses, either given as
arguments on the command line or via the -l/--location option. For each
successful PC lookup, it outputs the call information in one of two formats:

- If the location corresponds to a call site in Dart source code, the call
  information includes the file, function, and line number information.
- If it corresponds to a Dart VM stub, the call information includes the dynamic
  symbol name for the instructions payload and an offset into that payload.

The -l option may be provided multiple times, or a single use of the -l option
may be given multiple arguments separated by commas.

PC addresses can be provided in one of two formats:

- An integer, e.g. 0x2a3f or 15049
- A static symbol in the VM snapshot plus an integer offset, e.g.,
  _kDartIsolateSnapshotInstructions+1523 or _kDartVMSnapshotInstructions+0x403f

Integers without an "0x" prefix that do not includes hexadecimal digits are
assumed to be decimal unless the -x/--force_hexadecimal flag is used.

By default, integer PC addresses are assumed to be virtual addresses valid for
the given debugging information. Otherwise, use both the --vm_start and
--isolate_start arguments to provide the appropriate starting addresses of the
VM and isolate instructions sections.

Options shared by all commands:
${_argParser.usage}

Options specific to the find command:
${_findParser.usage}''';

final String _dumpUsage = '''
Usage: decode dump [options] <snapshot>

The dump command dumps the DWARF information in the given snapshot to either
standard output or a given output file.

Options specific to the dump command:
${_dumpParser.usage}''';

final _usages = <String?, String>{
  null: _mainUsage,
  '': _mainUsage,
  'help': _helpUsage,
  'translate': _translateUsage,
  'find': _findUsage,
  'dump': _dumpUsage,
};

const int _badUsageExitCode = 1;

void errorWithUsage(String message, {String? command}) {
  print('Error: $message.\n');
  print(_usages[command]);
  io.exitCode = _badUsageExitCode;
}

void help(ArgResults options) {
  void usageError(String message) => errorWithUsage(message, command: 'help');

  switch (options.rest.length) {
    case 0:
      return print(_usages['help']);
    case 1:
      {
        final usage = _usages[options.rest.first];
        if (usage != null) return print(usage);
        return usageError('invalid command ${options.rest.first}');
      }
    default:
      return usageError('too many arguments');
  }
}

Dwarf? _loadFromFile(String? original, Function(String) usageError) {
  if (original == null) {
    usageError('must provide -d/--debug');
    return null;
  }
  final filename = path.canonicalize(path.normalize(original));
  try {
    final dwarf = Dwarf.fromFile(filename);
    if (dwarf == null) {
      usageError('file "$original" does not contain debugging information');
    }
    return dwarf;
  } on io.FileSystemException {
    usageError('debug file "$original" does not exist');
    return null;
  }
}

void find(ArgResults options) {
  final bool verbose = options['verbose'];
  final bool forceHexadecimal = options['force_hexadecimal'];

  void usageError(String message) => errorWithUsage(message, command: 'find');
  int? tryParseIntAddress(String s) {
    if (!forceHexadecimal && !s.startsWith('0x')) {
      final decimal = int.tryParse(s);
      if (decimal != null) return decimal;
    }
    return int.tryParse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  }

  PCOffset? convertAddress(StackTraceHeader header, String s) {
    final parsedOffset =
        tryParseSymbolOffset(s, forceHexadecimal: forceHexadecimal);
    if (parsedOffset != null) return parsedOffset;

    final address = tryParseIntAddress(s);
    if (address != null) return header.offsetOf(address);

    return null;
  }

  final dwarf = _loadFromFile(options['debug'], usageError);
  if (dwarf == null) return;

  if ((options['vm_start'] == null) != (options['isolate_start'] == null)) {
    return usageError('need both VM start and isolate start');
  }

  var vmStart = dwarf.vmStartAddress;
  if (options['vm_start'] != null) {
    final address = tryParseIntAddress(options['vm_start']);
    if (address == null) {
      return usageError('could not parse VM start address '
          '${options['vm_start']}');
    }
    vmStart = address;
  }

  var isolateStart = dwarf.isolateStartAddress;
  if (options['isolate_start'] != null) {
    final address = tryParseIntAddress(options['isolate_start']);
    if (address == null) {
      return usageError('could not parse isolate start address '
          '${options['isolate_start']}');
    }
    isolateStart = address;
  }

  final header = StackTraceHeader.fromStarts(isolateStart, vmStart);

  final locations = <PCOffset>[];
  for (final String s in [
    ...(options['location'] as List<String>),
    ...options.rest,
  ]) {
    final location = convertAddress(header, s);
    if (location == null) return usageError('could not parse PC address $s');
    locations.add(location);
  }
  if (locations.isEmpty) return usageError('no PC addresses to find');

  for (final offset in locations) {
    final addr = dwarf.virtualAddressOf(offset);
    final frames = dwarf
        .callInfoFor(addr, includeInternalFrames: verbose)
        ?.map((CallInfo c) => '  $c');
    final addrString =
        addr > 0 ? '0x${addr.toRadixString(16)}' : addr.toString();
    print('For virtual address $addrString:');
    if (frames == null) {
      print('  Invalid virtual address.');
    } else if (frames.isEmpty) {
      print('  Not a call from user or library code.');
    } else {
      frames.forEach(print);
    }
  }
}

Future<void> translate(ArgResults options) async {
  void usageError(String message) =>
      errorWithUsage(message, command: 'translate');

  final dwarf = _loadFromFile(options['debug'], usageError);
  if (dwarf == null) {
    return;
  }

  final verbose = options['verbose'];
  final output = options['output'] != null
      ? io.File(path.canonicalize(path.normalize(options['output'])))
          .openWrite()
      : io.stdout;
  final input = options['input'] != null
      ? io.File(path.canonicalize(path.normalize(options['input']))).openRead()
      : io.stdin;

  final convertedStream = input
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .transform(DwarfStackTraceDecoder(dwarf, includeInternalFrames: verbose))
      .map((s) => '$s\n')
      .transform(utf8.encoder);

  await output.addStream(convertedStream);
  await output.flush();
  await output.close();
}

Future<void> dump(ArgResults options) async {
  void usageError(String message) => errorWithUsage(message, command: 'dump');

  if (options.rest.isEmpty) {
    return usageError('must provide a path to an ELF file or dSYM directory '
        'that contains DWARF information');
  }
  final dwarf = _loadFromFile(options.rest.first, usageError);
  if (dwarf == null) {
    return usageError("'${options.rest.first}' contains no DWARF information");
  }

  final output = options['output'] != null
      ? io.File(path.canonicalize(path.normalize(options['output'])))
          .openWrite()
      : io.stdout;
  output.write(dwarf.dumpFileInfo());
  await output.flush();
  await output.close();
}

Future<void> main(List<String> arguments) async {
  ArgResults options;

  try {
    options = _argParser.parse(arguments);
  } on FormatException catch (e) {
    return errorWithUsage(e.message);
  }

  if (options['help']) return print(_usages[options.command?.name]);
  if (options.command == null) return errorWithUsage('no command provided');

  switch (options.command!.name) {
    case 'help':
      return help(options.command!);
    case 'find':
      return find(options.command!);
    case 'translate':
      return await translate(options.command!);
    case 'dump':
      return await dump(options.command!);
  }
}
