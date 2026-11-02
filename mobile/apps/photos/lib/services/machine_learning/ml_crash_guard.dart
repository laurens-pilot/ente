import "dart:convert";
import "dart:io";

import "package:logging/logging.dart";
import "package:path_provider/path_provider.dart";
import "package:photos/utils/ml_util.dart";

typedef _CrashGuardState = ({
  int? pid,
  List<int> inFlightFileKeys,
  bool stopRequested,
  bool attributable,
  Map<int, int> deathsByFileKey,
});

class MlCrashGuard {
  MlCrashGuard([this._directory = getApplicationSupportDirectory]);

  static const _maxDeathsBeforeSkip = 3;
  static const _maxTrackedFiles = 50;

  final Future<Directory> Function() _directory;
  final _logger = Logger("MlCrashGuard");
  final Set<int> _inFlightFileKeys = {};

  File? _stateFile;
  bool _appResumed = false;
  bool _stopRequested = false;
  Map<int, int> _deathsByFileKey = {};

  bool get _canAttributeDeaths => _appResumed && !_stopRequested;

  Future<void> recover(MLMode mode) async {
    _stateFile = null;
    _inFlightFileKeys.clear();
    _stopRequested = false;
    _deathsByFileKey = {};
    final directory = await _directory();
    final stateFile = File("${directory.path}/${_fileName(mode)}");
    final state = _read(stateFile);
    _deathsByFileKey = state.deathsByFileKey;
    _stateFile = stateFile;
    final leftover = state.inFlightFileKeys;
    if (leftover.isEmpty) return;
    if (state.pid == pid) {
      _logger.info(
        "ML engine ended without the process exiting while processing "
        "fileIDs $leftover, not counting it",
      );
    } else if (state.stopRequested) {
      _logger.info(
        "ML process exited after a stop request while processing fileIDs "
        "$leftover, not counting it",
      );
    } else if (state.attributable && leftover.length == 1) {
      final fileKey = leftover.single;
      _recordDeath(fileKey);
      _logger.warning(
        "ML process died while processing fileID $fileKey "
        "(${_deathsByFileKey[fileKey]}/$_maxDeathsBeforeSkip)",
      );
    } else {
      leftover.forEach(_markSuspect);
      _logger.warning(
        "ML process exited while processing fileIDs $leftover, retrying "
        "them one at a time in the foreground",
      );
    }
    _persist();
  }

  bool isSuspect(int fileKey) => _deathsByFileKey.containsKey(fileKey);

  bool canRetrySuspect(int fileKey) =>
      _canAttributeDeaths || hasRepeatedlyCrashed(fileKey);

  bool hasRepeatedlyCrashed(int fileKey) =>
      (_deathsByFileKey[fileKey] ?? 0) >= _maxDeathsBeforeSkip;

  Future<T> track<T>(int fileKey, Future<T> Function() work) async {
    _inFlightFileKeys.add(fileKey);
    _persist();
    try {
      return await work();
    } finally {
      _inFlightFileKeys.remove(fileKey);
      _persist();
    }
  }

  void setAppResumed(bool resumed) {
    if (_appResumed == resumed) return;
    _appResumed = resumed;
    if (_inFlightFileKeys.isNotEmpty) _persist();
  }

  void markStopRequested() {
    if (_stopRequested) return;
    _stopRequested = true;
    if (_inFlightFileKeys.isNotEmpty) _persist();
  }

  void forget(int fileKey) {
    if (_deathsByFileKey.remove(fileKey) != null) _persist();
  }

  void _recordDeath(int fileKey) {
    final deaths = (_deathsByFileKey.remove(fileKey) ?? 0) + 1;
    _deathsByFileKey[fileKey] = deaths;
    _evictOldest();
  }

  void _markSuspect(int fileKey) {
    _deathsByFileKey.putIfAbsent(fileKey, () => 0);
    _evictOldest();
  }

  void _evictOldest() {
    while (_deathsByFileKey.length > _maxTrackedFiles) {
      _deathsByFileKey.remove(_deathsByFileKey.keys.first);
    }
  }

  String _fileName(MLMode mode) => mode == MLMode.localGallery
      ? "ml_crash_guard_offline.json"
      : "ml_crash_guard.json";

  _CrashGuardState _read(File stateFile) {
    try {
      if (!stateFile.existsSync()) return _emptyState;
      final json =
          jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
      final deaths = json["deathsByFileKey"] as Map<String, dynamic>;
      return (
        pid: json["pid"] as int?,
        inFlightFileKeys: (json["inFlightFileKeys"] as List).cast<int>(),
        stopRequested: json["stopRequested"] as bool,
        attributable: json["attributable"] as bool,
        deathsByFileKey: {
          for (final entry in deaths.entries)
            int.parse(entry.key): entry.value as int,
        },
      );
    } catch (e, s) {
      _logger.warning("Ignoring unreadable ML crash guard state", e, s);
      return _emptyState;
    }
  }

  _CrashGuardState get _emptyState => (
    pid: null,
    inFlightFileKeys: [],
    stopRequested: false,
    attributable: false,
    deathsByFileKey: {},
  );

  void _persist() {
    final stateFile = _stateFile;
    if (stateFile == null) return;
    try {
      final tempFile = File("${stateFile.path}.tmp");
      tempFile.writeAsStringSync(
        jsonEncode({
          "pid": pid,
          "inFlightFileKeys": _inFlightFileKeys.toList(),
          "stopRequested": _stopRequested,
          "attributable": _canAttributeDeaths,
          "deathsByFileKey": {
            for (final entry in _deathsByFileKey.entries)
              "${entry.key}": entry.value,
          },
        }),
      );
      tempFile.renameSync(stateFile.path);
    } catch (e, s) {
      _logger.warning("Failed to persist ML crash guard state", e, s);
    }
  }
}
