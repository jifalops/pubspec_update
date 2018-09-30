import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:args/args.dart';
import 'package:colorize/colorize.dart';

/// Word characters with dots.
/// Dots must be non-consecutive and cannot start or end a package name.
const packageNameRegex = r'\w(?:\.?\w)*';

/// 0.0.0-prerelease+build
const packageVersionRegex =
    '\\d+\\.\\d+\\.\\d+(?:-$_namedPart)?(?:\\+$_namedPart)?';

/// Pre-relase and build number of a package version. Alphanumerics, hyphens,
/// and dots. Dots must be non-consecutive and cannot start or end a named
/// version part.
const _namedPart = r'[a-zA-Z0-9-](?:\.?[a-zA-Z0-9-])*';

bool silent;
String usage;

void main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('confirm',
        abbr: 'c',
        defaultsTo: false,
        negatable: false,
        help: 'Update packages without prompting the user for confirmation.')
    ..addFlag('force',
        abbr: 'f',
        defaultsTo: false,
        negatable: false,
        help: 'Equivalent to --upgrade --confirm.')
    ..addFlag('get',
        abbr: 'g',
        defaultsTo: false,
        negatable: false,
        help:
            'Run `pub get` or `flutter packages get` on the package before processing.')
    ..addFlag('help',
        abbr: 'h',
        defaultsTo: false,
        negatable: false,
        help: 'Print this help message.')
    ..addFlag('silent',
        abbr: 's',
        defaultsTo: false,
        negatable: false,
        help: 'Suppress all output.')
    ..addFlag('upgrade',
        abbr: 'u',
        defaultsTo: false,
        negatable: false,
        help:
            'Run `pub upgrade` or `flutter packages upgrade` on the package before processing.'
            ' Overrides --get.');

  usage = '''
Usage: pubspec-update [arguments] [directory]

arguments
${parser.usage}
''';

  ArgResults argv;
  try {
    argv = parser.parse(args);
  } catch (e) {
    print(usage);
    exit(1);
  }
  if (argv['help'] || argv.rest.length > 1) {
    print(usage);
    exit(0);
  }

  silent = argv['silent'];
  final force = argv['force'];
  final confirm = force || argv['confirm'];
  final upgrade = force || argv['upgrade'];
  final runGet = !upgrade && argv['get'];
  final path = argv.rest.length == 1 ? argv.rest.first : '.';

  final packagesFile = File('$path/.packages');
  final pubspecFile = File('$path/pubspec.yaml');

  // pubspec.yaml must exist.
  if (pubspecFile.existsSync()) {
    final pubspecLines = pubspecFile.readAsLinesSync();
    Command command;

    // Try to create .packages if it doesn't exist.
    if (!packagesFile.existsSync()) {
      sprint('`.packages` not found. Creating...');
      command = Command.fromPubspec(pubspecLines, upgrade);
      await command.run(path);
      if (!packagesFile.existsSync()) {
        sprint('Failed to create `.packages`. Exiting.');
        exit(2);
      }
    }

    // Run get/upgrade if requested and it hasn't been run.
    if ((upgrade || runGet) && command == null) {
      command = Command.fromPubspec(pubspecLines, upgrade);
      int exitCode = await command.run(path);
      if (exitCode != 0) {
        sprint('Command failed, cannot update versions.');
        exit(3);
      }
    }

    final packages = parsePackageVersions(packagesFile);
    final pubspec = ChangedPubspec.fromLines(pubspecLines, packages);

    if (pubspec.changed) {
      sprint('The following pubspec.yaml package versions will be changed:');
      if (pubspec.mainChanges.isNotEmpty) {
        sprint('dependencies:');
        pubspec.mainChanges.forEach((dep) => sprint('  $dep'));
      }
      if (pubspec.devChanges.isNotEmpty) {
        sprint('dev_dependencies:');
        pubspec.devChanges.forEach((dep) => sprint('  $dep'));
      }
      bool confirmed = true;
      if (!confirm) {
        final reponse = promptUser('Continue with changes? [Y/n]');
        confirmed = reponse.isEmpty || reponse.toLowerCase() == 'y';
      }
      if (confirmed) {
        pubspecFile.writeAsStringSync(pubspec.contents.join('\n'), flush: true);
      }
    } else {
      sprint('pubspec.yaml versions are already up to date!');
    }
  } else {
    print('"$path" is not a package.\n');
    print(usage);
    exit(4);
  }
  exit(0);
}

class Command {
  const Command(this.command, this.args);
  final String command;
  final List<String> args;

  @override
  toString() => '$command ${args.join(' ')}';

  Future<int> run(String path) async {
    sprint('Running command "$this".');
    sprint('-----');
    final process = await Process.start(command, args, workingDirectory: path);
    process.stdout
        .transform(utf8.decoder)
        .listen((data) => silent ? null : stdout.write(data));
    process.stderr
        .transform(utf8.decoder)
        .listen((data) => silent ? null : stderr.write(data));
    final exitCode = await process.exitCode;
    sprint('-----');
    return exitCode;
  }

  static Command fromPubspec(List<String> pubspecLines, bool upgrade) {
    String command = 'pub';
    final args = <String>[];
    for (final line in pubspecLines) {
      if (line.trim() == 'flutter:') {
        command = 'flutter';
        args.add('packages');
        break;
      }
    }
    return Command(command, args..add(upgrade ? 'upgrade' : 'get'));
  }
}

/// Finds *versioned* packages in a `.packages` file's contents.
Map<String, String> parsePackageVersions(File packagesFile) {
  return Map.fromEntries(
      RegExp('/($packageNameRegex)-($packageVersionRegex)/lib/')
          .allMatches(packagesFile.readAsStringSync())
          .map((match) => MapEntry(match.group(1), match.group(2))));
}

class ChangedPubspec {
  const ChangedPubspec(this.contents, this.mainChanges, this.devChanges);
  final List<String> contents, mainChanges, devChanges;
  bool get changed => mainChanges.isNotEmpty || devChanges.isNotEmpty;

  /// Finds version changes in the lines of a pubspec.yaml by comparing them to
  /// their latest version.
  static ChangedPubspec fromLines(
      List<String> lines, Map<String, String> latestVersions) {
    final depMatcher =
        RegExp('^  ["\']?($packageNameRegex)["\']?\\s*:\\s*(.*)\\s*\$');
    final mainChanges = <String>[];
    final devChanges = <String>[];
    int index = 0;
    while (index < lines.length) {
      final isMainDepsHeader = lines[index].trimRight() == 'dependencies:';
      final isDevDepsHeader = lines[index].trimRight() == 'dev_dependencies:';
      if (isMainDepsHeader || isDevDepsHeader) {
        int subIndex = index + 1;
        while (subIndex < lines.length &&
            (lines[subIndex].isEmpty || lines[subIndex].startsWith('  '))) {
          final match = depMatcher.firstMatch(lines[subIndex]);
          if (match != null) {
            // Make sure the next valid line is not a continuation of this
            // dependency.
            int nextLine = subIndex + 1;
            while (nextLine < lines.length && lines[nextLine].trim().isEmpty)
              nextLine++;
            if (nextLine >= lines.length ||
                !lines[nextLine].startsWith('    ')) {
              final pkg = match.group(1);
              assert(latestVersions.containsKey(pkg));
              final oldVersion = match.group(2);
              final newVersion = '^${latestVersions[pkg]}';
              if (oldVersion != newVersion) {
                final change =
                    '$pkg: ${Colorize(oldVersion)..red()} ${Colorize(newVersion)..green()}';
                if (isMainDepsHeader) {
                  mainChanges.add(change);
                } else if (isDevDepsHeader) {
                  devChanges.add(change);
                }
                lines[subIndex] = '  $pkg: $newVersion';
              }
            }
          }
          subIndex++;
        }
        index = subIndex;
      } else {
        index++;
      }
    }
    return ChangedPubspec(lines, mainChanges, devChanges);
  }
}

String promptUser(String prompt, [bool singleByte = false]) {
  stdout.write('$prompt ');
  return singleByte
      ? utf8.decode([stdin.readByteSync()])
      : stdin.readLineSync(encoding: utf8);
}

void sprint(dynamic s) => silent ? null : print(s);
