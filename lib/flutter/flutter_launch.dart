
import 'dart:async';

import 'package:atom/node/fs.dart';
import 'package:atom/node/process.dart';
import 'package:logging/logging.dart';

import '../debug/debugger.dart';
import '../debug/observatory_debugger.dart' show ObservatoryDebugger;
import '../flutter/flutter_devices.dart';
import '../launch/launch.dart';
import '../projects.dart';
import '../state.dart';
import 'flutter_daemon.dart';
import 'flutter_sdk.dart';

final Logger _logger = new Logger('atom.flutter_launch');

FlutterSdkManager _flutterSdk = deps[FlutterSdkManager];

FlutterDeviceManager get deviceManager => deps[FlutterDeviceManager];

class FlutterLaunchType extends LaunchType {
  static void register(LaunchManager manager) =>
      manager.registerLaunchType(new FlutterLaunchType());

  _LaunchInstance _lastLaunch;

  FlutterLaunchType([String launchType = 'flutter']) : super(launchType);

  bool get supportsChecked => false;

  bool canLaunch(String path, LaunchData data) {
    DartProject project = projectManager.getProjectFor(path);
    if (project == null) return false;

    if (!_flutterSdk.hasSdk) return false;

    // It's a flutter entry-point if it's in a Flutter project, has a main()
    // method, and imports a flutter package.
    if (data.hasMain && project.isFlutterProject()) {
      if (data.fileContents != null) {
        return data.fileContents.contains('"package:flutter/')
          || data.fileContents.contains("'package:flutter/");
      }
    }

    return false;
  }

  Future<Launch> performLaunch(LaunchManager manager, LaunchConfiguration configuration) {
    String path = configuration.primaryResource;
    DartProject project = projectManager.getProjectFor(path);
    if (project == null) return new Future.error("File not in a Dart project.");

    if (!_flutterSdk.hasSdk) {
      _flutterSdk.showInstallationInfo();
      return new Future.error("Unable to launch ${configuration.shortResourceName}; "
        " no Flutter SDK found.");
    }

    return _killLastLaunch().then((_) {
      _lastLaunch = new _RunLaunchInstance(project, configuration, this);
      return _lastLaunch.launch();
    });
  }

  void connectToApp(
    DartProject project,
    LaunchConfiguration configuration,
    int observatoryPort, {
    bool pipeStdio: true
  }) {
    if (!_flutterSdk.hasSdk) {
      _flutterSdk.showInstallationInfo();
      return;
    }

    _killLastLaunch().then((_) {
      _lastLaunch = new _ConnectLaunchInstance(
        project,
        configuration,
        this,
        observatoryPort,
        pipeStdio: pipeStdio
      );
      _lastLaunch.launch();
    });
  }

  String getDefaultConfigText() {
    return '''
# The starting route for the app.
route:
# Additional args for the flutter run command.
args:
''';
  }

  Future _killLastLaunch() {
    if (_lastLaunch == null) return new Future.value();
    Launch launch = _lastLaunch._launch;
    return launch.isTerminated ? new Future.value() : launch.kill();
  }
}

abstract class _LaunchInstance {
  final DartProject project;
  Launch _launch;
  int _observatoryPort;
  Device _device;
  DebugConnection debugConnection;

  _LaunchInstance(this.project) {
    _device = deviceManager.currentSelectedDevice;
  }

  bool get pipeStdio;

  Future<Launch> launch();

  void _connectToDebugger() {
    FlutterUriTranslator translator = new FlutterUriTranslator(_launch.project?.path);
    ObservatoryDebugger.connect(
      _launch,
      'localhost',
      _observatoryPort,
      uriTranslator: translator,
      pipeStdio: pipeStdio
    ).then((DebugConnection connection) {
      debugConnection = connection;
      _launch.servicePort.value = _observatoryPort;
    }).catchError((e) {
      _launch.pipeStdio(
        'Unable to connect to the Observatory at port ${_observatoryPort}.\n',
        error: true
      );
    });
  }
}

class _RunLaunchInstance extends _LaunchInstance {
  ProcessRunner _runner;
  List<String> _args;

  _RunLaunchInstance(
    DartProject project,
    LaunchConfiguration configuration,
    FlutterLaunchType launchType
  ) : super(project) {
    List<String> flutterArgs = configuration.argsAsList;

    // Use either `flutter run` or `flutter run_mojo`.
    _args = ['run'];

    // TODO(devoncarew): Remove after flutter run defaults to '--resident'.
    _args.add('--resident');

    // Pass in the run mode: --debug, --profile, or --release.
    BuildMode mode = deviceManager.runMode;
    _args.add('--${mode.name}');

    if (mode.supportsDebugging) {
      _observatoryPort = getOpenPort();
      _args.add('--debug-port=${_observatoryPort}');
      _args.add('--start-paused');
    }

    var route = configuration.typeArgs['route'];
    if (route is String && route.isNotEmpty) {
      _args.add('--route');
      _args.add(route);
    }

    if (_device != null) {
      _args.add('--device-id');
      _args.add(_device.id);
    }

    String relPath = fs.relativize(project.path, configuration.primaryResource);
    if (relPath != 'lib/main.dart') {
      _args.add('-t');
      _args.add(relPath);
    }

    _args.addAll(flutterArgs);

    String description = 'flutter ${_args.join(' ')}';

    _launch = new _FlutterLaunch(
      launchManager,
      launchType,
      configuration,
      configuration.shortResourceName,
      project,
      killHandler: _kill,
      cwd: project.path,
      title: description,
      targetName: _device?.name
    );
    launchManager.addLaunch(_launch);
  }

  bool get pipeStdio => false;

  Future<Launch> launch() async {
    FlutterTool flutter = _flutterSdk.sdk.flutterTool;

    _runner = _flutter(flutter, _args, cwd: project.path);
    _runner.execStreaming();
    _runner.onStdout.listen((String str) {
      _watchForObservatoryMessage(str);
      _launch.pipeStdio(str);
    });
    _runner.onStderr.listen((String str) => _launch.pipeStdio(str, error: true));
    _runner.onExit.then((code) => _launch.launchTerminated(code));

    return _launch;
  }

  void _watchForObservatoryMessage(String str) {
    // "Observatory listening on http://127.0.0.1:8100"
    if (!str.startsWith('Observatory listening on http'))
      return;

    if (_observatoryPort != null && _launch.servicePort.value == null) {
      new Future.delayed(new Duration(milliseconds: 100), _connectToDebugger);
    }
  }

  Future _kill() {
    if (_runner == null) {
      _launch.launchTerminated(1);
      return new Future.value();
    } else {
      // Tell the flutter run --resident process to quit.
      // TOOD(devoncarew): This is not reliable - the remote app is not terminating.
      _runner.write('q');
      _runner.write('\n');

      return new Future.delayed(new Duration(milliseconds: 250), () {
        _runner?.kill();
        _runner = null;
      });
    }
  }
}

class _ConnectLaunchInstance extends _LaunchInstance {
  int _observatoryDevicePort;
  bool pipeStdio;

  _ConnectLaunchInstance(
    DartProject project,
    LaunchConfiguration configuration,
    FlutterLaunchType launchType,
    this._observatoryDevicePort, {
    this.pipeStdio
  }) : super(project) {
    String description = 'Flutter connect to port $_observatoryDevicePort';

    _launch = new _FlutterLaunch(
      launchManager,
      launchType,
      configuration,
      configuration.shortResourceName,
      project,
      killHandler: _kill,
      cwd: project.path,
      title: description,
      targetName: _device?.name
    );
    launchManager.addLaunch(_launch);
  }

  Future<Launch> launch() async {
    _observatoryPort = await _daemon.device.forward(_device.id, _observatoryDevicePort);
    _connectToDebugger();
    return _launch;
  }

  Future _kill() {
    _daemon.device.unforward(_device.id, _observatoryDevicePort, _observatoryPort);
    _launch.launchTerminated(0);
    return new Future.value();
  }

  FlutterDaemon get _daemon => deps[FlutterDaemonManager].daemon;
}

ProcessRunner _flutter(FlutterTool flutter, List<String> args, {String cwd}) {
  return flutter.runRaw(args, cwd: cwd, startProcess: false);
}

// TODO: Move _LaunchInstance functionality into this class?
class _FlutterLaunch extends Launch {
  CachingServerResolver _resolver;

  _FlutterLaunch(
    LaunchManager manager,
    LaunchType launchType,
    LaunchConfiguration launchConfiguration,
    String name,
    DartProject project, {
    Function killHandler,
    String cwd,
    String title,
    String targetName
  }) : super(
    manager,
    launchType,
    launchConfiguration,
    name,
    killHandler: killHandler,
    cwd: cwd,
    title: title,
    targetName: targetName
  ) {
    _resolver = new CachingServerResolver(
      cwd: project.path,
      server: analysisServer
    );

    exitCode.onChanged.first.then((_) => _resolver.dispose());
  }

  String get locationLabel => project.workspaceRelativeName;

  Future<String> resolve(String url) => _resolver.resolve(url);
}

class FlutterUriTranslator implements UriTranslator {
  static const _packagesPrefix = 'packages/';
  static const _packagePrefix = 'package:';

  final String root;

  FlutterUriTranslator(this.root);

  String targetToClient(String str) {
    String result = _targetToClient(str);
    _logger.finer('targetToClient ${str} ==> ${result}');
    return result;
  }

  String _targetToClient(String str) {
    if (str.startsWith(_packagesPrefix)) {
      // Convert packages/ prefix to package: one.
      return _packagePrefix + str.substring(_packagesPrefix.length);
    } else if (fs.existsSync(str)) {
      return new Uri.file(str).toString();
    } else {
      return str;
    }
  }

  String clientToTarget(String str) {
    String result = _clientToTarget(str);
    _logger.finer('clientToTarget ${str} ==> ${result}');
    return result;
  }

  String _clientToTarget(String str) {
    if (str.startsWith(_packagePrefix)) {
      // Convert package: prefix to packages/ one.
      return _packagesPrefix + str.substring(_packagePrefix.length);
    } else if (str.startsWith('file:')) {
      return Uri.parse(str).toFilePath();
    } else {
      return str;
    }
  }
}

// class FlutterUriTranslator implements UriTranslator {
//   static const _packagesPrefix = 'packages/';
//   static const _packagePrefix = 'package:';
//
//   final String root;
//   final String prefix;
//
//   String _rootPrefix;
//
//   FlutterUriTranslator(this.root, {this.prefix: 'http://localhost:9888/'}) {
//     _rootPrefix = new Uri.directory(root, windows: isWindows).toString();
//   }
//
//   String targetToClient(String str) {
//     String result = _targetToClient(str);
//     _logger.finer('targetToClient ${str} ==> ${result}');
//     return result;
//   }
//
//   String _targetToClient(String str) {
//     if (str.startsWith(prefix)) {
//       str = str.substring(prefix.length);
//
//       if (str.startsWith(_packagesPrefix)) {
//         // Convert packages/ prefix to package: one.
//         return _packagePrefix + str.substring(_packagesPrefix.length);
//       } else {
//         // Return files relative to the starting project.
//         return '${_rootPrefix}${str}';
//       }
//     } else {
//       return str;
//     }
//   }
//
//   String clientToTarget(String str) {
//     String result = _clientToTarget(str);
//     _logger.finer('clientToTarget ${str} ==> ${result}');
//     return result;
//   }
//
//   String _clientToTarget(String str) {
//     if (str.startsWith(_packagePrefix)) {
//       // Convert package: prefix to packages/ one.
//       return prefix + _packagesPrefix + str.substring(_packagePrefix.length);
//     } else if (str.startsWith(_rootPrefix)) {
//       // Convert file:///foo/bar/lib/main.dart to http://.../lib/main.dart.
//       return prefix + str.substring(_rootPrefix.length);
//     } else {
//       return str;
//     }
//   }
// }
