import "dart:collection";
import "dart:convert";

import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:flutter_timezone/flutter_timezone.dart";
import "package:logging/logging.dart";
import "package:photos/db/device_files_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/extensions/user_extension.dart";
import "package:photos/models/api/collection/user.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file/file_type.dart";
import "package:photos/models/location_tag/location_tag.dart";
import "package:photos/models/search/generic_search_result.dart";
import "package:photos/models/search/hierarchical/hierarchical_search_filter.dart";
import "package:photos/models/search/hierarchical/top_level_generic_filter.dart";
import "package:photos/models/search/search_constants.dart";
import "package:photos/models/search/search_types.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/account/user_service.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/services/location_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/ml_computer.dart";
import "package:photos/services/machine_learning/semantic_search/semantic_search_service.dart";
import "package:photos/services/search_service.dart";
import "package:photos/services/timezone_aliases.dart";
import "package:photos/utils/file_util.dart";

class NaturalSearchService {
  NaturalSearchService._privateConstructor();

  static final NaturalSearchService instance =
      NaturalSearchService._privateConstructor();

  static const String _toolSchemaAssetPath =
      "assets/natural_search/tool_schema_search_photos_v1.JSON";
  static const String _developerPromptAssetPath =
      "assets/natural_search/developer_message.txt";
  static const String _examplePromptContextAssetPath =
      "assets/natural_search/example_dynamic_prompt_context.JSON";
  static const String _toolName = "search_photos_v1";

  static const Set<String> _timeFilterKinds = {
    "absolute_range",
    "multiple_ranges",
    "calendar_month",
    "calendar_year",
    "day_month_year",
    "day_month_every_year",
    "month_every_year",
  };

  static const Set<String> _ownershipScopes = {
    "mine",
    "shared_with_me",
    "shared_by_contacts",
    "all_accessible",
  };

  static const Set<String> _personOperators = {"any", "all"};

  static const Set<String> _allowedArgumentFields = {
    "time_filter",
    "ente_album_names",
    "device_album_names",
    "file_types",
    "filename_query",
    "caption_query",
    "camera_make_query",
    "camera_model_query",
    "ownership_scope",
    "contact_names",
    "person_names",
    "person_operator",
    "location_tag_names",
    "place_queries",
    "semantic_query",
    "video_duration_seconds",
    "file_size_mb",
    "limit",
  };

  final _logger = Logger("NaturalSearchService");

  String? _cachedToolSchemaRaw;
  Map<String, dynamic>? _cachedToolSchema;
  String? _cachedDeveloperPrompt;
  Map<String, dynamic>? _cachedExampleContext;

  Future<NaturalSearchModelInput> buildModelInput(String userQuery) async {
    final normalizedQuery = userQuery.trim();
    final toolSchema = await _loadToolSchema();
    final developerPromptBase = await _loadDeveloperPrompt();
    final dynamicContext = await _buildDynamicPromptContext();
    const encoder = JsonEncoder.withIndent("  ");
    final promptContextJson = encoder.convert(dynamicContext);

    final developerPrompt =
        "$developerPromptBase\n\nRuntime context JSON:\n$promptContextJson";

    return NaturalSearchModelInput(
      userQuery: normalizedQuery,
      developerPrompt: developerPrompt,
      toolSchema: toolSchema,
      dynamicContext: dynamicContext,
      toolSchemaRaw: _cachedToolSchemaRaw!,
    );
  }

  NaturalSearchParsedToolCall parseModelOutput(String rawOutput) {
    final parsed = parseToolCallPayload(rawOutput);
    final normalizedArguments = _normalizeArguments(parsed.arguments);

    return NaturalSearchParsedToolCall(
      name: parsed.name,
      arguments: normalizedArguments.arguments,
      warnings: [...parsed.warnings, ...normalizedArguments.warnings],
      rawCallJson: parsed.rawCallJson,
    );
  }

  Future<NaturalSearchExecutionResult> executeParsedCall({
    required String originalQuery,
    required NaturalSearchParsedToolCall parsedToolCall,
    String? rawFunctionGemmaToolCallOutput,
  }) {
    return executeToolArguments(
      originalQuery: originalQuery,
      toolArguments: parsedToolCall.arguments,
      parserWarnings: parsedToolCall.warnings,
      rawFunctionGemmaToolCallOutput: rawFunctionGemmaToolCallOutput,
    );
  }

  Future<NaturalSearchExecutionResult> executeToolArguments({
    required String originalQuery,
    required Map<String, dynamic> toolArguments,
    List<String> parserWarnings = const [],
    String? rawFunctionGemmaToolCallOutput,
  }) async {
    final normalizationResult = _normalizeArguments(toolArguments);
    final normalizedArguments = normalizationResult.arguments;
    final warnings = <String>[
      ...parserWarnings,
      ...normalizationResult.warnings,
    ];

    final allFiles = await SearchService.instance.getAllFilesForSearch();
    var workingFiles = List<EnteFile>.from(allFiles);
    final resolvedArguments = <String, dynamic>{};

    if (normalizedArguments.containsKey("ownership_scope")) {
      final result = await _applyOwnershipScopeFilter(
        files: workingFiles,
        arguments: normalizedArguments,
      );
      workingFiles = result.files;
      resolvedArguments.addAll(result.resolvedArguments);
      warnings.addAll(result.warnings);
    }

    if (normalizedArguments.containsKey("time_filter")) {
      final timeFilter =
          normalizedArguments["time_filter"] as Map<String, dynamic>;
      final ranges = resolveTimeFilterToRanges(
        timeFilter,
        searchStartYearOverride: searchStartYear,
        nowOverride: DateTime.now(),
      );
      if (ranges.isEmpty) {
        warnings.add("time_filter resolved to 0 ranges; skipping time filter");
      } else {
        resolvedArguments["time_ranges_micros"] = ranges
            .map(
              (range) => {
                "start_microseconds": range.startMicroseconds,
                "end_microseconds_exclusive": range.endMicrosecondsExclusive,
              },
            )
            .toList(growable: false);
        workingFiles = workingFiles.where((file) {
          final createdAt = file.creationTime;
          if (createdAt == null) {
            return false;
          }
          for (final range in ranges) {
            if (range.contains(createdAt)) {
              return true;
            }
          }
          return false;
        }).toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("ente_album_names")) {
      final requestedNames =
          (normalizedArguments["ente_album_names"] as List<String>);
      final resolution = _resolveEnteAlbumIDs(requestedNames);
      if (resolution.collectionIds.isEmpty) {
        warnings.add("No matching Ente albums found for ente_album_names");
        workingFiles = [];
      } else {
        resolvedArguments["ente_album_collection_ids"] =
            resolution.collectionIds.toList(growable: false);
        workingFiles = workingFiles.where((file) {
          final collectionID = file.collectionID;
          return collectionID != null &&
              resolution.collectionIds.contains(collectionID);
        }).toList(growable: false);
      }
      warnings.addAll(resolution.warnings);
    }

    if (normalizedArguments.containsKey("device_album_names")) {
      final requestedNames =
          (normalizedArguments["device_album_names"] as List<String>);
      final resolution = await _resolveDeviceAlbumLocalIDs(requestedNames);
      if (resolution.localIDs.isEmpty) {
        warnings.add("No matching device albums found for device_album_names");
        workingFiles = [];
      } else {
        resolvedArguments["device_album_path_ids"] =
            resolution.pathIDs.toList(growable: false);
        workingFiles = workingFiles.where((file) {
          final localID = file.localID;
          return localID != null && resolution.localIDs.contains(localID);
        }).toList(growable: false);
      }
      warnings.addAll(resolution.warnings);
    }

    if (normalizedArguments.containsKey("file_types")) {
      final fileTypes =
          _resolveFileTypes(normalizedArguments["file_types"] as List<String>);
      if (fileTypes.isEmpty) {
        warnings.add("No valid file types resolved from file_types");
        workingFiles = [];
      } else {
        resolvedArguments["file_types"] =
            fileTypes.map((fileType) => fileType.name).toList(growable: false);
        workingFiles = workingFiles
            .where((file) => fileTypes.contains(file.fileType))
            .toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("filename_query")) {
      final query = normalizedArguments["filename_query"] as String;
      workingFiles = workingFiles.where((file) {
        return file.displayName.toLowerCase().contains(query.toLowerCase());
      }).toList(growable: false);
    }

    if (normalizedArguments.containsKey("caption_query")) {
      final query = normalizedArguments["caption_query"] as String;
      workingFiles = workingFiles.where((file) {
        final caption = file.caption;
        return caption != null &&
            caption.toLowerCase().contains(query.toLowerCase());
      }).toList(growable: false);
    }

    if (normalizedArguments.containsKey("camera_make_query")) {
      final query = normalizedArguments["camera_make_query"] as String;
      workingFiles = workingFiles.where((file) {
        final make = file.cameraMake;
        return make != null && make.toLowerCase().contains(query.toLowerCase());
      }).toList(growable: false);
    }

    if (normalizedArguments.containsKey("camera_model_query")) {
      final query = normalizedArguments["camera_model_query"] as String;
      workingFiles = workingFiles.where((file) {
        final model = file.cameraModel;
        return model != null &&
            model.toLowerCase().contains(query.toLowerCase());
      }).toList(growable: false);
    }

    if (normalizedArguments.containsKey("person_names")) {
      final requestedNames =
          normalizedArguments["person_names"] as List<String>;
      final personOperator =
          (normalizedArguments["person_operator"] as String?) ?? "any";
      final resolution = await _resolvePersonUploadedIDs(
        requestedNames,
        personOperator,
      );
      warnings.addAll(resolution.warnings);
      resolvedArguments["person_ids"] = resolution.personIDs;

      if (resolution.uploadedIDs.isEmpty) {
        workingFiles = [];
      } else {
        workingFiles = workingFiles.where((file) {
          final uploadedID = file.uploadedFileID;
          return uploadedID != null &&
              resolution.uploadedIDs.contains(uploadedID);
        }).toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("location_tag_names")) {
      final requestedNames =
          normalizedArguments["location_tag_names"] as List<String>;
      final resolution = await _resolveLocationTags(requestedNames);
      warnings.addAll(resolution.warnings);
      resolvedArguments["location_tag_names_resolved"] =
          resolution.tags.map((tag) => tag.name).toList(growable: false);

      if (resolution.tags.isEmpty) {
        workingFiles = [];
      } else {
        workingFiles = workingFiles.where((file) {
          if (!file.hasLocation) {
            return false;
          }
          for (final tag in resolution.tags) {
            if (isFileInsideLocationTag(
              tag.centerPoint,
              file.location!,
              tag.radius,
            )) {
              return true;
            }
          }
          return false;
        }).toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("place_queries")) {
      final placeQueries = normalizedArguments["place_queries"] as List<String>;
      final resolution = await _resolveFilesForPlaceQueries(
        files: workingFiles,
        placeQueries: placeQueries,
      );
      warnings.addAll(resolution.warnings);
      resolvedArguments["place_query_matches"] = resolution.matchesSummary;
      if (resolution.files.isEmpty) {
        workingFiles = [];
      } else {
        final matched = resolution.files.toSet();
        workingFiles = workingFiles
            .where((file) => matched.contains(file))
            .toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("semantic_query")) {
      final semanticQuery = normalizedArguments["semantic_query"] as String;
      final semanticResult = await _resolveSemanticQuery(semanticQuery);
      warnings.addAll(semanticResult.warnings);
      resolvedArguments["semantic_query_resolved"] = {
        "query": semanticQuery,
        "matched_uploaded_ids":
            semanticResult.uploadedIDs.toList(growable: false),
      };

      if (semanticResult.uploadedIDs.isEmpty) {
        workingFiles = [];
      } else {
        workingFiles = workingFiles.where((file) {
          final uploadedID = file.uploadedFileID;
          return uploadedID != null &&
              semanticResult.uploadedIDs.contains(uploadedID);
        }).toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("video_duration_seconds")) {
      final range = _resolveNumericRange(
        normalizedArguments["video_duration_seconds"] as Map<String, dynamic>,
      );
      warnings.addAll(range.warnings);
      if (!range.isValid) {
        workingFiles = [];
      } else {
        resolvedArguments["video_duration_seconds"] = range.toJson();
        workingFiles = workingFiles.where((file) {
          if (!file.isVideo || file.duration == null) {
            return false;
          }
          return range.contains(file.duration!);
        }).toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("file_size_mb")) {
      final range = _resolveNumericRange(
        normalizedArguments["file_size_mb"] as Map<String, dynamic>,
      );
      warnings.addAll(range.warnings);
      if (!range.isValid) {
        workingFiles = [];
      } else {
        final minBytes = range.min != null ? range.min! * 1024 * 1024 : null;
        final maxBytes = range.max != null ? range.max! * 1024 * 1024 : null;
        resolvedArguments["file_size_bytes"] = {
          if (minBytes != null) "min": minBytes,
          if (maxBytes != null) "max": maxBytes,
        };
        workingFiles = workingFiles.where((file) {
          final fileSize = file.fileSize;
          if (fileSize == null) {
            return false;
          }
          if (minBytes != null && fileSize < minBytes) {
            return false;
          }
          if (maxBytes != null && fileSize > maxBytes) {
            return false;
          }
          return true;
        }).toList(growable: false);
      }
    }

    _sortFilesChronologically(workingFiles);

    final limit = normalizedArguments["limit"] as int?;
    if (limit != null && limit >= 0 && workingFiles.length > limit) {
      workingFiles = workingFiles.sublist(0, limit);
    }

    if (kDebugMode) {
      _logger.info(
        "Natural search app-layer parameters for '$originalQuery':\n"
        "normalized_tool_arguments=${jsonEncode(normalizedArguments)}\n"
        "resolved_arguments=${jsonEncode(resolvedArguments)}\n"
        "warnings=${jsonEncode(warnings)}\n"
        "matched_file_count=${workingFiles.length}",
      );
    }

    final executionFilter = TopLevelGenericFilter(
      filterName: originalQuery,
      occurrence: kMostRelevantFilter,
      filterResultType: ResultType.file,
      matchedUploadedIDs: filesToUploadedFileIDs(workingFiles),
    );
    final searchResultParams = <String, dynamic>{
      if (rawFunctionGemmaToolCallOutput != null)
        kFunctionGemmaRawToolCallOutput: rawFunctionGemmaToolCallOutput,
    };

    return NaturalSearchExecutionResult(
      originalQuery: originalQuery,
      normalizedToolArguments: normalizedArguments,
      resolvedArguments: resolvedArguments,
      files: workingFiles,
      warnings: warnings,
      initialFilter: executionFilter,
      rawFunctionGemmaToolCallOutput: rawFunctionGemmaToolCallOutput,
      searchResult: GenericSearchResult(
        ResultType.magic,
        originalQuery,
        workingFiles,
        params: searchResultParams,
        hierarchicalSearchFilter: executionFilter,
      ),
    );
  }

  Future<NaturalSearchExecutionResult> runNaturalSearchQuery(
    String userQuery,
  ) async {
    final modelInput = await buildModelInput(userQuery);
    final promptPayloadJson = buildFunctionGemmaPromptPayloadJson(
      developerPrompt: modelInput.developerPrompt,
      toolSchemaRaw: modelInput.toolSchemaRaw,
      userQuery: modelInput.userQuery,
    );
    final inferenceResult =
        await MLComputer.instance.runFunctionGemmaNaturalSearch(
      promptPayloadJson,
    );
    final parsedToolCall =
        parseModelOutput(inferenceResult.normalizedToolCallJson);
    if (kDebugMode) {
      _logger.info(
        "FunctionGemma raw output for '${modelInput.userQuery}':\n${inferenceResult.rawOutput}",
      );
      _logger.info(
        "FunctionGemma normalized tool call for '${modelInput.userQuery}':\n${jsonEncode(parsedToolCall.rawCallJson)}",
      );
    }
    return executeParsedCall(
      originalQuery: modelInput.userQuery,
      parsedToolCall: parsedToolCall,
      rawFunctionGemmaToolCallOutput: inferenceResult.rawOutput,
    );
  }

  @visibleForTesting
  static String buildFunctionGemmaPromptPayloadJson({
    required String developerPrompt,
    required String toolSchemaRaw,
    required String userQuery,
  }) {
    return jsonEncode({
      "developer_prompt": developerPrompt,
      "tool_schema_json": toolSchemaRaw,
      "user_query": userQuery,
    });
  }

  @visibleForTesting
  static ParsedToolCall parseToolCallPayload(String rawOutput) {
    final output = rawOutput.trim();
    if (output.isEmpty) {
      throw const FormatException("Model output is empty");
    }

    final warnings = <String>[];
    final stripped = _stripCodeFences(output);
    final extractedToolCallBlocks =
        _extractTaggedToolCallBlocks(stripped).toList(growable: false);

    String? jsonPayload;
    if (extractedToolCallBlocks.length > 1) {
      throw const FormatException(
        "Expected exactly one <tool_call> block but found multiple",
      );
    }
    if (extractedToolCallBlocks.length == 1) {
      jsonPayload = extractedToolCallBlocks.first.trim();
    }

    jsonPayload ??= _extractFirstJsonObject(stripped)?.trim();
    if (jsonPayload == null || jsonPayload.isEmpty) {
      throw const FormatException("Could not locate JSON tool-call payload");
    }

    final decoded = jsonDecode(jsonPayload);

    if (decoded is Map<String, dynamic>) {
      final parsed = _parseToolCallMap(decoded, warnings);
      return parsed;
    }

    throw FormatException(
      "Tool-call payload must be a JSON object. Got ${decoded.runtimeType}",
    );
  }

  @visibleForTesting
  static List<TimeRangeMicros> resolveTimeFilterToRanges(
    Map<String, dynamic> timeFilter, {
    required int searchStartYearOverride,
    required DateTime nowOverride,
  }) {
    final kindValue = timeFilter["kind"];
    if (kindValue is! String || !_timeFilterKinds.contains(kindValue)) {
      return const [];
    }

    final now = nowOverride;
    final currentYear = now.year;

    switch (kindValue) {
      case "absolute_range":
      case "multiple_ranges":
        final ranges = timeFilter["ranges"];
        if (ranges is! List) {
          return const [];
        }
        final resolvedRanges = <TimeRangeMicros>[];
        for (final item in ranges) {
          if (item is! Map<String, dynamic>) {
            continue;
          }
          final startString = item["start_local"] as String?;
          final endString = item["end_local_exclusive"] as String?;
          if (startString == null || endString == null) {
            continue;
          }
          final start = _tryParseLocalDateTime(startString);
          final end = _tryParseLocalDateTime(endString);
          if (start == null || end == null) {
            continue;
          }
          if (!end.isAfter(start)) {
            continue;
          }
          resolvedRanges.add(
            TimeRangeMicros(
              startMicroseconds: start.microsecondsSinceEpoch,
              endMicrosecondsExclusive: end.microsecondsSinceEpoch,
            ),
          );
        }
        return resolvedRanges;
      case "calendar_month":
        final year = _toInt(timeFilter["year"]);
        final month = _toInt(timeFilter["month"]);
        if (year == null || month == null || month < 1 || month > 12) {
          return const [];
        }
        final start = DateTime(year, month, 1);
        final end = month == 12
            ? DateTime(year + 1, 1, 1)
            : DateTime(year, month + 1, 1);
        return [
          TimeRangeMicros(
            startMicroseconds: start.microsecondsSinceEpoch,
            endMicrosecondsExclusive: end.microsecondsSinceEpoch,
          ),
        ];
      case "calendar_year":
        final year = _toInt(timeFilter["year"]);
        if (year == null) {
          return const [];
        }
        return [
          TimeRangeMicros(
            startMicroseconds: DateTime(year, 1, 1).microsecondsSinceEpoch,
            endMicrosecondsExclusive:
                DateTime(year + 1, 1, 1).microsecondsSinceEpoch,
          ),
        ];
      case "day_month_year":
        final day = _toInt(timeFilter["day"]);
        final month = _toInt(timeFilter["month"]);
        final year = _toInt(timeFilter["year"]);
        if (day == null || month == null || year == null) {
          return const [];
        }
        if (!_isValidGregorianDate(day: day, month: month, year: year)) {
          return const [];
        }
        final start = DateTime(year, month, day);
        final end = DateTime(year, month, day + 1);
        return [
          TimeRangeMicros(
            startMicroseconds: start.microsecondsSinceEpoch,
            endMicrosecondsExclusive: end.microsecondsSinceEpoch,
          ),
        ];
      case "day_month_every_year":
        final day = _toInt(timeFilter["day"]);
        final month = _toInt(timeFilter["month"]);
        if (day == null || month == null) {
          return const [];
        }
        final ranges = <TimeRangeMicros>[];
        for (var year = searchStartYearOverride; year <= currentYear; year++) {
          if (!_isValidGregorianDate(day: day, month: month, year: year)) {
            continue;
          }
          final start = DateTime(year, month, day);
          final end = DateTime(year, month, day + 1);
          ranges.add(
            TimeRangeMicros(
              startMicroseconds: start.microsecondsSinceEpoch,
              endMicrosecondsExclusive: end.microsecondsSinceEpoch,
            ),
          );
        }
        return ranges;
      case "month_every_year":
        final month = _toInt(timeFilter["month"]);
        if (month == null || month < 1 || month > 12) {
          return const [];
        }
        final ranges = <TimeRangeMicros>[];
        for (var year = searchStartYearOverride; year <= currentYear; year++) {
          final start = DateTime(year, month, 1);
          final end = month == 12
              ? DateTime(year + 1, 1, 1)
              : DateTime(year, month + 1, 1);
          ranges.add(
            TimeRangeMicros(
              startMicroseconds: start.microsecondsSinceEpoch,
              endMicrosecondsExclusive: end.microsecondsSinceEpoch,
            ),
          );
        }
        return ranges;
    }

    return const [];
  }

  Future<Map<String, dynamic>> _loadToolSchema() async {
    if (_cachedToolSchema != null) {
      return _cachedToolSchema!;
    }
    final raw = await rootBundle.loadString(_toolSchemaAssetPath);
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException("Tool schema JSON must be an object");
    }
    _cachedToolSchemaRaw = raw;
    _cachedToolSchema = decoded;
    return decoded;
  }

  Future<String> _loadDeveloperPrompt() async {
    if (_cachedDeveloperPrompt != null) {
      return _cachedDeveloperPrompt!;
    }
    _cachedDeveloperPrompt =
        (await rootBundle.loadString(_developerPromptAssetPath)).trim();
    return _cachedDeveloperPrompt!;
  }

  Future<Map<String, dynamic>> _loadExamplePromptContext() async {
    if (_cachedExampleContext != null) {
      return Map<String, dynamic>.from(_cachedExampleContext!);
    }
    final raw = await rootBundle.loadString(_examplePromptContextAssetPath);
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        "Example dynamic prompt context must be an object",
      );
    }
    _cachedExampleContext = decoded;
    return Map<String, dynamic>.from(decoded);
  }

  Future<Map<String, dynamic>> _buildDynamicPromptContext() async {
    final context = await _loadExamplePromptContext();

    context["current_local_datetime"] = _formatLocalDateTime(DateTime.now());
    context["local_timezone"] = await _resolveLocalTimezone();
    context["week_start"] = "monday";
    context["search_start_year"] = searchStartYear;

    context["available_ente_album_names"] =
        _getCanonicalEnteAlbumNames().toList(growable: false);
    context["available_device_album_names"] =
        (await _getCanonicalDeviceAlbumNames()).toList(growable: false);
    context["available_person_names"] =
        (await _getCanonicalPersonNames()).toList(growable: false);
    context["available_location_tag_names"] =
        (await _getCanonicalLocationTagNames()).toList(growable: false);
    context["available_contact_names"] =
        _getCanonicalContactNames().toList(growable: false);

    return context;
  }

  SplayTreeSet<String> _getCanonicalEnteAlbumNames() {
    final names = SplayTreeSet<String>(
      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    final collections = CollectionsService.instance.getCollectionsForUI(
      includedShared: true,
      includeCollab: true,
    );
    for (final collection in collections) {
      final name = collection.displayName.trim();
      if (name.isNotEmpty) {
        names.add(name);
      }
    }
    return names;
  }

  Future<SplayTreeSet<String>> _getCanonicalDeviceAlbumNames() async {
    final names = SplayTreeSet<String>(
      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    final deviceCollections = await FilesDB.instance.getDeviceCollections();
    for (final collection in deviceCollections) {
      final name = collection.name.trim();
      if (name.isNotEmpty) {
        names.add(name);
      }
    }
    return names;
  }

  Future<SplayTreeSet<String>> _getCanonicalPersonNames() async {
    final names = SplayTreeSet<String>(
      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    if (!PersonService.isInitialized) {
      return names;
    }
    final persons = await PersonService.instance.getPersons();
    for (final person in persons) {
      final name = person.data.name.trim();
      if (name.isNotEmpty && !person.data.isIgnored) {
        names.add(name);
      }
    }
    return names;
  }

  Future<SplayTreeSet<String>> _getCanonicalLocationTagNames() async {
    final names = SplayTreeSet<String>(
      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    final locationTags = await locationService.getLocationTags();
    for (final tag in locationTags) {
      final name = tag.item.name.trim();
      if (name.isNotEmpty) {
        names.add(name);
      }
    }
    return names;
  }

  SplayTreeSet<String> _getCanonicalContactNames() {
    final names = SplayTreeSet<String>(
      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    final contacts = UserService.instance.getRelevantContacts();
    for (final contact in contacts) {
      final email = contact.email.trim();
      if (email.isEmpty) {
        continue;
      }
      final displayName = contact.displayName?.trim();
      final canonical = displayName != null && displayName.isNotEmpty
          ? "$displayName <$email>"
          : email;
      names.add(canonical);
    }
    return names;
  }

  Future<String> _resolveLocalTimezone() async {
    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      if (timezone.trim().isEmpty) {
        return "UTC";
      }
      if (kTimeZoneAliases.containsKey(timezone)) {
        return kTimeZoneAliases[timezone]!;
      }
      return timezone;
    } catch (e, s) {
      _logger.warning("Could not resolve local timezone, using UTC", e, s);
      return "UTC";
    }
  }

  String _formatLocalDateTime(DateTime dateTime) {
    final year = dateTime.year.toString().padLeft(4, "0");
    final month = dateTime.month.toString().padLeft(2, "0");
    final day = dateTime.day.toString().padLeft(2, "0");
    final hour = dateTime.hour.toString().padLeft(2, "0");
    final minute = dateTime.minute.toString().padLeft(2, "0");
    final second = dateTime.second.toString().padLeft(2, "0");
    return "$year-$month-$day"
        "T$hour:$minute:$second";
  }

  _NormalizationResult _normalizeArguments(Map<String, dynamic> arguments) {
    final normalized = <String, dynamic>{};
    final warnings = <String>[];

    for (final entry in arguments.entries) {
      final key = entry.key;
      if (!_allowedArgumentFields.contains(key)) {
        warnings.add("Ignoring unknown argument field '$key'");
        continue;
      }

      final value = entry.value;
      if (value == null) {
        continue;
      }

      switch (key) {
        case "time_filter":
          if (value is Map<String, dynamic>) {
            final kind = value["kind"];
            if (kind is String && _timeFilterKinds.contains(kind)) {
              final cleaned = <String, dynamic>{"kind": kind};
              if (value["ranges"] is List) {
                final ranges = <Map<String, String>>[];
                for (final item in value["ranges"] as List) {
                  if (item is! Map<String, dynamic>) {
                    continue;
                  }
                  final start = item["start_local"];
                  final end = item["end_local_exclusive"];
                  if (start is String && end is String) {
                    ranges.add(
                      {
                        "start_local": start.trim(),
                        "end_local_exclusive": end.trim(),
                      },
                    );
                  }
                }
                if (ranges.isNotEmpty) {
                  cleaned["ranges"] = ranges;
                }
              }
              final year = _toInt(value["year"]);
              final month = _toInt(value["month"]);
              final day = _toInt(value["day"]);
              if (year != null) {
                cleaned["year"] = year;
              }
              if (month != null) {
                cleaned["month"] = month;
              }
              if (day != null) {
                cleaned["day"] = day;
              }
              normalized[key] = cleaned;
            } else {
              warnings.add("Ignoring invalid time_filter.kind '$kind'");
            }
          } else {
            warnings
                .add("Ignoring invalid time_filter type ${value.runtimeType}");
          }
          break;
        case "ente_album_names":
        case "device_album_names":
        case "contact_names":
        case "person_names":
        case "location_tag_names":
        case "place_queries":
          final array = _normalizeStringList(value);
          if (array.isNotEmpty) {
            normalized[key] = array;
          }
          break;
        case "file_types":
          final array = _normalizeStringList(value);
          if (array.isNotEmpty) {
            normalized[key] = array;
          }
          break;
        case "filename_query":
        case "caption_query":
        case "camera_make_query":
        case "camera_model_query":
        case "semantic_query":
          if (value is String && value.trim().isNotEmpty) {
            normalized[key] = value.trim();
          }
          break;
        case "ownership_scope":
          if (value is String && _ownershipScopes.contains(value.trim())) {
            normalized[key] = value.trim();
          } else {
            warnings.add("Ignoring invalid ownership_scope '$value'");
          }
          break;
        case "person_operator":
          if (value is String && _personOperators.contains(value.trim())) {
            normalized[key] = value.trim();
          } else {
            warnings.add("Ignoring invalid person_operator '$value'");
          }
          break;
        case "video_duration_seconds":
        case "file_size_mb":
          if (value is Map<String, dynamic>) {
            final range = <String, int>{};
            final min = _toInt(value["min"]);
            final max = _toInt(value["max"]);
            if (min != null && min >= 0) {
              range["min"] = min;
            }
            if (max != null && max >= 0) {
              range["max"] = max;
            }
            if (range.isNotEmpty) {
              normalized[key] = range;
            }
          }
          break;
        case "limit":
          final limit = _toInt(value);
          if (limit != null && limit > 0) {
            normalized[key] = limit;
          }
          break;
      }
    }

    if (normalized.containsKey("person_names") &&
        !normalized.containsKey("person_operator")) {
      normalized["person_operator"] = "any";
    }

    return _NormalizationResult(arguments: normalized, warnings: warnings);
  }

  Future<_OwnershipFilterResult> _applyOwnershipScopeFilter({
    required List<EnteFile> files,
    required Map<String, dynamic> arguments,
  }) async {
    final scope = arguments["ownership_scope"] as String?;
    if (scope == null) {
      return _OwnershipFilterResult(
        files: files,
        resolvedArguments: const {},
        warnings: const [],
      );
    }

    switch (scope) {
      case "mine":
        return _OwnershipFilterResult(
          files: files.where((file) => file.isOwner).toList(growable: false),
          resolvedArguments: const {"ownership_scope": "mine"},
          warnings: const [],
        );
      case "shared_with_me":
        return _OwnershipFilterResult(
          files: files.where((file) => !file.isOwner).toList(growable: false),
          resolvedArguments: const {"ownership_scope": "shared_with_me"},
          warnings: const [],
        );
      case "all_accessible":
        return _OwnershipFilterResult(
          files: files,
          resolvedArguments: const {"ownership_scope": "all_accessible"},
          warnings: const [],
        );
      case "shared_by_contacts":
        final requestedContacts =
            (arguments["contact_names"] as List<String>?) ?? const [];
        final contactResolution = _resolveContacts(requestedContacts);

        final ownerIDs = contactResolution.users
            .where((user) => user.id != null)
            .map((user) => user.id!)
            .toSet();
        final emails = contactResolution.users
            .map((user) => user.email.toLowerCase())
            .toSet();

        final allSharedByContactsFiles = files.where((file) {
          if (file.isOwner) {
            return false;
          }

          final ownerID = file.ownerID;
          if (ownerID != null && ownerIDs.contains(ownerID)) {
            return true;
          }

          if (ownerID != null) {
            final owner = CollectionsService.instance
                .getFileOwner(ownerID, file.collectionID);
            return emails.contains(owner.email.toLowerCase());
          }

          return false;
        }).toList(growable: false);

        return _OwnershipFilterResult(
          files: allSharedByContactsFiles,
          resolvedArguments: {
            "ownership_scope": "shared_by_contacts",
            "resolved_contact_emails": emails.toList(growable: false),
            "resolved_contact_user_ids": ownerIDs.toList(growable: false),
          },
          warnings: contactResolution.warnings,
        );
    }

    return _OwnershipFilterResult(
      files: files,
      resolvedArguments: const {},
      warnings: ["Unknown ownership_scope '$scope'; ownership filter skipped"],
    );
  }

  _EntityIDResolutionResult _resolveEnteAlbumIDs(List<String> requestedNames) {
    final warnings = <String>[];
    final normalizedToCollections = <String, Set<int>>{};

    final collections = CollectionsService.instance.getCollectionsForUI(
      includedShared: true,
      includeCollab: true,
    );

    for (final collection in collections) {
      final name = collection.displayName.trim();
      if (name.isEmpty) {
        continue;
      }
      normalizedToCollections
          .putIfAbsent(name.toLowerCase(), () => <int>{})
          .add(collection.id);
    }

    final resolvedIDs = <int>{};
    for (final requestedName in requestedNames) {
      final ids = normalizedToCollections[requestedName.toLowerCase()];
      if (ids == null || ids.isEmpty) {
        warnings.add("No Ente album found for '$requestedName'");
        continue;
      }
      resolvedIDs.addAll(ids);
    }

    return _EntityIDResolutionResult(
      collectionIds: resolvedIDs,
      warnings: warnings,
    );
  }

  Future<_DeviceAlbumResolutionResult> _resolveDeviceAlbumLocalIDs(
    List<String> requestedNames,
  ) async {
    final warnings = <String>[];
    final deviceCollections = await FilesDB.instance.getDeviceCollections();

    final normalizedToPathIDs = <String, Set<String>>{};
    for (final collection in deviceCollections) {
      final name = collection.name.trim();
      if (name.isEmpty) {
        continue;
      }
      normalizedToPathIDs
          .putIfAbsent(name.toLowerCase(), () => <String>{})
          .add(collection.id);
    }

    final requestedPathIDs = <String>{};
    for (final requestedName in requestedNames) {
      final pathIDs = normalizedToPathIDs[requestedName.toLowerCase()];
      if (pathIDs == null || pathIDs.isEmpty) {
        warnings.add("No device album found for '$requestedName'");
        continue;
      }
      requestedPathIDs.addAll(pathIDs);
    }

    final pathIDToLocalIDMap =
        await FilesDB.instance.getDevicePathIDToLocalIDMap();
    final localIDs = <String>{};
    for (final pathID in requestedPathIDs) {
      final ids = pathIDToLocalIDMap[pathID];
      if (ids != null) {
        localIDs.addAll(ids);
      }
    }

    return _DeviceAlbumResolutionResult(
      localIDs: localIDs,
      pathIDs: requestedPathIDs,
      warnings: warnings,
    );
  }

  Set<FileType> _resolveFileTypes(List<String> fileTypes) {
    final resolvedTypes = <FileType>{};
    for (final fileType in fileTypes) {
      switch (fileType) {
        case "image":
          resolvedTypes.add(FileType.image);
          break;
        case "video":
          resolvedTypes.add(FileType.video);
          break;
        case "live_photo":
          resolvedTypes.add(FileType.livePhoto);
          break;
      }
    }
    return resolvedTypes;
  }

  Future<_PersonResolutionResult> _resolvePersonUploadedIDs(
    List<String> requestedNames,
    String personOperator,
  ) async {
    final warnings = <String>[];
    if (!PersonService.isInitialized) {
      warnings.add("PersonService is not initialized");
      return _PersonResolutionResult(
        uploadedIDs: const <int>{},
        personIDs: const <String>[],
        warnings: warnings,
      );
    }

    final persons = await PersonService.instance.getPersons();
    final nameToPersonIDs = <String, Set<String>>{};

    for (final person in persons) {
      final name = person.data.name.trim();
      if (name.isEmpty || person.data.isIgnored) {
        continue;
      }
      nameToPersonIDs
          .putIfAbsent(name.toLowerCase(), () => <String>{})
          .add(person.remoteID);
    }

    final resolvedPersonIDs = <String>{};
    for (final requestedName in requestedNames) {
      final matchingIDs = nameToPersonIDs[requestedName.toLowerCase()];
      if (matchingIDs == null || matchingIDs.isEmpty) {
        warnings.add("No person found for '$requestedName'");
        continue;
      }
      resolvedPersonIDs.addAll(matchingIDs);
    }

    if (resolvedPersonIDs.isEmpty) {
      return _PersonResolutionResult(
        uploadedIDs: const <int>{},
        personIDs: const <String>[],
        warnings: warnings,
      );
    }

    Set<int>? combinedUploadedIDs;
    for (final personID in resolvedPersonIDs) {
      final files = await SearchService.instance.getFilesForPersonID(
        personID,
        sortOnTime: false,
      );
      final uploadedIDs = filesToUploadedFileIDs(files);
      if (combinedUploadedIDs == null) {
        combinedUploadedIDs = Set<int>.from(uploadedIDs);
      } else if (personOperator == "all") {
        combinedUploadedIDs = combinedUploadedIDs.intersection(uploadedIDs);
      } else {
        combinedUploadedIDs = combinedUploadedIDs.union(uploadedIDs);
      }
    }

    return _PersonResolutionResult(
      uploadedIDs: combinedUploadedIDs ?? const <int>{},
      personIDs: resolvedPersonIDs.toList(growable: false),
      warnings: warnings,
    );
  }

  Future<_LocationTagResolutionResult> _resolveLocationTags(
    List<String> requestedNames,
  ) async {
    final warnings = <String>[];
    final locationTags = await locationService.getLocationTags();
    final map = <String, List<LocationTag>>{};

    for (final localEntity in locationTags) {
      final tag = localEntity.item;
      map.putIfAbsent(tag.name.toLowerCase(), () => <LocationTag>[]).add(tag);
    }

    final resolvedTags = <LocationTag>[];
    for (final requestedName in requestedNames) {
      final tags = map[requestedName.toLowerCase()];
      if (tags == null || tags.isEmpty) {
        warnings.add("No location tag found for '$requestedName'");
        continue;
      }
      resolvedTags.addAll(tags);
    }

    return _LocationTagResolutionResult(tags: resolvedTags, warnings: warnings);
  }

  Future<_PlaceQueryResolutionResult> _resolveFilesForPlaceQueries({
    required List<EnteFile> files,
    required List<String> placeQueries,
  }) async {
    final warnings = <String>[];
    if (files.isEmpty) {
      return _PlaceQueryResolutionResult(
        files: const [],
        matchesSummary: const <String, dynamic>{},
        warnings: warnings,
      );
    }

    final cityToFiles = await locationService.getFilesInCity(files, "");
    final normalizedQueries = placeQueries
        .map((query) => query.trim().toLowerCase())
        .where((query) => query.isNotEmpty)
        .toSet();

    final matchedFiles = <EnteFile>{};
    final matchesSummary = <String, dynamic>{};

    for (final query in normalizedQueries) {
      final matchedCities = <String>[];
      for (final entry in cityToFiles.entries) {
        final city = entry.key;
        final cityName = city.city.toLowerCase();
        final countryName = city.country.toLowerCase();

        final cityMatched = cityName.contains(query);
        final countryMatched = countryName.contains(query);

        if (!cityMatched && !countryMatched) {
          continue;
        }

        matchedFiles.addAll(entry.value);
        matchedCities.add("${city.city}, ${city.country}");
      }

      matchesSummary[query] = {
        "matched_cities": matchedCities,
        "matched_city_count": matchedCities.length,
      };

      if (matchedCities.isEmpty) {
        warnings.add("No place matches found for '$query'");
      }
    }

    return _PlaceQueryResolutionResult(
      files: matchedFiles.toList(growable: false),
      matchesSummary: matchesSummary,
      warnings: warnings,
    );
  }

  Future<_SemanticResolutionResult> _resolveSemanticQuery(String query) async {
    final warnings = <String>[];
    try {
      final result =
          await SemanticSearchService.instance.searchScreenQuery(query);
      final files = result.$2;
      final uploadedIDs = filesToUploadedFileIDs(files);
      return _SemanticResolutionResult(
        uploadedIDs: uploadedIDs,
        warnings: warnings,
      );
    } catch (e, s) {
      _logger.warning("Semantic query failed", e, s);
      warnings.add("semantic_query execution failed: $e");
      return _SemanticResolutionResult(
        uploadedIDs: const <int>{},
        warnings: warnings,
      );
    }
  }

  _ContactResolutionResult _resolveContacts(
    List<String> requestedCanonicalContacts,
  ) {
    final warnings = <String>[];
    final relevantContacts = UserService.instance.getRelevantContacts();

    final canonicalToUser = <String, User>{};
    for (final user in relevantContacts) {
      final email = user.email.trim();
      if (email.isEmpty) {
        continue;
      }
      final displayName = user.displayName?.trim();
      final canonical = displayName != null && displayName.isNotEmpty
          ? "$displayName <$email>"
          : email;
      canonicalToUser[canonical.toLowerCase()] = user;
      canonicalToUser[email.toLowerCase()] = user;
    }

    if (requestedCanonicalContacts.isEmpty) {
      return _ContactResolutionResult(
        users: relevantContacts,
        warnings: warnings,
      );
    }

    final users = <User>[];
    for (final requested in requestedCanonicalContacts) {
      final resolved = canonicalToUser[requested.toLowerCase()];
      if (resolved == null) {
        warnings.add("No contact found for '$requested'");
        continue;
      }
      users.add(resolved);
    }

    return _ContactResolutionResult(users: users, warnings: warnings);
  }

  _NumericRangeResult _resolveNumericRange(Map<String, dynamic> value) {
    final warnings = <String>[];
    var min = _toInt(value["min"]);
    var max = _toInt(value["max"]);

    if (min == null && max == null) {
      return _NumericRangeResult(min: null, max: null, warnings: warnings);
    }

    if (min != null && min < 0) {
      warnings.add("Ignoring negative min value $min");
      min = null;
    }
    if (max != null && max < 0) {
      warnings.add("Ignoring negative max value $max");
      max = null;
    }

    if (min != null && max != null && min > max) {
      warnings.add("Range min was greater than max; swapping values");
      final temp = min;
      min = max;
      max = temp;
    }

    return _NumericRangeResult(min: min, max: max, warnings: warnings);
  }

  void _sortFilesChronologically(List<EnteFile> files) {
    files.sort(
      (first, second) =>
          (first.creationTime ?? 0).compareTo(second.creationTime ?? 0),
    );
  }

  static ParsedToolCall _parseToolCallMap(
    Map<String, dynamic> decoded,
    List<String> warnings,
  ) {
    if (decoded.containsKey("tool_calls")) {
      final toolCalls = decoded["tool_calls"];
      if (toolCalls is! List || toolCalls.length != 1) {
        throw const FormatException("Expected exactly one tool call");
      }
      final firstCall = toolCalls.first;
      if (firstCall is! Map<String, dynamic>) {
        throw const FormatException("tool_calls[0] must be a JSON object");
      }
      return _parseToolCallMap(firstCall, warnings);
    }

    if (decoded.containsKey("function")) {
      final function = decoded["function"];
      if (function is! Map<String, dynamic>) {
        throw const FormatException("function must be a JSON object");
      }
      final combined = <String, dynamic>{
        "name": function["name"],
        "arguments": function["arguments"],
      };
      return _parseToolCallMap(combined, warnings);
    }

    final name = decoded["name"];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException("Tool call must include a non-empty 'name'");
    }
    final trimmedName = name.trim();
    if (trimmedName != _toolName) {
      throw FormatException(
        "Unexpected tool call '$trimmedName'. Expected '$_toolName'",
      );
    }

    final arguments = decoded["arguments"];
    final parsedArguments = _parseToolCallArguments(arguments);

    return ParsedToolCall(
      name: trimmedName,
      arguments: parsedArguments,
      warnings: warnings,
      rawCallJson: decoded,
    );
  }

  static Map<String, dynamic> _parseToolCallArguments(dynamic arguments) {
    if (arguments == null) {
      return <String, dynamic>{};
    }

    if (arguments is Map<String, dynamic>) {
      return arguments;
    }

    if (arguments is String) {
      final trimmed = arguments.trim();
      if (trimmed.isEmpty) {
        return <String, dynamic>{};
      }
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      throw const FormatException(
        "Tool-call 'arguments' must decode to an object",
      );
    }

    throw FormatException(
      "Tool-call 'arguments' must be an object or JSON string. Got ${arguments.runtimeType}",
    );
  }

  static String _stripCodeFences(String output) {
    final trimmed = output.trim();
    if (!trimmed.startsWith("```") || !trimmed.endsWith("```")) {
      return trimmed;
    }

    var stripped = trimmed;
    stripped = stripped.replaceFirst(RegExp(r"^```[a-zA-Z0-9_-]*\\s*"), "");
    stripped = stripped.replaceFirst(RegExp(r"\\s*```$"), "");
    return stripped.trim();
  }

  static Iterable<String> _extractTaggedToolCallBlocks(String text) sync* {
    final regex = RegExp(r"<tool_call>([\s\S]*?)</tool_call>");
    for (final match in regex.allMatches(text)) {
      final group = match.group(1);
      if (group != null) {
        yield group;
      }
    }
  }

  static String? _extractFirstJsonObject(String input) {
    final text = input.trim();
    final startIndex = text.indexOf("{");
    if (startIndex < 0) {
      return null;
    }

    var depth = 0;
    var inString = false;
    var isEscaped = false;

    for (var i = startIndex; i < text.length; i++) {
      final char = text[i];

      if (isEscaped) {
        isEscaped = false;
        continue;
      }

      if (char == r"\\") {
        isEscaped = true;
        continue;
      }

      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (inString) {
        continue;
      }

      if (char == "{") {
        depth++;
      } else if (char == "}") {
        depth--;
        if (depth == 0) {
          return text.substring(startIndex, i + 1);
        }
      }
    }

    return null;
  }

  static DateTime? _tryParseLocalDateTime(String input) {
    try {
      return DateTime.parse(input);
    } catch (_) {
      return null;
    }
  }

  static int? _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  static bool _isValidGregorianDate({
    required int day,
    required int month,
    required int year,
  }) {
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      return false;
    }

    final candidate = DateTime(year, month, day);
    return candidate.year == year &&
        candidate.month == month &&
        candidate.day == day;
  }

  static List<String> _normalizeStringList(dynamic value) {
    if (value is! List) {
      return const [];
    }

    final seen = <String>{};
    final normalized = <String>[];

    for (final item in value) {
      if (item is! String) {
        continue;
      }
      final trimmed = item.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final normalizedKey = trimmed.toLowerCase();
      if (seen.contains(normalizedKey)) {
        continue;
      }
      seen.add(normalizedKey);
      normalized.add(trimmed);
    }

    return normalized;
  }
}

class NaturalSearchModelInput {
  final String userQuery;
  final String developerPrompt;
  final String toolSchemaRaw;
  final Map<String, dynamic> toolSchema;
  final Map<String, dynamic> dynamicContext;

  NaturalSearchModelInput({
    required this.userQuery,
    required this.developerPrompt,
    required this.toolSchemaRaw,
    required this.toolSchema,
    required this.dynamicContext,
  });
}

class NaturalSearchParsedToolCall {
  final String name;
  final Map<String, dynamic> arguments;
  final List<String> warnings;
  final Map<String, dynamic> rawCallJson;

  NaturalSearchParsedToolCall({
    required this.name,
    required this.arguments,
    required this.warnings,
    required this.rawCallJson,
  });
}

class ParsedToolCall {
  final String name;
  final Map<String, dynamic> arguments;
  final List<String> warnings;
  final Map<String, dynamic> rawCallJson;

  ParsedToolCall({
    required this.name,
    required this.arguments,
    required this.warnings,
    required this.rawCallJson,
  });
}

class NaturalSearchExecutionResult {
  final String originalQuery;
  final Map<String, dynamic> normalizedToolArguments;
  final Map<String, dynamic> resolvedArguments;
  final List<EnteFile> files;
  final List<String> warnings;
  final HierarchicalSearchFilter initialFilter;
  final String? rawFunctionGemmaToolCallOutput;
  final GenericSearchResult searchResult;

  NaturalSearchExecutionResult({
    required this.originalQuery,
    required this.normalizedToolArguments,
    required this.resolvedArguments,
    required this.files,
    required this.warnings,
    required this.initialFilter,
    this.rawFunctionGemmaToolCallOutput,
    required this.searchResult,
  });
}

class TimeRangeMicros {
  final int startMicroseconds;
  final int endMicrosecondsExclusive;

  const TimeRangeMicros({
    required this.startMicroseconds,
    required this.endMicrosecondsExclusive,
  });

  bool contains(int microsecondsSinceEpoch) {
    return microsecondsSinceEpoch >= startMicroseconds &&
        microsecondsSinceEpoch < endMicrosecondsExclusive;
  }
}

class _NormalizationResult {
  final Map<String, dynamic> arguments;
  final List<String> warnings;

  _NormalizationResult({
    required this.arguments,
    required this.warnings,
  });
}

class _OwnershipFilterResult {
  final List<EnteFile> files;
  final Map<String, dynamic> resolvedArguments;
  final List<String> warnings;

  _OwnershipFilterResult({
    required this.files,
    required this.resolvedArguments,
    required this.warnings,
  });
}

class _EntityIDResolutionResult {
  final Set<int> collectionIds;
  final List<String> warnings;

  _EntityIDResolutionResult({
    required this.collectionIds,
    required this.warnings,
  });
}

class _DeviceAlbumResolutionResult {
  final Set<String> localIDs;
  final Set<String> pathIDs;
  final List<String> warnings;

  _DeviceAlbumResolutionResult({
    required this.localIDs,
    required this.pathIDs,
    required this.warnings,
  });
}

class _PersonResolutionResult {
  final Set<int> uploadedIDs;
  final List<String> personIDs;
  final List<String> warnings;

  _PersonResolutionResult({
    required this.uploadedIDs,
    required this.personIDs,
    required this.warnings,
  });
}

class _LocationTagResolutionResult {
  final List<LocationTag> tags;
  final List<String> warnings;

  _LocationTagResolutionResult({
    required this.tags,
    required this.warnings,
  });
}

class _PlaceQueryResolutionResult {
  final List<EnteFile> files;
  final Map<String, dynamic> matchesSummary;
  final List<String> warnings;

  _PlaceQueryResolutionResult({
    required this.files,
    required this.matchesSummary,
    required this.warnings,
  });
}

class _SemanticResolutionResult {
  final Set<int> uploadedIDs;
  final List<String> warnings;

  _SemanticResolutionResult({
    required this.uploadedIDs,
    required this.warnings,
  });
}

class _ContactResolutionResult {
  final List<User> users;
  final List<String> warnings;

  _ContactResolutionResult({
    required this.users,
    required this.warnings,
  });
}

class _NumericRangeResult {
  final int? min;
  final int? max;
  final List<String> warnings;

  _NumericRangeResult({
    required this.min,
    required this.max,
    required this.warnings,
  });

  bool get isValid => min != null || max != null;

  bool contains(int value) {
    if (min != null && value < min!) {
      return false;
    }
    if (max != null && value > max!) {
      return false;
    }
    return true;
  }

  Map<String, int> toJson() {
    return {
      if (min != null) "min": min!,
      if (max != null) "max": max!,
    };
  }
}
