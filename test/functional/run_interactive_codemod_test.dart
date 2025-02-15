// Copyright 2019 Workiva Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

@TestOn('vm')
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:codemod/src/run_interactive_codemod.dart' show codemodArgParser;

import '../util.dart';

// Change this to `true` and all of the functional tests in this file will print
// the stdout/stderr of the codemod processes.
final _debug = false;

const _testFixturesPath = 'test_fixtures/functional';
const _afterAllPatches = '$_testFixturesPath/after_all_patches/';
const _afterSomePatches = '$_testFixturesPath/after_some_patches/';
const _afterNoPatches = '$_testFixturesPath/before/';
const _projectPath = '$_testFixturesPath/before/';

Future<Null> testCodemod(
  String description,
  String goldPath, {
  List<String> args,
  body(String out, String err),
  int expectedExitCode,
  String script,
  List<String> stdinLines,
}) async {
  test(description, () async {
    Directory tempProjectDir;
    try {
      tempProjectDir = Directory(_testFixturesPath).createTempSync();
      copyDirectory(Directory(_projectPath), tempProjectDir);
      final pubGetResult = await Process.run(
        'pub',
        ['get'],
        workingDirectory: tempProjectDir.path,
      );
      if (pubGetResult.exitCode != 0) {
        fail('Failed to `pub get` in test fixture directory.\n'
            'Pub get stderr:\n'
            '${pubGetResult.stderr}');
      }

      final processArgs = [script ?? 'codemod.dart']..addAll(args ?? []);
      if (_debug) {
        processArgs.add('--verbose');
      }
      final process = await Process.start('dart', processArgs,
          workingDirectory: tempProjectDir.path);
      (stdinLines ?? []).forEach(process.stdin.writeln);
      final codemodExitCode = await process.exitCode;
      expectedExitCode ??= 0;

      final codemodStdout = await process.stdout.transform(utf8.decoder).join();
      final codemodStderr = await process.stderr.transform(utf8.decoder).join();

      expect(codemodExitCode, expectedExitCode,
          reason: 'Expected codemod to exit with code $expectedExitCode, but '
              'it exited with $codemodExitCode.\n'
              'Process stderr:\n$codemodStderr');

      if (_debug) {
        print('STDOUT:\n$codemodStdout\n\nSTDERR:\n$codemodStderr');
      }

      expectProjectsMatch(goldPath, tempProjectDir.path);

      if (body != null) {
        body(codemodStdout, codemodStderr);
      }
    } finally {
      tempProjectDir?.deleteSync(recursive: true);
    }
  });
}

void expectProjectsMatch(String goldPath, String testPath) {
  final sortedFiles =
      Directory(goldPath).listSync(recursive: true).whereType<File>().toList();
  sortedFiles.sort((a, b) => a.path.compareTo(b.path));
  for (final file in sortedFiles) {
    final relPath = p.relative(file.path, from: goldPath);
    final other = File(p.join(testPath, relPath));
    expect(
      other.readAsStringSync(),
      file.readAsStringSync(),
      reason: 'File contents mismatch: $relPath',
    );
  }
}

void main() {
  group('runInteractiveCodemod', () {
    testCodemod('--help outputs usage help text', _afterNoPatches,
        args: ['--help'], body: (out, err) {
      expect(err,
          contains('Global codemod options:\n\n' + codemodArgParser.usage));
    });

    testCodemod(
        '--help outputs additional help text if provided', _afterNoPatches,
        script: 'codemod_help_output.dart', args: ['--help'], body: (out, err) {
      expect(err, contains('additional help output'));
    });

    testCodemod('skips all patches via prompts', _afterNoPatches,
        // 6 prompts (2 files, 3 each)
        stdinLines: ['n', 'n', 'n', 'n', 'n', 'n']);

    testCodemod('applies all patches via prompts', _afterAllPatches,
        // 6 prompts (2 files, 3 each)
        stdinLines: ['y', 'y', 'y', 'y', 'y', 'y']);

    testCodemod('applies some patches via prompts', _afterSomePatches,
        // 6 prompts (2 files, 3 each)
        stdinLines: [
          // File 1
          'y', 'n', 'y',
          // File 2
          'n', 'y', 'n',
        ]);

    testCodemod('applies all patches via [enter] when defaultYes=true',
        _afterAllPatches,
        script: 'codemod_default_yes.dart',
        // 6 prompts (2 files, 3 each)
        // Empty string is equivalent to the user typing [enter]/[return]
        stdinLines: ['', '', '', '', '', '']);

    testCodemod('applies all patches via --yes-to-all', _afterAllPatches,
        args: ['--yes-to-all']);

    testCodemod('applies patches and then quits via prompts', _afterSomePatches,
        // 6 prompts (2 files, 3 each)
        stdinLines: [
          // File 1
          'y', 'n', 'y',
          // File 2 - quits after skipping 1st, accepting 2nd; effectively skips
          // the 3rd patch suggestion.
          'n', 'y', 'q',
        ]);

    testCodemod('--fail-on-changes exits with 0 when no changes needed',
        _afterNoPatches,
        args: ['--fail-on-changes'],
        script: 'codemod_no_patches.dart', body: (out, err) {
      expect(out, contains('No changes needed.'));
    });

    testCodemod('--fail-on-changes exits with non-zero when changes needed',
        _afterNoPatches,
        args: ['--fail-on-changes'],
        expectedExitCode: 1,
        script: 'codemod.dart', body: (out, err) {
      expect(err, contains('6 change(s) needed.'));
    });

    testCodemod('--fail-on-changes adds extra text to output when provided',
        _afterNoPatches,
        args: ['--fail-on-changes'],
        expectedExitCode: 1,
        script: 'codemod_changes_required_output.dart', body: (out, err) {
      expect(err, contains('6 change(s) needed.\n\nchanges required output'));
    });
  });
}
