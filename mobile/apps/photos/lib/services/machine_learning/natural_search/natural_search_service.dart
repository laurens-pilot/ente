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

enum NaturalSearchContextEntityKind {
  album,
  deviceAlbum,
  person,
  locationTag,
  contact,
}

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
  static const Set<String> _supportedToolNames = {
    _toolName,
  };

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
  static const Set<String> _schemaLeakageArgumentFields = {
    "additionalProperties",
    "properties",
    "required",
    "description",
    "type",
    "items",
    "enum",
    "minimum",
    "maximum",
    "pattern",
    "minItems",
    "uniqueItems",
  };
  static const Set<String> _listArgumentFields = {
    "album_names",
    "shared_by_contacts",
    "people_in_media",
    "place_names",
    "ente_album_names",
    "device_album_names",
    "file_types",
    "contact_names",
    "person_names",
    "location_tag_names",
    "place_queries",
  };
  static const Set<String> _objectArgumentFields = {
    "time_filter",
    "video_duration_seconds",
    "file_size_mb",
  };

  static const Set<String> _allowedArgumentFields = {
    "time_query",
    "time_filter",
    "album_names",
    "media_type",
    "text_query",
    "camera_query",
    "ownership_scope",
    "shared_by_contacts",
    "people_in_media",
    "people_mode",
    "place_names",
    "visual_query",
    "file_format",
    "video_duration_query",
    "file_size_query",
    "video_duration_seconds",
    "file_size_mb",
    "limit",
    "ente_album_names",
    "device_album_names",
    "file_types",
    "filename_query",
    "caption_query",
    "camera_make_query",
    "camera_model_query",
    "contact_names",
    "person_names",
    "person_operator",
    "location_tag_names",
    "place_queries",
    "semantic_query",
  };
  static const Set<String> _mediaTypes = {
    "photo",
    "video",
  };
  static const Set<String> _reservedPeopleValues = {
    "all",
    "any",
    "me",
    "my",
    "mine",
    "person",
    "people",
    "someone",
  };
  static const Set<String> _queryStopWords = {
    "a",
    "an",
    "all",
    "any",
    "at",
    "by",
    "day",
    "days",
    "find",
    "for",
    "from",
    "give",
    "image",
    "images",
    "in",
    "last",
    "me",
    "month",
    "months",
    "movie",
    "movies",
    "my",
    "of",
    "on",
    "or",
    "past",
    "photo",
    "photos",
    "picture",
    "pictures",
    "search",
    "show",
    "the",
    "this",
    "to",
    "video",
    "videos",
    "week",
    "weeks",
    "with",
    "year",
    "years",
  };
  static const Set<String> _albumIntentTokens = {
    "album",
    "albums",
    "collection",
    "collections",
    "folder",
    "folders",
  };
  static const Set<String> _sharingIntentTokens = {
    "receive",
    "received",
    "sent",
    "share",
    "shared",
    "shares",
    "sharing",
  };
  static const Map<String, int> _monthNameToNumber = {
    "january": 1,
    "jan": 1,
    "february": 2,
    "feb": 2,
    "march": 3,
    "mar": 3,
    "april": 4,
    "apr": 4,
    "may": 5,
    "june": 6,
    "jun": 6,
    "july": 7,
    "jul": 7,
    "august": 8,
    "aug": 8,
    "september": 9,
    "sep": 9,
    "sept": 9,
    "october": 10,
    "oct": 10,
    "november": 11,
    "nov": 11,
    "december": 12,
    "dec": 12,
  };
  static const Map<String, int> _numberWordToInt = {
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "eleven": 11,
    "twelve": 12,
  };
  static final RegExp _nonAlphaNumericPattern = RegExp(r"[^a-z0-9]+");
  static final RegExp _whitespacePattern = RegExp(r"\s+");

  final _logger = Logger("NaturalSearchService");
  Future<NaturalSearchExecutionResult>? _searchScreenRequest;
  String? _latestPendingQuery;

  String? _cachedToolSchemaRaw;
  Map<String, dynamic>? _cachedToolSchema;
  String? _cachedDeveloperPrompt;
  Map<String, dynamic>? _cachedExampleContext;

  Future<NaturalSearchModelInput> buildModelInput(String userQuery) async {
    final normalizedQuery = userQuery.trim();
    final toolSchema = await _loadToolSchema();
    final developerPromptBase = await _loadDeveloperPrompt();
    final dynamicContext = await _buildDynamicPromptContext(normalizedQuery);
    final promptContextJson = jsonEncode(dynamicContext);

    final developerPrompt =
        "$developerPromptBase\nRuntime context JSON:$promptContextJson";

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
    final validationIssues = detectCorruptedToolCallIssues(
      parsed.arguments,
      normalizedArguments.arguments,
    );

    return NaturalSearchParsedToolCall(
      name: parsed.name,
      arguments: normalizedArguments.arguments,
      warnings: [
        ...parsed.warnings,
        ...normalizedArguments.warnings,
        ...validationIssues.map((issue) => "Tool call validation: $issue"),
      ],
      validationIssues: validationIssues,
      rawCallJson: parsed.rawCallJson,
    );
  }

  Future<NaturalSearchExecutionResult> executeParsedCall({
    required String originalQuery,
    required NaturalSearchParsedToolCall parsedToolCall,
    String? functionGemmaPrompt,
    String? rawFunctionGemmaToolCallOutput,
  }) {
    return executeToolArguments(
      originalQuery: originalQuery,
      toolArguments: parsedToolCall.arguments,
      parserWarnings: parsedToolCall.warnings,
      functionGemmaPrompt: functionGemmaPrompt,
      rawFunctionGemmaToolCallOutput: rawFunctionGemmaToolCallOutput,
    );
  }

  Future<NaturalSearchExecutionResult> executeToolArguments({
    required String originalQuery,
    required Map<String, dynamic> toolArguments,
    List<String> parserWarnings = const [],
    String? functionGemmaPrompt,
    String? rawFunctionGemmaToolCallOutput,
  }) async {
    final normalizationResult = _normalizeArguments(toolArguments);
    var normalizedArguments = normalizationResult.arguments;
    final warnings = <String>[
      ...parserWarnings,
      ...normalizationResult.warnings,
    ];

    final pruningResult = await _pruneArgumentsForExecution(
      originalQuery: originalQuery,
      normalizedArguments: normalizedArguments,
    );
    normalizedArguments = pruningResult.arguments;
    warnings.addAll(pruningResult.warnings);

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

    final timeRanges = normalizedArguments.containsKey("time_query")
        ? resolveTimeQueryToRanges(
            normalizedArguments["time_query"] as String,
            searchStartYearOverride: searchStartYear,
            nowOverride: DateTime.now(),
          )
        : normalizedArguments.containsKey("time_filter")
            ? resolveTimeFilterToRanges(
                normalizedArguments["time_filter"] as Map<String, dynamic>,
                searchStartYearOverride: searchStartYear,
                nowOverride: DateTime.now(),
              )
            : const <TimeRangeMicros>[];
    if (normalizedArguments.containsKey("time_query") ||
        normalizedArguments.containsKey("time_filter")) {
      if (timeRanges.isEmpty) {
        warnings.add("time query resolved to 0 ranges; skipping time filter");
      } else {
        resolvedArguments["time_ranges_micros"] = timeRanges
            .map(
              (range) => {
                "start_microseconds": range.startMicroseconds,
                "end_microseconds_exclusive": range.endMicrosecondsExclusive,
              },
            )
            .toList(growable: false);
        if (normalizedArguments["time_query"] case final String timeQuery) {
          resolvedArguments["time_query"] = timeQuery;
        }
        workingFiles = workingFiles.where((file) {
          final createdAt = file.creationTime;
          if (createdAt == null) {
            return false;
          }
          for (final range in timeRanges) {
            if (range.contains(createdAt)) {
              return true;
            }
          }
          return false;
        }).toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("album_names")) {
      final requestedNames = normalizedArguments["album_names"] as List<String>;
      final resolution = await _resolveAlbumNames(requestedNames);
      warnings.addAll(resolution.warnings);
      resolvedArguments["album_names_resolved"] = {
        "album_names": requestedNames,
        "ente_album_collection_ids":
            resolution.collectionIds.toList(growable: false),
        "device_album_path_ids": resolution.pathIDs.toList(growable: false),
      };

      if (resolution.collectionIds.isEmpty && resolution.localIDs.isEmpty) {
        workingFiles = [];
      } else {
        workingFiles = workingFiles.where((file) {
          final collectionMatch = file.collectionID != null &&
              resolution.collectionIds.contains(file.collectionID);
          final deviceMatch = file.localID != null &&
              resolution.localIDs.contains(file.localID);
          return collectionMatch || deviceMatch;
        }).toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("media_type")) {
      final fileTypes = _resolveMediaType(
        normalizedArguments["media_type"] as String,
      );
      if (fileTypes.isEmpty) {
        warnings.add("No valid file types resolved from media_type");
        workingFiles = [];
      } else {
        resolvedArguments["file_types"] =
            fileTypes.map((fileType) => fileType.name).toList(growable: false);
        workingFiles = workingFiles
            .where((file) => fileTypes.contains(file.fileType))
            .toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("text_query")) {
      final query = normalizedArguments["text_query"] as String;
      final normalizedQuery = query.toLowerCase();
      workingFiles = workingFiles.where((file) {
        final filenameMatched =
            file.displayName.toLowerCase().contains(normalizedQuery);
        final caption = file.caption;
        final captionMatched =
            caption != null && caption.toLowerCase().contains(normalizedQuery);
        return filenameMatched || captionMatched;
      }).toList(growable: false);
    }

    if (normalizedArguments.containsKey("camera_query")) {
      final query = normalizedArguments["camera_query"] as String;
      final normalizedQuery = query.toLowerCase();
      workingFiles = workingFiles.where((file) {
        final make = file.cameraMake;
        final model = file.cameraModel;
        final makeMatched =
            make != null && make.toLowerCase().contains(normalizedQuery);
        final modelMatched =
            model != null && model.toLowerCase().contains(normalizedQuery);
        return makeMatched || modelMatched;
      }).toList(growable: false);
    }

    if (normalizedArguments.containsKey("people_in_media")) {
      final requestedNames =
          normalizedArguments["people_in_media"] as List<String>;
      final peopleMode =
          (normalizedArguments["people_mode"] as String?) ?? "any";
      final resolution = await _resolvePersonUploadedIDs(
        requestedNames,
        peopleMode,
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

    if (normalizedArguments.containsKey("place_names")) {
      final placeNames = normalizedArguments["place_names"] as List<String>;
      final resolution = await _resolveFilesForPlaceNames(
        files: workingFiles,
        placeNames: placeNames,
      );
      warnings.addAll(resolution.warnings);
      resolvedArguments["place_names_resolved"] = resolution.matchesSummary;
      if (resolution.files.isEmpty) {
        workingFiles = [];
      } else {
        final matched = resolution.files.toSet();
        workingFiles = workingFiles
            .where((file) => matched.contains(file))
            .toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("visual_query")) {
      final visualQuery = normalizedArguments["visual_query"] as String;
      final semanticResult = await _resolveSemanticQuery(visualQuery);
      warnings.addAll(semanticResult.warnings);
      resolvedArguments["visual_query_resolved"] = {
        "query": visualQuery,
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

    if (normalizedArguments.containsKey("file_format")) {
      final fileFormatQuery = normalizedArguments["file_format"] as String;
      final acceptedFormats = _resolveFileFormatAliases(fileFormatQuery);
      if (acceptedFormats.isEmpty) {
        warnings.add("No valid file formats resolved from file_format");
        workingFiles = [];
      } else {
        resolvedArguments["file_formats"] = acceptedFormats.toList(
          growable: false,
        );
        workingFiles = workingFiles.where((file) {
          final fileFormat = getExtension(file.displayName);
          return acceptedFormats.contains(fileFormat);
        }).toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("video_duration_query") ||
        normalizedArguments.containsKey("video_duration_seconds")) {
      final range = normalizedArguments.containsKey("video_duration_query")
          ? _resolveVideoDurationQuery(
              normalizedArguments["video_duration_query"] as String,
            )
          : _resolveNumericRange(
              normalizedArguments["video_duration_seconds"]
                  as Map<String, dynamic>,
            );
      warnings.addAll(range.warnings);
      if (!range.isValid) {
        workingFiles = [];
      } else {
        if (normalizedArguments["video_duration_query"]
            case final String query) {
          resolvedArguments["video_duration_query"] = query;
        }
        resolvedArguments["video_duration_seconds"] = range.toJson();
        workingFiles = workingFiles.where((file) {
          if (!file.isVideo || file.duration == null) {
            return false;
          }
          return range.contains(file.duration!);
        }).toList(growable: false);
      }
    }

    if (normalizedArguments.containsKey("file_size_query") ||
        normalizedArguments.containsKey("file_size_mb")) {
      final range = normalizedArguments.containsKey("file_size_query")
          ? _resolveFileSizeQuery(
              normalizedArguments["file_size_query"] as String,
            )
          : _resolveNumericRange(
              normalizedArguments["file_size_mb"] as Map<String, dynamic>,
            ).scale(1024 * 1024);
      warnings.addAll(range.warnings);
      if (!range.isValid) {
        workingFiles = [];
      } else {
        if (normalizedArguments["file_size_query"] case final String query) {
          resolvedArguments["file_size_query"] = query;
        }
        final minBytes = range.min;
        final maxBytes = range.max;
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
      if (functionGemmaPrompt != null)
        kFunctionGemmaPrompt: functionGemmaPrompt,
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
      functionGemmaPrompt: functionGemmaPrompt,
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
    final normalizedQuery = userQuery.trim();
    if (_searchScreenRequest != null) {
      _latestPendingQuery = normalizedQuery;
      return _searchScreenRequest!;
    }

    _searchScreenRequest = _runNaturalSearchQueryWithCoalescing(
      normalizedQuery,
    );

    return _searchScreenRequest!;
  }

  Future<NaturalSearchExecutionResult> _runNaturalSearchQueryWithCoalescing(
    String normalizedQuery,
  ) async {
    try {
      final result = await _runNaturalSearchQueryInternal(normalizedQuery);
      _searchScreenRequest = null;

      final latestPendingQuery = _latestPendingQuery;
      _latestPendingQuery = null;
      if (latestPendingQuery != null && latestPendingQuery != normalizedQuery) {
        return runNaturalSearchQuery(latestPendingQuery);
      }

      return result;
    } catch (e) {
      _searchScreenRequest = null;
      _latestPendingQuery = null;
      rethrow;
    }
  }

  Future<NaturalSearchExecutionResult> _runNaturalSearchQueryInternal(
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
    if (parsedToolCall.validationIssues.isNotEmpty) {
      final validationMessage = parsedToolCall.validationIssues.join("; ");
      if (kDebugMode) {
        _logger.warning(
          "FunctionGemma tool call failed validation for '${modelInput.userQuery}', continuing in debug mode: $validationMessage",
        );
      } else {
        throw FormatException(
          "FunctionGemma produced an invalid tool call: $validationMessage",
        );
      }
    }
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
      functionGemmaPrompt: inferenceResult.prompt,
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
  static List<String> detectCorruptedToolCallIssues(
    Map<String, dynamic> rawArguments,
    Map<String, dynamic> normalizedArguments,
  ) {
    final issues = <String>{};

    _collectSchemaLeakageIssues(
      rawArguments,
      path: "arguments",
      issues: issues,
    );

    if (rawArguments.containsKey("kind")) {
      issues.add(
        "Unexpected top-level 'kind' in arguments; expected time_filter.kind",
      );
    }

    for (final entry in rawArguments.entries) {
      final key = entry.key;
      final value = entry.value;
      if (_listArgumentFields.contains(key) && value is! List) {
        issues.add("Field '$key' must be an array, got ${value.runtimeType}");
      }
      if (_objectArgumentFields.contains(key) &&
          value is! Map<String, dynamic>) {
        issues.add("Field '$key' must be an object, got ${value.runtimeType}");
      }
    }

    if (rawArguments.isNotEmpty && normalizedArguments.isEmpty) {
      issues.add("No valid executable arguments remained after normalization");
    }

    return issues.toList(growable: false);
  }

  static void _collectSchemaLeakageIssues(
    dynamic value, {
    required String path,
    required Set<String> issues,
  }) {
    if (value is Map<String, dynamic>) {
      for (final entry in value.entries) {
        final key = entry.key;
        final nextPath = "$path.$key";
        if (_schemaLeakageArgumentFields.contains(key)) {
          issues.add("Unexpected schema keyword '$nextPath' in arguments");
        }
        _collectSchemaLeakageIssues(
          entry.value,
          path: nextPath,
          issues: issues,
        );
      }
      return;
    }

    if (value is List) {
      for (var index = 0; index < value.length; index++) {
        _collectSchemaLeakageIssues(
          value[index],
          path: "$path[$index]",
          issues: issues,
        );
      }
    }
  }

  @visibleForTesting
  static List<TimeRangeMicros> resolveTimeQueryToRanges(
    String timeQuery, {
    required int searchStartYearOverride,
    required DateTime nowOverride,
  }) {
    final normalized = _normalizeContextText(timeQuery);
    if (normalized.isEmpty) {
      return const [];
    }

    final startOfToday = DateTime(
      nowOverride.year,
      nowOverride.month,
      nowOverride.day,
    );
    if (normalized == "today") {
      return [_buildDayRange(startOfToday)];
    }
    if (normalized == "yesterday") {
      return [_buildDayRange(startOfToday.subtract(const Duration(days: 1)))];
    }
    if (normalized == "this week") {
      final start = _startOfWeekMonday(startOfToday);
      return [_buildRange(start, start.add(const Duration(days: 7)))];
    }
    if (normalized == "last week") {
      final start = _startOfWeekMonday(startOfToday).subtract(
        const Duration(days: 7),
      );
      return [_buildRange(start, start.add(const Duration(days: 7)))];
    }
    if (normalized == "this month") {
      final start = DateTime(nowOverride.year, nowOverride.month, 1);
      return [_buildRange(start, _addMonths(start, 1))];
    }
    if (normalized == "last month") {
      final start = DateTime(nowOverride.year, nowOverride.month - 1, 1);
      return [
        _buildRange(start, DateTime(nowOverride.year, nowOverride.month, 1)),
      ];
    }
    if (normalized == "this year") {
      final start = DateTime(nowOverride.year, 1, 1);
      return [_buildRange(start, DateTime(nowOverride.year + 1, 1, 1))];
    }
    if (normalized == "last year") {
      final start = DateTime(nowOverride.year - 1, 1, 1);
      return [_buildRange(start, DateTime(nowOverride.year, 1, 1))];
    }

    final rollingWindowMatch = RegExp(
      r"^(?:past|last) (\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve) (day|days|week|weeks|month|months|year|years)$",
    ).firstMatch(normalized);
    if (rollingWindowMatch != null) {
      final amount = _parseIntOrWord(rollingWindowMatch.group(1));
      final unit = rollingWindowMatch.group(2);
      if (amount != null && unit != null) {
        final start = _subtractCalendarUnit(nowOverride, amount, unit);
        return [_buildRange(start, nowOverride)];
      }
    }

    final yearsAgoMatch = RegExp(
      r"^(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve) years ago$",
    ).firstMatch(normalized);
    if (yearsAgoMatch != null) {
      final yearsAgo = _parseIntOrWord(yearsAgoMatch.group(1));
      if (yearsAgo != null && yearsAgo > 0) {
        final year = nowOverride.year - yearsAgo;
        return [
          _buildRange(DateTime(year, 1, 1), DateTime(year + 1, 1, 1)),
        ];
      }
    }

    final explicitRange = _tryParseExplicitDateRange(normalized);
    if (explicitRange != null) {
      return [explicitRange];
    }

    final calendarMonthMatch = RegExp(
      r"^(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|sept|october|oct|november|nov|december|dec) (\d{4})$",
    ).firstMatch(normalized);
    if (calendarMonthMatch != null) {
      final month = _monthNameToNumber[calendarMonthMatch.group(1)!];
      final year = int.tryParse(calendarMonthMatch.group(2)!);
      if (month != null && year != null) {
        final start = DateTime(year, month, 1);
        return [_buildRange(start, _addMonths(start, 1))];
      }
    }

    final calendarYearMatch = RegExp(r"^(\d{4})$").firstMatch(normalized);
    if (calendarYearMatch != null) {
      final year = int.tryParse(calendarYearMatch.group(1)!);
      if (year != null) {
        return [_buildRange(DateTime(year, 1, 1), DateTime(year + 1, 1, 1))];
      }
    }

    final specificDate = _tryParseLooseDate(normalized);
    if (specificDate != null) {
      return [_buildDayRange(specificDate.toDateTime())];
    }

    final recurringMonthMatch = RegExp(
      r"^every (january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|sept|october|oct|november|nov|december|dec)$",
    ).firstMatch(normalized);
    if (recurringMonthMatch != null) {
      final month = _monthNameToNumber[recurringMonthMatch.group(1)!];
      if (month != null) {
        return _buildRecurringMonthRanges(
          month: month,
          currentYear: nowOverride.year,
          searchStartYear: searchStartYearOverride,
        );
      }
    }

    final recurringDayMonth = _tryParseLooseDate(
      normalized,
      defaultYear: nowOverride.year,
    );
    if (recurringDayMonth != null &&
        !RegExp(r"\d{4}").hasMatch(normalized) &&
        _monthNameToNumber.keys.any(normalized.contains)) {
      final ranges = <TimeRangeMicros>[];
      for (var year = searchStartYearOverride;
          year <= nowOverride.year;
          year++) {
        if (!_isValidGregorianDate(
          day: recurringDayMonth.day,
          month: recurringDayMonth.month,
          year: year,
        )) {
          continue;
        }
        ranges.add(
          _buildDayRange(
            DateTime(year, recurringDayMonth.month, recurringDayMonth.day),
          ),
        );
      }
      return ranges;
    }

    return const [];
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

  static TimeRangeMicros _buildRange(DateTime start, DateTime endExclusive) {
    return TimeRangeMicros(
      startMicroseconds: start.microsecondsSinceEpoch,
      endMicrosecondsExclusive: endExclusive.microsecondsSinceEpoch,
    );
  }

  static TimeRangeMicros _buildDayRange(DateTime dayStart) {
    return _buildRange(dayStart, dayStart.add(const Duration(days: 1)));
  }

  static DateTime _startOfWeekMonday(DateTime value) {
    return value.subtract(Duration(days: value.weekday - DateTime.monday));
  }

  static DateTime _addMonths(DateTime value, int monthDelta) {
    final targetMonthIndex = value.month + monthDelta;
    final year = value.year + ((targetMonthIndex - 1) ~/ 12);
    final month = ((targetMonthIndex - 1) % 12) + 1;
    final day = value.day.clamp(1, _daysInMonth(year, month));
    return DateTime(
      year,
      month,
      day,
      value.hour,
      value.minute,
      value.second,
    );
  }

  static int _daysInMonth(int year, int month) {
    return DateTime(year, month + 1, 0).day;
  }

  static DateTime _subtractCalendarUnit(
    DateTime value,
    int amount,
    String unit,
  ) {
    switch (unit) {
      case "day":
      case "days":
        return value.subtract(Duration(days: amount));
      case "week":
      case "weeks":
        return value.subtract(Duration(days: amount * 7));
      case "month":
      case "months":
        return _addMonths(value, -amount);
      case "year":
      case "years":
        return DateTime(
          value.year - amount,
          value.month,
          value.day.clamp(1, _daysInMonth(value.year - amount, value.month)),
          value.hour,
          value.minute,
          value.second,
        );
    }
    return value;
  }

  static int? _parseIntOrWord(String? input) {
    if (input == null || input.isEmpty) {
      return null;
    }
    return int.tryParse(input) ?? _numberWordToInt[input];
  }

  static TimeRangeMicros? _tryParseExplicitDateRange(String normalizedQuery) {
    final query = normalizedQuery.startsWith("from ")
        ? normalizedQuery.substring(5)
        : normalizedQuery;
    for (final separator in const [" till ", " to ", " until ", " through "]) {
      final separatorIndex = query.indexOf(separator);
      if (separatorIndex == -1) {
        continue;
      }

      final left = query.substring(0, separatorIndex).trim();
      final right = query.substring(separatorIndex + separator.length).trim();
      var rightDate = _tryParseLooseDate(right);
      var leftDate = _tryParseLooseDate(
        left,
        defaultYear: rightDate?.year,
        defaultMonth: rightDate?.month,
      );
      rightDate ??= _tryParseLooseDate(
        right,
        defaultYear: leftDate?.year,
        defaultMonth: leftDate?.month,
      );
      leftDate ??= _tryParseLooseDate(
        left,
        defaultYear: rightDate?.year,
        defaultMonth: rightDate?.month,
      );

      if (leftDate == null || rightDate == null) {
        continue;
      }

      final start = leftDate.toDateTime();
      final endExclusive = rightDate.toDateTime().add(const Duration(days: 1));
      if (!endExclusive.isAfter(start)) {
        continue;
      }
      return _buildRange(start, endExclusive);
    }
    return null;
  }

  static _ResolvedCalendarDate? _tryParseLooseDate(
    String input, {
    int? defaultYear,
    int? defaultMonth,
  }) {
    final normalized = _normalizeContextText(input).replaceAll(" of ", " ");
    final dayMonthYearMatch = RegExp(
      r"^(\d{1,2}) (january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|sept|october|oct|november|nov|december|dec)(?: (\d{4}))?$",
    ).firstMatch(normalized);
    if (dayMonthYearMatch != null) {
      final day = int.tryParse(dayMonthYearMatch.group(1)!);
      final month = _monthNameToNumber[dayMonthYearMatch.group(2)!];
      final year =
          int.tryParse(dayMonthYearMatch.group(3) ?? "") ?? defaultYear;
      if (day != null &&
          month != null &&
          year != null &&
          _isValidGregorianDate(day: day, month: month, year: year)) {
        return _ResolvedCalendarDate(year: year, month: month, day: day);
      }
    }

    final monthDayYearMatch = RegExp(
      r"^(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|sept|october|oct|november|nov|december|dec) (\d{1,2})(?: (\d{4}))?$",
    ).firstMatch(normalized);
    if (monthDayYearMatch != null) {
      final month = _monthNameToNumber[monthDayYearMatch.group(1)!];
      final day = int.tryParse(monthDayYearMatch.group(2)!);
      final year =
          int.tryParse(monthDayYearMatch.group(3) ?? "") ?? defaultYear;
      if (day != null &&
          month != null &&
          year != null &&
          _isValidGregorianDate(day: day, month: month, year: year)) {
        return _ResolvedCalendarDate(year: year, month: month, day: day);
      }
    }

    final dayYearMatch =
        RegExp(r"^(\d{1,2})(?: (\d{4}))?$").firstMatch(normalized);
    if (dayYearMatch != null && defaultMonth != null) {
      final day = int.tryParse(dayYearMatch.group(1)!);
      final year = int.tryParse(dayYearMatch.group(2) ?? "") ?? defaultYear;
      if (day != null &&
          year != null &&
          _isValidGregorianDate(day: day, month: defaultMonth, year: year)) {
        return _ResolvedCalendarDate(
          year: year,
          month: defaultMonth,
          day: day,
        );
      }
    }

    return null;
  }

  static List<TimeRangeMicros> _buildRecurringMonthRanges({
    required int month,
    required int currentYear,
    required int searchStartYear,
  }) {
    final ranges = <TimeRangeMicros>[];
    for (var year = searchStartYear; year <= currentYear; year++) {
      final start = DateTime(year, month, 1);
      ranges.add(_buildRange(start, _addMonths(start, 1)));
    }
    return ranges;
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
    _cachedToolSchemaRaw = jsonEncode(decoded);
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

  Future<Map<String, dynamic>> _buildDynamicPromptContext(
    String userQuery,
  ) async {
    final context = await _loadExamplePromptContext();
    context.remove("available_album_names");
    context.remove("available_people_in_media");
    context.remove("available_location_tag_names");
    context.remove("available_shared_by_contacts");

    context["current_local_datetime"] = _formatLocalDateTime(DateTime.now());
    context["local_timezone"] = await _resolveLocalTimezone();
    context["week_start"] = "monday";
    context["search_start_year"] = searchStartYear;
    context["result_ordering"] = "chronological";

    final albumNames = selectRelevantContextCandidates(
      userQuery: userQuery,
      candidates: await _getCanonicalAlbumNames(),
      entityKind: NaturalSearchContextEntityKind.album,
      maxResults: 10,
    );
    if (albumNames.isNotEmpty) {
      context["available_album_names"] = albumNames;
    }

    final personNames = selectRelevantContextCandidates(
      userQuery: userQuery,
      candidates: await _getCanonicalPersonNames(),
      entityKind: NaturalSearchContextEntityKind.person,
      maxResults: 8,
    );
    if (personNames.isNotEmpty) {
      context["available_people_in_media"] = personNames;
    }

    final locationTagNames = selectRelevantContextCandidates(
      userQuery: userQuery,
      candidates: await _getCanonicalLocationTagNames(),
      entityKind: NaturalSearchContextEntityKind.locationTag,
      maxResults: 8,
    );
    if (locationTagNames.isNotEmpty) {
      context["available_location_tag_names"] = locationTagNames;
    }

    final contactNames = selectRelevantContextCandidates(
      userQuery: userQuery,
      candidates: _getCanonicalContactNames(),
      entityKind: NaturalSearchContextEntityKind.contact,
      maxResults: 6,
    );
    if (contactNames.isNotEmpty) {
      context["available_shared_by_contacts"] = contactNames;
    }

    return context;
  }

  Future<SplayTreeSet<String>> _getCanonicalAlbumNames() async {
    final names = _getCanonicalEnteAlbumNames();
    names.addAll(await _getCanonicalDeviceAlbumNames());
    return names;
  }

  @visibleForTesting
  static List<String> selectRelevantContextCandidates({
    required String userQuery,
    required Iterable<String> candidates,
    required NaturalSearchContextEntityKind entityKind,
    int maxResults = 12,
  }) {
    final normalizedQuery = _normalizeContextText(userQuery);
    if (normalizedQuery.isEmpty) {
      return const [];
    }

    final queryTokens =
        _extractMeaningfulContextTokens(normalizedQuery).toSet();
    final hasAlbumIntent = queryTokens.any(_albumIntentTokens.contains);
    final hasSharingIntent = queryTokens.any(_sharingIntentTokens.contains) ||
        normalizedQuery.contains("shared by") ||
        normalizedQuery.contains("shared with");
    final scoredCandidates = <_ScoredContextCandidate>[];

    for (final candidate in candidates) {
      final normalizedCandidate = _normalizeContextText(candidate);
      if (normalizedCandidate.isEmpty) {
        continue;
      }

      if (_shouldSkipContextCandidate(
        entityKind: entityKind,
        normalizedQuery: normalizedQuery,
        normalizedCandidate: normalizedCandidate,
      )) {
        continue;
      }

      final candidateTokens = _extractMeaningfulContextTokens(
        normalizedCandidate,
      ).toSet();
      final hasExactPhraseMatch = _containsWholePhrase(
        normalizedQuery,
        normalizedCandidate,
      );
      final matchedTokenCount =
          candidateTokens.intersection(queryTokens).length;

      switch (entityKind) {
        case NaturalSearchContextEntityKind.album:
        case NaturalSearchContextEntityKind.deviceAlbum:
          final hasDistinctivePhraseMatch = hasExactPhraseMatch &&
              (candidateTokens.length > 1 ||
                  _isDistinctiveContextCandidate(normalizedCandidate));
          if (!hasAlbumIntent && !hasDistinctivePhraseMatch) {
            continue;
          }
          if (!hasDistinctivePhraseMatch && matchedTokenCount == 0) {
            continue;
          }
          break;
        case NaturalSearchContextEntityKind.contact:
          if (!hasSharingIntent && !hasExactPhraseMatch) {
            continue;
          }
          if (!hasExactPhraseMatch && matchedTokenCount == 0) {
            continue;
          }
          break;
        case NaturalSearchContextEntityKind.person:
        case NaturalSearchContextEntityKind.locationTag:
          if (!hasExactPhraseMatch && matchedTokenCount == 0) {
            continue;
          }
          break;
      }

      final score = (hasExactPhraseMatch ? 100 : 0) +
          (matchedTokenCount * 10) +
          (candidateTokens.length > 1 ? 2 : 0);
      scoredCandidates.add(
        _ScoredContextCandidate(candidate: candidate, score: score),
      );
    }

    scoredCandidates.sort((a, b) {
      final scoreComparison = b.score.compareTo(a.score);
      if (scoreComparison != 0) {
        return scoreComparison;
      }
      return a.candidate.toLowerCase().compareTo(b.candidate.toLowerCase());
    });

    final selected = <String>{};
    final results = <String>[];
    for (final candidate in scoredCandidates) {
      if (selected.add(candidate.candidate)) {
        results.add(candidate.candidate);
      }
      if (results.length >= maxResults) {
        break;
      }
    }

    return results;
  }

  static bool _shouldSkipContextCandidate({
    required NaturalSearchContextEntityKind entityKind,
    required String normalizedQuery,
    required String normalizedCandidate,
  }) {
    final isAlbumKind = entityKind == NaturalSearchContextEntityKind.album ||
        entityKind == NaturalSearchContextEntityKind.deviceAlbum;
    if (!isAlbumKind) {
      return false;
    }

    return normalizedCandidate == "camera" &&
        (normalizedQuery.contains("camera make") ||
            normalizedQuery.contains("camera model"));
  }

  static bool _isDistinctiveContextCandidate(String normalizedCandidate) {
    if (normalizedCandidate.contains(RegExp(r"[0-9]"))) {
      return true;
    }
    return normalizedCandidate.contains(" ");
  }

  static bool _containsWholePhrase(String text, String phrase) {
    return " $text ".contains(" $phrase ");
  }

  static String _normalizeContextText(String input) {
    return input
        .toLowerCase()
        .replaceAll(_nonAlphaNumericPattern, " ")
        .replaceAll(_whitespacePattern, " ")
        .trim();
  }

  static String _normalizeNumericQueryText(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9.\s-]"), " ")
        .replaceAll(_whitespacePattern, " ")
        .trim();
  }

  static List<String> _extractMeaningfulContextTokens(String input) {
    return input
        .split(" ")
        .map((token) => token.trim())
        .where(
          (token) => token.length >= 2 && !_queryStopWords.contains(token),
        )
        .toList(growable: false);
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
        case "time_query":
          if (value is String && value.trim().isNotEmpty) {
            normalized["time_query"] = value.trim();
          }
          break;
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
        case "album_names":
        case "ente_album_names":
        case "device_album_names":
          final albumNames = _normalizeStringList(value);
          if (albumNames.isNotEmpty) {
            _mergeStringListArgument(normalized, "album_names", albumNames);
          }
          break;
        case "shared_by_contacts":
        case "contact_names":
          final contacts = _normalizeStringList(value);
          if (contacts.isNotEmpty) {
            _mergeStringListArgument(
              normalized,
              "shared_by_contacts",
              contacts,
            );
          }
          break;
        case "people_in_media":
        case "person_names":
          final people = _normalizeStringList(value);
          if (people.isNotEmpty) {
            _mergeStringListArgument(normalized, "people_in_media", people);
          }
          break;
        case "place_names":
        case "location_tag_names":
        case "place_queries":
          final places = _normalizeStringList(value);
          if (places.isNotEmpty) {
            _mergeStringListArgument(normalized, "place_names", places);
          }
          break;
        case "media_type":
          if (value is String) {
            final mediaType = value.trim().toLowerCase();
            if (_mediaTypes.contains(mediaType)) {
              normalized["media_type"] = mediaType;
            } else {
              warnings.add("Ignoring invalid media_type '$value'");
            }
          }
          break;
        case "file_types":
          final array = _normalizeStringList(value);
          final mediaType = _mediaTypeFromLegacyFileTypes(array);
          if (mediaType != null) {
            normalized["media_type"] = mediaType;
          }
          break;
        case "text_query":
        case "filename_query":
        case "caption_query":
          if (value is String && value.trim().isNotEmpty) {
            _mergeSingularStringArgument(
              normalized,
              "text_query",
              value.trim(),
              warnings,
            );
          }
          break;
        case "camera_query":
        case "camera_make_query":
        case "camera_model_query":
          if (value is String && value.trim().isNotEmpty) {
            _mergeSingularStringArgument(
              normalized,
              "camera_query",
              value.trim(),
              warnings,
            );
          }
          break;
        case "visual_query":
        case "semantic_query":
          if (value is String && value.trim().isNotEmpty) {
            _mergeSingularStringArgument(
              normalized,
              "visual_query",
              value.trim(),
              warnings,
            );
          }
          break;
        case "ownership_scope":
          if (value is String && _ownershipScopes.contains(value.trim())) {
            normalized[key] = value.trim();
          } else {
            warnings.add("Ignoring invalid ownership_scope '$value'");
          }
          break;
        case "people_mode":
        case "person_operator":
          if (value is String && _personOperators.contains(value.trim())) {
            normalized["people_mode"] = value.trim();
          } else {
            warnings.add("Ignoring invalid person_operator '$value'");
          }
          break;
        case "file_format":
          if (value is String && value.trim().isNotEmpty) {
            normalized["file_format"] = _normalizeFileFormatQuery(value);
          }
          break;
        case "video_duration_query":
        case "file_size_query":
          if (value is String && value.trim().isNotEmpty) {
            normalized[key] = value.trim();
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

    if (normalized.containsKey("people_in_media") &&
        !normalized.containsKey("people_mode")) {
      normalized["people_mode"] = "any";
    }
    if (normalized.containsKey("shared_by_contacts") &&
        !normalized.containsKey("ownership_scope")) {
      normalized["ownership_scope"] = "shared_by_contacts";
    }

    return _NormalizationResult(arguments: normalized, warnings: warnings);
  }

  Future<ArgumentPruningResult> _pruneArgumentsForExecution({
    required String originalQuery,
    required Map<String, dynamic> normalizedArguments,
  }) async {
    final canonicalAlbumNames = await _getCanonicalAlbumNames();
    final canonicalPersonNames = await _getCanonicalPersonNames();
    final canonicalContactNames = _getCanonicalContactNames();

    return pruneArgumentsForQueryConsistency(
      originalQuery: originalQuery,
      normalizedArguments: normalizedArguments,
      canonicalAlbumNames: canonicalAlbumNames,
      canonicalPersonNames: canonicalPersonNames,
      canonicalContactNames: canonicalContactNames,
      searchStartYearOverride: searchStartYear,
      nowOverride: DateTime.now(),
    );
  }

  @visibleForTesting
  static ArgumentPruningResult pruneArgumentsForQueryConsistency({
    required String originalQuery,
    required Map<String, dynamic> normalizedArguments,
    required Set<String> canonicalAlbumNames,
    required Set<String> canonicalPersonNames,
    required Set<String> canonicalContactNames,
    required int searchStartYearOverride,
    required DateTime nowOverride,
  }) {
    final pruned = Map<String, dynamic>.from(normalizedArguments);
    final warnings = <String>[];
    final normalizedQuery = _normalizeContextText(originalQuery);
    final queryTokens =
        _extractMeaningfulContextTokens(normalizedQuery).toSet();
    final hasAlbumIntent = queryTokens.any(_albumIntentTokens.contains);
    final hasSharingIntent = queryTokens.any(_sharingIntentTokens.contains) ||
        normalizedQuery.contains("shared by") ||
        normalizedQuery.contains("shared with");

    if (pruned["album_names"] case final List<String> albumNames) {
      final retainedAlbumNames = albumNames.where((albumName) {
        final normalizedAlbumName = _normalizeContextText(albumName);
        if (normalizedAlbumName.isEmpty) {
          warnings.add("Dropping empty album_names value");
          return false;
        }
        if (!_containsValueIgnoreCase(canonicalAlbumNames, albumName)) {
          warnings.add("Dropping unknown album_names value '$albumName'");
          return false;
        }
        if (!_containsWholePhrase(normalizedQuery, normalizedAlbumName)) {
          warnings.add(
            "Dropping album_names value '$albumName' because it is not grounded in the query",
          );
          return false;
        }
        if (_looksLikeTemporalValue(
              normalizedAlbumName,
              searchStartYearOverride: searchStartYearOverride,
              nowOverride: nowOverride,
            ) &&
            !hasAlbumIntent) {
          warnings.add(
            "Dropping album_names value '$albumName' because it looks like a time phrase",
          );
          return false;
        }
        return true;
      }).toList(growable: false);
      if (retainedAlbumNames.isEmpty) {
        pruned.remove("album_names");
      } else {
        pruned["album_names"] = retainedAlbumNames;
      }
    }

    if (pruned["people_in_media"] case final List<String> peopleInMedia) {
      final retainedPeople = peopleInMedia.where((personName) {
        final normalizedPersonName = _normalizeContextText(personName);
        if (normalizedPersonName.isEmpty) {
          warnings.add("Dropping empty people_in_media value");
          return false;
        }
        if (_reservedPeopleValues.contains(normalizedPersonName)) {
          warnings.add(
            "Dropping invalid people_in_media value '$personName'",
          );
          return false;
        }
        if (!_containsValueIgnoreCase(canonicalPersonNames, personName)) {
          warnings.add("Dropping unknown people_in_media value '$personName'");
          return false;
        }
        if (!_containsWholePhrase(normalizedQuery, normalizedPersonName)) {
          warnings.add(
            "Dropping people_in_media value '$personName' because it is not grounded in the query",
          );
          return false;
        }
        if (_looksLikeTemporalValue(
          normalizedPersonName,
          searchStartYearOverride: searchStartYearOverride,
          nowOverride: nowOverride,
        )) {
          warnings.add(
            "Dropping people_in_media value '$personName' because it looks like a time phrase",
          );
          return false;
        }
        return true;
      }).toList(growable: false);
      if (retainedPeople.isEmpty) {
        pruned.remove("people_in_media");
        pruned.remove("people_mode");
      } else {
        pruned["people_in_media"] = retainedPeople;
      }
    }

    if (pruned["shared_by_contacts"] case final List<String> sharedByContacts) {
      final retainedContacts = sharedByContacts.where((contactName) {
        if (!_containsValueIgnoreCase(canonicalContactNames, contactName)) {
          warnings.add(
            "Dropping unknown shared_by_contacts value '$contactName'",
          );
          return false;
        }
        if (!hasSharingIntent) {
          warnings.add(
            "Dropping shared_by_contacts because the query has no sharing intent",
          );
          return false;
        }
        final contactTokens =
            _extractMeaningfulContextTokens(_normalizeContextText(contactName))
                .toSet();
        if (contactTokens.intersection(queryTokens).isEmpty) {
          warnings.add(
            "Dropping shared_by_contacts value '$contactName' because it is not grounded in the query",
          );
          return false;
        }
        return true;
      }).toList(growable: false);
      if (retainedContacts.isEmpty) {
        pruned.remove("shared_by_contacts");
      } else {
        pruned["shared_by_contacts"] = retainedContacts;
      }
    }

    if (pruned["ownership_scope"] case final String ownershipScope) {
      if (!_shouldKeepOwnershipScopeForQuery(
        originalQuery,
        ownershipScope,
        hasSharingIntent: hasSharingIntent,
        hasSharedByContacts: pruned.containsKey("shared_by_contacts"),
      )) {
        warnings.add(
          "Dropping ownership_scope '$ownershipScope' because it is not grounded in the query",
        );
        pruned.remove("ownership_scope");
      }
    }

    return ArgumentPruningResult(arguments: pruned, warnings: warnings);
  }

  static void _mergeStringListArgument(
    Map<String, dynamic> normalized,
    String key,
    List<String> values,
  ) {
    final merged = <String>[
      ...((normalized[key] as List<String>?) ?? const <String>[]),
    ];
    for (final value in values) {
      if (!merged.contains(value)) {
        merged.add(value);
      }
    }
    if (merged.isNotEmpty) {
      normalized[key] = merged;
    }
  }

  static void _mergeSingularStringArgument(
    Map<String, dynamic> normalized,
    String key,
    String value,
    List<String> warnings,
  ) {
    final existing = normalized[key] as String?;
    if (existing == null || existing == value) {
      normalized[key] = value;
      return;
    }
    warnings.add("Ignoring conflicting value for '$key': '$value'");
  }

  static String? _mediaTypeFromLegacyFileTypes(List<String> fileTypes) {
    if (fileTypes.isEmpty) {
      return null;
    }

    final normalizedTypes = fileTypes.map((type) => type.toLowerCase()).toSet();
    final hasPhoto = normalizedTypes.contains("image") ||
        normalizedTypes.contains("live_photo");
    final hasVideo = normalizedTypes.contains("video");
    if (hasPhoto && hasVideo) {
      return null;
    }
    if (hasPhoto) {
      return "photo";
    }
    if (hasVideo) {
      return "video";
    }
    return null;
  }

  static String _normalizeFileFormatQuery(String fileFormat) {
    final normalized = fileFormat.trim().toLowerCase();
    return normalized.startsWith(".") ? normalized.substring(1) : normalized;
  }

  static bool _containsValueIgnoreCase(
    Iterable<String> values,
    String candidate,
  ) {
    final normalizedCandidate = candidate.trim().toLowerCase();
    return values.any(
      (value) => value.trim().toLowerCase() == normalizedCandidate,
    );
  }

  static bool _looksLikeTemporalValue(
    String value, {
    required int searchStartYearOverride,
    required DateTime nowOverride,
  }) {
    if (resolveTimeQueryToRanges(
      value,
      searchStartYearOverride: searchStartYearOverride,
      nowOverride: nowOverride,
    ).isNotEmpty) {
      return true;
    }
    return RegExp(r"^\d{4}$").hasMatch(value);
  }

  static bool _shouldKeepOwnershipScopeForQuery(
    String originalQuery,
    String ownershipScope, {
    required bool hasSharingIntent,
    required bool hasSharedByContacts,
  }) {
    final normalizedQuery = " ${_normalizeContextText(originalQuery)} ";
    switch (ownershipScope) {
      case "mine":
        return normalizedQuery.contains(" my ") ||
            normalizedQuery.contains(" mine ") ||
            normalizedQuery.contains(" own ");
      case "shared_with_me":
        return normalizedQuery.contains("shared with me") ||
            normalizedQuery.contains("sent to me") ||
            normalizedQuery.contains("for me");
      case "shared_by_contacts":
        return hasSharingIntent || hasSharedByContacts;
      case "all_accessible":
        return normalizedQuery.contains("all accessible") ||
            normalizedQuery.contains("everything i can access") ||
            normalizedQuery.contains("everything accessible") ||
            normalizedQuery.contains("all my accessible");
    }
    return false;
  }

  static Set<String> _resolveFileFormatAliases(String fileFormat) {
    final normalized = _normalizeFileFormatQuery(fileFormat);
    switch (normalized) {
      case "jpg":
      case "jpeg":
        return {"jpg", "jpeg"};
      case "heic":
      case "heif":
        return {"heic", "heif"};
      case "tif":
      case "tiff":
        return {"tif", "tiff"};
      default:
        return normalized.isEmpty ? const <String>{} : {normalized};
    }
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
            (arguments["shared_by_contacts"] as List<String>?) ?? const [];
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

  Future<_AlbumResolutionResult> _resolveAlbumNames(
    List<String> requestedNames,
  ) async {
    final warnings = <String>[];
    final normalizedToCollectionIDs = <String, Set<int>>{};
    final collections = CollectionsService.instance.getCollectionsForUI(
      includedShared: true,
      includeCollab: true,
    );
    for (final collection in collections) {
      final name = collection.displayName.trim();
      if (name.isEmpty) {
        continue;
      }
      normalizedToCollectionIDs
          .putIfAbsent(name.toLowerCase(), () => <int>{})
          .add(collection.id);
    }

    final normalizedToPathIDs = <String, Set<String>>{};
    final deviceCollections = await FilesDB.instance.getDeviceCollections();
    for (final collection in deviceCollections) {
      final name = collection.name.trim();
      if (name.isEmpty) {
        continue;
      }
      normalizedToPathIDs
          .putIfAbsent(name.toLowerCase(), () => <String>{})
          .add(collection.id);
    }

    final collectionIds = <int>{};
    final pathIDs = <String>{};
    for (final requestedName in requestedNames) {
      final normalizedName = requestedName.trim().toLowerCase();
      var matched = false;

      final matchedCollectionIds = normalizedToCollectionIDs[normalizedName];
      if (matchedCollectionIds != null && matchedCollectionIds.isNotEmpty) {
        collectionIds.addAll(matchedCollectionIds);
        matched = true;
      }

      final matchedPathIDs = normalizedToPathIDs[normalizedName];
      if (matchedPathIDs != null && matchedPathIDs.isNotEmpty) {
        pathIDs.addAll(matchedPathIDs);
        matched = true;
      }

      if (!matched) {
        warnings.add("No album found for '$requestedName'");
      }
    }

    final pathIDToLocalIDMap =
        await FilesDB.instance.getDevicePathIDToLocalIDMap();
    final localIDs = <String>{};
    for (final pathID in pathIDs) {
      final ids = pathIDToLocalIDMap[pathID];
      if (ids != null) {
        localIDs.addAll(ids);
      }
    }

    return _AlbumResolutionResult(
      collectionIds: collectionIds,
      localIDs: localIDs,
      pathIDs: pathIDs,
      warnings: warnings,
    );
  }

  Set<FileType> _resolveMediaType(String mediaType) {
    switch (mediaType) {
      case "photo":
        return {
          FileType.image,
          FileType.livePhoto,
        };
      case "video":
        return {
          FileType.video,
        };
    }
    return const <FileType>{};
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

  Future<_PlaceQueryResolutionResult> _resolveFilesForPlaceNames({
    required List<EnteFile> files,
    required List<String> placeNames,
  }) async {
    final warnings = <String>[];
    if (files.isEmpty) {
      return _PlaceQueryResolutionResult(
        files: const [],
        matchesSummary: const <String, dynamic>{},
        warnings: warnings,
      );
    }

    final locationTags = await locationService.getLocationTags();
    final normalizedToTags = <String, List<LocationTag>>{};
    for (final localEntity in locationTags) {
      final tag = localEntity.item;
      normalizedToTags
          .putIfAbsent(tag.name.trim().toLowerCase(), () => <LocationTag>[])
          .add(tag);
    }

    final matchedTags = <LocationTag>[];
    final freeTextPlaces = <String>[];
    final matchedTagNames = <String>[];
    for (final placeName in placeNames) {
      final normalizedName = placeName.trim().toLowerCase();
      final exactTags = normalizedToTags[normalizedName];
      if (exactTags != null && exactTags.isNotEmpty) {
        matchedTags.addAll(exactTags);
        matchedTagNames.add(placeName);
      } else {
        freeTextPlaces.add(placeName);
      }
    }

    final matchedFiles = <EnteFile>{};
    final matchesSummary = <String, dynamic>{};

    if (matchedTags.isNotEmpty) {
      matchesSummary["location_tag_names"] = matchedTagNames;
      matchedFiles.addAll(
        files.where((file) {
          if (!file.hasLocation) {
            return false;
          }
          for (final tag in matchedTags) {
            if (isFileInsideLocationTag(
              tag.centerPoint,
              file.location!,
              tag.radius,
            )) {
              return true;
            }
          }
          return false;
        }),
      );
    }

    if (freeTextPlaces.isNotEmpty) {
      final placeQueryResolution = await _resolveFilesForPlaceQueries(
        files: files,
        placeQueries: freeTextPlaces,
      );
      warnings.addAll(placeQueryResolution.warnings);
      matchesSummary["place_queries"] = placeQueryResolution.matchesSummary;
      matchedFiles.addAll(placeQueryResolution.files);
    }

    if (matchedFiles.isEmpty && matchedTags.isEmpty && freeTextPlaces.isEmpty) {
      warnings.add("No place names resolved from place_names");
    }

    return _PlaceQueryResolutionResult(
      files: matchedFiles.toList(growable: false),
      matchesSummary: matchesSummary,
      warnings: warnings,
    );
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

  @visibleForTesting
  static Map<String, int> resolveVideoDurationQueryToRangeJson(
    String durationQuery,
  ) {
    return _resolveVideoDurationQuery(durationQuery).toJson();
  }

  static _NumericRangeResult _resolveVideoDurationQuery(String durationQuery) {
    final normalized = _normalizeNumericQueryText(durationQuery);
    if (normalized.isEmpty) {
      return _NumericRangeResult(
        min: null,
        max: null,
        warnings: ["Could not parse empty video_duration_query"],
      );
    }

    final betweenMatch = RegExp(
      r"(?:between|from)\s+(\d+(?:\.\d+)?)\s*(hours?|hrs?|hr|h|minutes?|minute|mins?|min|m|seconds?|second|secs?|sec|s)?\s+(?:and|to)\s+(\d+(?:\.\d+)?)\s*(hours?|hrs?|hr|h|minutes?|minute|mins?|min|m|seconds?|second|secs?|sec|s)\b",
    ).firstMatch(normalized);
    if (betweenMatch != null) {
      final firstValue = double.parse(betweenMatch.group(1)!);
      final firstUnit = betweenMatch.group(2) ?? betweenMatch.group(4)!;
      final secondValue = double.parse(betweenMatch.group(3)!);
      final secondUnit = betweenMatch.group(4)!;
      return _buildDurationRange(
        firstValue: firstValue,
        firstUnit: firstUnit,
        secondValue: secondValue,
        secondUnit: secondUnit,
        inclusive: true,
      );
    }

    final rangedMatch = RegExp(
      r"(\d+(?:\.\d+)?)\s*(hours?|hrs?|hr|h|minutes?|minute|mins?|min|m|seconds?|second|secs?|sec|s)?\s*-\s*(\d+(?:\.\d+)?)\s*(hours?|hrs?|hr|h|minutes?|minute|mins?|min|m|seconds?|second|secs?|sec|s)\b",
    ).firstMatch(normalized);
    if (rangedMatch != null) {
      final firstValue = double.parse(rangedMatch.group(1)!);
      final firstUnit = rangedMatch.group(2) ?? rangedMatch.group(4)!;
      final secondValue = double.parse(rangedMatch.group(3)!);
      final secondUnit = rangedMatch.group(4)!;
      return _buildDurationRange(
        firstValue: firstValue,
        firstUnit: firstUnit,
        secondValue: secondValue,
        secondUnit: secondUnit,
        inclusive: true,
      );
    }

    final inclusiveLowerMatch = RegExp(
      r"(?:at least|minimum of|min(?:imum)? of|no less than)\s+(.+)$",
    ).firstMatch(normalized);
    if (inclusiveLowerMatch != null) {
      final value =
          _parseDurationPhraseToSeconds(inclusiveLowerMatch.group(1)!);
      if (value != null) {
        return _NumericRangeResult(
          min: value,
          max: null,
          warnings: const [],
        );
      }
    }

    final strictLowerMatch = RegExp(
      r"(?:over|more than|longer than|above|greater than)\s+(.+)$",
    ).firstMatch(normalized);
    if (strictLowerMatch != null) {
      final value = _parseDurationPhraseToSeconds(strictLowerMatch.group(1)!);
      if (value != null) {
        return _NumericRangeResult(
          min: value + 1,
          max: null,
          warnings: const [],
        );
      }
    }

    final inclusiveUpperMatch = RegExp(
      r"(?:at most|up to|maximum of|max(?:imum)? of|no more than)\s+(.+)$",
    ).firstMatch(normalized);
    if (inclusiveUpperMatch != null) {
      final value =
          _parseDurationPhraseToSeconds(inclusiveUpperMatch.group(1)!);
      if (value != null) {
        return _NumericRangeResult(
          min: null,
          max: value,
          warnings: const [],
        );
      }
    }

    final strictUpperMatch = RegExp(
      r"(?:under|less than|shorter than|below)\s+(.+)$",
    ).firstMatch(normalized);
    if (strictUpperMatch != null) {
      final value = _parseDurationPhraseToSeconds(strictUpperMatch.group(1)!);
      if (value != null) {
        return _NumericRangeResult(
          min: null,
          max: value > 0 ? value - 1 : 0,
          warnings: const [],
        );
      }
    }

    final exactValue = _parseDurationPhraseToSeconds(normalized);
    if (exactValue != null) {
      return _NumericRangeResult(
        min: exactValue,
        max: exactValue,
        warnings: const [],
      );
    }

    return _NumericRangeResult(
      min: null,
      max: null,
      warnings: ["Could not parse video_duration_query '$durationQuery'"],
    );
  }

  @visibleForTesting
  static Map<String, int> resolveFileSizeQueryToRangeJson(
    String fileSizeQuery,
  ) {
    return _resolveFileSizeQuery(fileSizeQuery).toJson();
  }

  static _NumericRangeResult _resolveFileSizeQuery(String fileSizeQuery) {
    final normalized = _normalizeNumericQueryText(fileSizeQuery);
    if (normalized.isEmpty) {
      return _NumericRangeResult(
        min: null,
        max: null,
        warnings: ["Could not parse empty file_size_query"],
      );
    }

    final betweenMatch = RegExp(
      r"(?:between|from)\s+(\d+(?:\.\d+)?)\s*(bytes?|b|kb|kib|mb|mib|gb|gib|tb|tib)?\s+(?:and|to)\s+(\d+(?:\.\d+)?)\s*(bytes?|b|kb|kib|mb|mib|gb|gib|tb|tib)\b",
    ).firstMatch(normalized);
    if (betweenMatch != null) {
      final firstValue = double.parse(betweenMatch.group(1)!);
      final firstUnit = betweenMatch.group(2) ?? betweenMatch.group(4)!;
      final secondValue = double.parse(betweenMatch.group(3)!);
      final secondUnit = betweenMatch.group(4)!;
      return _buildSizeRange(
        firstValue: firstValue,
        firstUnit: firstUnit,
        secondValue: secondValue,
        secondUnit: secondUnit,
      );
    }

    final rangedMatch = RegExp(
      r"(\d+(?:\.\d+)?)\s*(bytes?|b|kb|kib|mb|mib|gb|gib|tb|tib)?\s*-\s*(\d+(?:\.\d+)?)\s*(bytes?|b|kb|kib|mb|mib|gb|gib|tb|tib)\b",
    ).firstMatch(normalized);
    if (rangedMatch != null) {
      final firstValue = double.parse(rangedMatch.group(1)!);
      final firstUnit = rangedMatch.group(2) ?? rangedMatch.group(4)!;
      final secondValue = double.parse(rangedMatch.group(3)!);
      final secondUnit = rangedMatch.group(4)!;
      return _buildSizeRange(
        firstValue: firstValue,
        firstUnit: firstUnit,
        secondValue: secondValue,
        secondUnit: secondUnit,
      );
    }

    final inclusiveLowerMatch = RegExp(
      r"(?:at least|minimum of|min(?:imum)? of|no less than)\s+(.+)$",
    ).firstMatch(normalized);
    if (inclusiveLowerMatch != null) {
      final value = _parseFileSizePhraseToBytes(inclusiveLowerMatch.group(1)!);
      if (value != null) {
        return _NumericRangeResult(
          min: value,
          max: null,
          warnings: const [],
        );
      }
    }

    final strictLowerMatch = RegExp(
      r"(?:over|more than|larger than|bigger than|greater than|above)\s+(.+)$",
    ).firstMatch(normalized);
    if (strictLowerMatch != null) {
      final value = _parseFileSizePhraseToBytes(strictLowerMatch.group(1)!);
      if (value != null) {
        return _NumericRangeResult(
          min: value + 1,
          max: null,
          warnings: const [],
        );
      }
    }

    final inclusiveUpperMatch = RegExp(
      r"(?:at most|up to|maximum of|max(?:imum)? of|no more than)\s+(.+)$",
    ).firstMatch(normalized);
    if (inclusiveUpperMatch != null) {
      final value = _parseFileSizePhraseToBytes(inclusiveUpperMatch.group(1)!);
      if (value != null) {
        return _NumericRangeResult(
          min: null,
          max: value,
          warnings: const [],
        );
      }
    }

    final strictUpperMatch = RegExp(
      r"(?:under|less than|smaller than|below)\s+(.+)$",
    ).firstMatch(normalized);
    if (strictUpperMatch != null) {
      final value = _parseFileSizePhraseToBytes(strictUpperMatch.group(1)!);
      if (value != null) {
        return _NumericRangeResult(
          min: null,
          max: value > 0 ? value - 1 : 0,
          warnings: const [],
        );
      }
    }

    final exactValue = _parseFileSizePhraseToBytes(normalized);
    if (exactValue != null) {
      return _NumericRangeResult(
        min: exactValue,
        max: exactValue,
        warnings: const [],
      );
    }

    return _NumericRangeResult(
      min: null,
      max: null,
      warnings: ["Could not parse file_size_query '$fileSizeQuery'"],
    );
  }

  static _NumericRangeResult _buildDurationRange({
    required double firstValue,
    required String firstUnit,
    required double secondValue,
    required String secondUnit,
    required bool inclusive,
  }) {
    final firstSeconds = _durationToSeconds(firstValue, firstUnit);
    final secondSeconds = _durationToSeconds(secondValue, secondUnit);
    if (firstSeconds == null || secondSeconds == null) {
      return _NumericRangeResult(
        min: null,
        max: null,
        warnings: const ["Could not parse video_duration_query range"],
      );
    }
    var min = firstSeconds;
    var max = secondSeconds;
    if (min > max) {
      final tmp = min;
      min = max;
      max = tmp;
    }
    return _NumericRangeResult(
      min: min,
      max: inclusive ? max : max - 1,
      warnings: const [],
    );
  }

  static _NumericRangeResult _buildSizeRange({
    required double firstValue,
    required String firstUnit,
    required double secondValue,
    required String secondUnit,
  }) {
    final firstBytes = _fileSizeToBytes(firstValue, firstUnit);
    final secondBytes = _fileSizeToBytes(secondValue, secondUnit);
    if (firstBytes == null || secondBytes == null) {
      return _NumericRangeResult(
        min: null,
        max: null,
        warnings: const ["Could not parse file_size_query range"],
      );
    }
    var min = firstBytes;
    var max = secondBytes;
    if (min > max) {
      final tmp = min;
      min = max;
      max = tmp;
    }
    return _NumericRangeResult(min: min, max: max, warnings: const []);
  }

  static int? _parseDurationPhraseToSeconds(String phrase) {
    final normalized = _normalizeNumericQueryText(phrase);
    final matches = RegExp(
      r"(\d+(?:\.\d+)?)\s*(hours?|hrs?|hr|h|minutes?|minute|mins?|min|m|seconds?|second|secs?|sec|s)\b",
    ).allMatches(normalized);
    if (matches.isEmpty) {
      return null;
    }

    var totalSeconds = 0.0;
    for (final match in matches) {
      final value = double.parse(match.group(1)!);
      final unit = match.group(2)!;
      final seconds = _durationToSeconds(value, unit);
      if (seconds == null) {
        return null;
      }
      totalSeconds += seconds;
    }
    return totalSeconds.round();
  }

  static int? _durationToSeconds(double value, String unit) {
    switch (unit.toLowerCase()) {
      case "h":
      case "hr":
      case "hrs":
      case "hour":
      case "hours":
        return (value * 60 * 60).round();
      case "m":
      case "min":
      case "mins":
      case "minute":
      case "minutes":
        return (value * 60).round();
      case "s":
      case "sec":
      case "secs":
      case "second":
      case "seconds":
        return value.round();
    }
    return null;
  }

  static int? _parseFileSizePhraseToBytes(String phrase) {
    final normalized = _normalizeNumericQueryText(phrase);
    final match = RegExp(
      r"(\d+(?:\.\d+)?)\s*(bytes?|b|kb|kib|mb|mib|gb|gib|tb|tib)\b",
    ).firstMatch(normalized);
    if (match == null) {
      return null;
    }
    return _fileSizeToBytes(
      double.parse(match.group(1)!),
      match.group(2)!,
    );
  }

  static int? _fileSizeToBytes(double value, String unit) {
    switch (unit.toLowerCase()) {
      case "b":
      case "byte":
      case "bytes":
        return value.round();
      case "kb":
      case "kib":
        return (value * 1024).round();
      case "mb":
      case "mib":
        return (value * 1024 * 1024).round();
      case "gb":
      case "gib":
        return (value * 1024 * 1024 * 1024).round();
      case "tb":
      case "tib":
        return (value * 1024 * 1024 * 1024 * 1024).round();
    }
    return null;
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
    if (!_supportedToolNames.contains(trimmedName)) {
      throw FormatException(
        "Unexpected tool call '$trimmedName'. Expected one of ${_supportedToolNames.toList(growable: false)}",
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
  final List<String> validationIssues;
  final Map<String, dynamic> rawCallJson;

  NaturalSearchParsedToolCall({
    required this.name,
    required this.arguments,
    required this.warnings,
    required this.validationIssues,
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
  final String? functionGemmaPrompt;
  final String? rawFunctionGemmaToolCallOutput;
  final GenericSearchResult searchResult;

  NaturalSearchExecutionResult({
    required this.originalQuery,
    required this.normalizedToolArguments,
    required this.resolvedArguments,
    required this.files,
    required this.warnings,
    required this.initialFilter,
    this.functionGemmaPrompt,
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

class ArgumentPruningResult {
  final Map<String, dynamic> arguments;
  final List<String> warnings;

  ArgumentPruningResult({
    required this.arguments,
    required this.warnings,
  });
}

class _ScoredContextCandidate {
  final String candidate;
  final int score;

  _ScoredContextCandidate({
    required this.candidate,
    required this.score,
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

class _AlbumResolutionResult {
  final Set<int> collectionIds;
  final Set<String> localIDs;
  final Set<String> pathIDs;
  final List<String> warnings;

  _AlbumResolutionResult({
    required this.collectionIds,
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

  _NumericRangeResult scale(int factor) {
    return _NumericRangeResult(
      min: min != null ? min! * factor : null,
      max: max != null ? max! * factor : null,
      warnings: warnings,
    );
  }
}

class _ResolvedCalendarDate {
  final int year;
  final int month;
  final int day;

  const _ResolvedCalendarDate({
    required this.year,
    required this.month,
    required this.day,
  });

  DateTime toDateTime() => DateTime(year, month, day);
}
