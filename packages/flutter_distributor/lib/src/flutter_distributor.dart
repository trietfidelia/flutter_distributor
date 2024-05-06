import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_app_builder/flutter_app_builder.dart';
import 'package:flutter_app_packager/flutter_app_packager.dart';
import 'package:flutter_app_publisher/flutter_app_publisher.dart';
import 'package:flutter_distributor/src/distribute_options.dart';
import 'package:flutter_distributor/src/extensions/extensions.dart';
import 'package:flutter_distributor/src/release.dart';
import 'package:flutter_distributor/src/release_job.dart';
import 'package:flutter_distributor/src/utils/utils.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:shell_executor/shell_executor.dart';
import 'package:shell_uikit/shell_uikit.dart';
import 'package:yaml/yaml.dart';

class FlutterDistributor {
  FlutterDistributor() {
    ShellExecutor.global = DefaultShellExecutor();
  }

  final FlutterAppBuilder _builder = FlutterAppBuilder();
  final FlutterAppPackager _packager = FlutterAppPackager();
  final FlutterAppPublisher _publisher = FlutterAppPublisher();

  Pubspec? _pubspec;
  Pubspec get pubspec {
    if (_pubspec == null) {
      final yamlString = File('pubspec.yaml').readAsStringSync();
      _pubspec = Pubspec.parse(yamlString);
    }
    return _pubspec!;
  }

  final Map<String, String> _globalVariables = {};
  Map<String, String> get globalVariables {
    if (_globalVariables.keys.isEmpty) {
      for (String key in Platform.environment.keys) {
        String? value = Platform.environment[key];
        if ((value ?? '').isNotEmpty) {
          _globalVariables[key] = value!;
        }
      }
      List<String> keys = distributeOptions.variables?.keys.toList() ?? [];
      for (String key in keys) {
        String? value = distributeOptions.variables?[key];
        if ((value ?? '').isNotEmpty) {
          _globalVariables[key] = value!;
        }
      }
    }
    return _globalVariables;
  }

  DistributeOptions? _distributeOptions;
  DistributeOptions get distributeOptions {
    if (_distributeOptions == null) {
      File file = File('distribute_options.yaml');
      if (file.existsSync()) {
        final yamlString = File('distribute_options.yaml').readAsStringSync();
        final yamlDoc = loadYaml(yamlString);
        _distributeOptions = DistributeOptions.fromJson(
          json.decode(json.encode(yamlDoc)),
        );
      } else {
        _distributeOptions = DistributeOptions(
          output: 'dist/',
          releases: [],
        );
      }
    }
    return _distributeOptions!;
  }

  Future<String?> _getCurrentVersion() async {
    try {
      var scriptFile = Platform.script.toFilePath();
      var pathToPubSpecYaml = p.join(p.dirname(scriptFile), '../pubspec.yaml');
      var pathToPubSpecLock = p.join(p.dirname(scriptFile), '../pubspec.lock');

      var pubSpecYamlFile = File(pathToPubSpecYaml);

      var pubSpecLockFile = File(pathToPubSpecLock);

      if (pubSpecLockFile.existsSync()) {
        var yamlDoc = loadYaml(await pubSpecLockFile.readAsString());
        if (yamlDoc['packages']['flutter_distributor'] == null) {
          var yamlDoc = loadYaml(await pubSpecYamlFile.readAsString());
          return yamlDoc['version'];
        }

        return yamlDoc['packages']['flutter_distributor']['version'];
      }
    } catch (_) {}
    return null;
  }

  Future<void> checkVersion() async {
    String? currentVersion = await _getCurrentVersion();
    String? latestVersion =
        await PubDevApi.getLatestVersionFromPackage('flutter_distributor');

    if (currentVersion != null &&
        latestVersion != null &&
        currentVersion.compareTo(latestVersion) < 0) {
      String msg = [
        '╔════════════════════════════════════════════════════════════════════════════╗',
        '║ A new version of Flutter Distributor is available!                         ║',
        '║                                                                            ║',
        '║ To update to the latest version, run "flutter_distributor upgrade".        ║',
        '╚════════════════════════════════════════════════════════════════════════════╝',
        '',
      ].join('\n');
      print(msg);
    }
    return Future.value();
  }

  Future<String?> getCurrentVersion() async {
    return await _getCurrentVersion();
  }

  Future<List<MakeResult>> package(
    String platform,
    List<String> targets, {
    String? channel,
    String? artifactName,
    required bool cleanBeforeBuild,
    required Map<String, dynamic> buildArguments,
    Map<String, String>? variables,
  }) async {
    List<MakeResult> makeResultList = [];

    try {
      Directory outputDirectory = distributeOptions.outputDirectory;
      if (!outputDirectory.existsSync()) {
        outputDirectory.createSync(recursive: true);
      }

      if (cleanBeforeBuild) {
        await _builder.clean();
      }

      bool isBuildOnlyOnce = platform != 'android';
      BuildResult? buildResult;

      for (String target in targets) {
        logger.info('Packaging ${pubspec.name} ${pubspec.version} as $target:');
        if (!isBuildOnlyOnce || (isBuildOnlyOnce && buildResult == null)) {
          try {
            buildResult = await _builder.build(
              platform,
              target: target,
              arguments: buildArguments,
              environment: variables ?? globalVariables,
            );
            print(
              const JsonEncoder.withIndent('  ').convert(buildResult.toJson()),
            );
            logger.info(
              'Successfully built ${buildResult.outputDirectory} in ${buildResult.duration!.inSeconds}s'
                  .brightGreen(),
            );
            logger.info(
              'Copying necessary dll files to the output directory...'
                  .brightBlue(),
            );
            // await copyDLL('msvcp140');
            // await copyDLL('vcruntime140_1');
            // await copyDLL('vcruntime140');
          } on UnsupportedError catch (error) {
            logger.warning('Warning: ${error.message}'.yellow());
            continue;
          } catch (error) {
            rethrow;
          }
        }

        if (buildResult != null) {
          String buildMode =
              buildArguments.containsKey('profile') ? 'profile' : 'release';
          Map<String, dynamic>? arguments = {
            'build_mode': buildMode,
            'flavor': buildArguments['flavor'],
            'channel': channel,
            'artifact_name': artifactName,
          };
          MakeResult makeResult = await _packager.package(
            platform,
            target,
            arguments,
            outputDirectory,
            buildOutputDirectory: buildResult.outputDirectory,
            buildOutputFiles: buildResult.outputFiles,
          );
          print(
            const JsonEncoder.withIndent('  ').convert(makeResult.toJson()),
          );
          FileSystemEntity artifact = makeResult.artifacts.first;
          logger.info(
            'Successfully packaged ${artifact.path}'.brightGreen(),
          );
          makeResultList.add(makeResult);
        }
      }
    } catch (error) {
      logger.severe(error.toString().red());
      if (error is Error) {
        logger.severe(error.stackTrace.toString().red());
      }
      rethrow;
    }

    return makeResultList;
  }

  Future<void> copyDLL(String dllName) async {
    // Get the path to the current directory
    String currentDirectory = Directory.current.path;

    // Determine the path to the build directory based on the current directory
    String buildDirectoryPath = '$currentDirectory/build';

    // Check if the build directory exists
    if (await Directory(buildDirectoryPath).exists()) {
      // Determine the path to the Windows build directory
      String windowsBuildDirectoryPath = '$buildDirectoryPath/windows';

      // Check if the Windows build directory exists
      if (await Directory(windowsBuildDirectoryPath).exists()) {
        // Determine the path to the x64 build directory
        String x64BuildDirectoryPath = '$windowsBuildDirectoryPath/x64';

        // Check if the x64 build directory exists
        if (await Directory(x64BuildDirectoryPath).exists()) {
          // Determine the path to the runner directory
          String runnerDirectoryPath = '$x64BuildDirectoryPath/runner';

          // Check if the runner directory exists
          if (await Directory(runnerDirectoryPath).exists()) {
            // Determine the path to the Release directory
            String releaseDirectoryPath = '$runnerDirectoryPath/Release';

            // Check if the Release directory exists
            if (await Directory(releaseDirectoryPath).exists()) {
              // Path to the DLL file in the assets directory
              String dllAssetPath = '$currentDirectory/assets/dlls/$dllName.dll';

              try {
                // Read the DLL file
                File dllFile = File(dllAssetPath);
                Uint8List bytes = await dllFile.readAsBytes();

                // Write the DLL file to the Release directory
                String dllTargetPath = '$releaseDirectoryPath/$dllName.dll';
                await File(dllTargetPath).writeAsBytes(bytes);
                logger.info(
                  'DLL file copied successfully to $dllTargetPath'
                      .brightGreen(),
                );
                return;
              } catch (e) {
                logger.info(
                  'Error copying DLL file: $e'.brightRed(),
                );
                return;
              }
            }
          }
        }
      }
    }
    logger.info(
      'Error: Unable to locate the release directory for copying DLL file.'
          .brightRed(),
    );
  }

  Future<List<PublishResult>> publish(
    FileSystemEntity fileSystemEntity,
    List<String> targets, {
    Map<String, dynamic>? publishArguments,
    Map<String, String>? variables,
  }) async {
    List<PublishResult> publishResultList = [];
    try {
      for (String target in targets) {
        ProgressBar progressBar = ProgressBar(
          format: 'Publishing to $target: {bar} {value}/{total} {percentage}%',
        );

        Map<String, dynamic>? newPublishArguments = {};

        if (publishArguments != null) {
          for (var key in publishArguments.keys) {
            if (!key.startsWith('$target-')) continue;
            dynamic value = publishArguments[key];

            if (value is List) {
              // ignore: prefer_for_elements_to_map_fromiterable
              value = Map.fromIterable(
                value,
                key: (e) => e.split('=')[0],
                value: (e) => e.split('=')[1],
              );
            }

            newPublishArguments.putIfAbsent(
              key.replaceAll('$target-', ''),
              () => value,
            );
          }
        }

        if (newPublishArguments.keys.isEmpty) {
          newPublishArguments = publishArguments;
        }

        PublishResult publishResult = await _publisher.publish(
          fileSystemEntity,
          target: target,
          environment: variables ?? globalVariables,
          publishArguments: newPublishArguments,
          onPublishProgress: (sent, total) {
            if (!progressBar.isActive) {
              progressBar.start(total, sent);
            } else {
              progressBar.update(sent);
            }
          },
        );
        if (progressBar.isActive) progressBar.stop();
        logger.info(
          'Successfully published ${publishResult.url}'.brightGreen(),
        );
        publishResultList.add(publishResult);
      }
    } on Error catch (error) {
      logger.severe(error.toString().brightRed());
      logger.severe(error.stackTrace.toString().brightRed());
    }
    return publishResultList;
  }

  Future<void> release(
    String name, {
    required List<String> jobNameList,
    required List<String> skipJobNameList,
    required bool cleanBeforeBuild,
  }) async {
    final time = Stopwatch()..start();

    try {
      Directory outputDirectory = distributeOptions.outputDirectory;
      if (!outputDirectory.existsSync()) {
        outputDirectory.createSync(recursive: true);
      }

      List<Release> releases = [];

      if (name.isNotEmpty) {
        releases =
            distributeOptions.releases.where((e) => e.name == name).toList();
      }

      if (releases.isEmpty) {
        throw Exception('Missing/incomplete `distribute_options.yaml` file.');
      }

      for (Release release in releases) {
        List<ReleaseJob> filteredJobs = release.jobs.where((e) {
          if (jobNameList.isNotEmpty) {
            return jobNameList.contains(e.name);
          }
          if (skipJobNameList.isNotEmpty) {
            return !skipJobNameList.contains(e.name);
          }
          return true;
        }).toList();
        if (filteredJobs.isEmpty) {
          throw Exception('No available jobs found in ${release.name}.');
        }

        bool needCleanBeforeBuild = cleanBeforeBuild;

        for (ReleaseJob job in filteredJobs) {
          logger.info('');
          logger.info(
            '${'===>'.blue()} ${'Releasing'.white(bold: true)} $name:${job.name.green(bold: true)}',
          );

          Map<String, String> variables = {}
            ..addAll(globalVariables)
            ..addAll(release.variables ?? {})
            ..addAll(job.variables ?? {});

          List<MakeResult> makeResultList = await package(
            job.package.platform,
            [job.package.target],
            channel: job.package.channel,
            artifactName: distributeOptions.artifactName,
            cleanBeforeBuild: needCleanBeforeBuild,
            buildArguments: job.package.buildArgs ?? {},
            variables: variables,
          );
          // Clean only once
          needCleanBeforeBuild = false;

          if (job.publish != null || job.publishTo != null) {
            String? publishTarget = job.publishTo ?? job.publish?.target;
            MakeResult makeResult = makeResultList.first;
            FileSystemEntity artifact = makeResult.artifacts.first;
            await publish(
              artifact,
              [publishTarget!],
              publishArguments: job.publish?.args,
              variables: variables,
            );
          }
        }
      }

      time.stop();
      logger.info('');
      logger.info(
        'RELEASE SUCCESSFUL in ${time.elapsed.inSeconds}s'.green(bold: true),
      );
    } catch (error, stacktrace) {
      time.stop();
      logger.info('');
      logger.severe(
        [
          'RELEASE FAILED in ${time.elapsed.inSeconds}s'.red(bold: true),
          error.toString().red(),
          stacktrace,
        ].join('\n'),
      );
    }
    return Future.value();
  }

  Future<void> upgrade() async {
    await $(
      'dart',
      ['pub', 'global', 'activate', 'flutter_distributor'],
    );
    return Future.value();
  }
}
