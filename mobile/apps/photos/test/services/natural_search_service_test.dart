import "package:flutter_test/flutter_test.dart";
import "package:photos/services/machine_learning/natural_search/natural_search_service.dart";

void main() {
  group("buildFunctionGemmaPromptPayloadJson", () {
    test("encodes required fields for Rust inference payload", () {
      const developerPrompt = "developer prompt";
      const toolSchemaRaw = "{\"type\":\"function\"}";
      const userQuery = "photos of the beach";

      final payload = NaturalSearchService.buildFunctionGemmaPromptPayloadJson(
        developerPrompt: developerPrompt,
        toolSchemaRaw: toolSchemaRaw,
        userQuery: userQuery,
      );

      expect(payload, contains("\"developer_prompt\""));
      expect(payload, contains("\"tool_schema_json\""));
      expect(payload, contains("\"user_query\""));
      expect(payload, contains(developerPrompt));
      expect(payload, contains(toolSchemaRaw.replaceAll("\"", "\\\"")));
      expect(payload, contains(userQuery));
    });
  });

  group("parseToolCallPayload", () {
    test("parses <tool_call> payload", () {
      const rawOutput = """
<tool_call>
{"name":"search_photos_v1","arguments":{"limit":10}}
</tool_call>
""";

      final parsed = NaturalSearchService.parseToolCallPayload(rawOutput);

      expect(parsed.name, "search_photos_v1");
      expect(parsed.arguments["limit"], 10);
      expect(parsed.arguments.containsKey("sort_by"), isFalse);
    });

    test("parses JSON with stringified arguments", () {
      const rawOutput =
          "{\"name\":\"search_photos_v1\",\"arguments\":\"{\\\"visual_query\\\":\\\"Photo of a beach\\\"}\"}";

      final parsed = NaturalSearchService.parseToolCallPayload(rawOutput);

      expect(parsed.name, "search_photos_v1");
      expect(parsed.arguments["visual_query"], "Photo of a beach");
    });

    test("parses code-fenced payload", () {
      const rawOutput = """
```json
{
  "name": "search_photos_v1",
  "arguments": {
    "ownership_scope": "mine"
  }
}
```
""";

      final parsed = NaturalSearchService.parseToolCallPayload(rawOutput);

      expect(parsed.name, "search_photos_v1");
      expect(parsed.arguments["ownership_scope"], "mine");
    });

    test("throws when tool name is not search_photos_v1", () {
      const rawOutput = "{\"name\":\"wrong_tool\",\"arguments\":{\"limit\":5}}";

      expect(
        () => NaturalSearchService.parseToolCallPayload(rawOutput),
        throwsFormatException,
      );
    });

    test("throws when multiple tool_call blocks are present", () {
      const rawOutput = """
<tool_call>{"name":"search_photos_v1","arguments":{"limit":1}}</tool_call>
<tool_call>{"name":"search_photos_v1","arguments":{"limit":2}}</tool_call>
""";

      expect(
        () => NaturalSearchService.parseToolCallPayload(rawOutput),
        throwsFormatException,
      );
    });
  });

  group("parseModelOutput", () {
    test("drops obsolete sort_by argument", () {
      const rawOutput =
          "{\"name\":\"search_photos_v1\",\"arguments\":{\"limit\":10,\"sort_by\":\"newest_first\"}}";

      final parsed = NaturalSearchService.instance.parseModelOutput(rawOutput);

      expect(parsed.arguments["limit"], 10);
      expect(parsed.arguments.containsKey("sort_by"), isFalse);
      expect(
        parsed.warnings,
        contains("Ignoring unknown argument field 'sort_by'"),
      );
      expect(parsed.validationIssues, isEmpty);
    });

    test("detects obvious schema leakage and malformed field shapes", () {
      const rawOutput =
          "{\"name\":\"search_photos_v1\",\"arguments\":{\"additionalProperties\":false,\"video_duration_seconds\":0,\"location_tag_names\":[\"Amsterdam\"],\"kind\":\"photos\"}}";

      final parsed = NaturalSearchService.instance.parseModelOutput(rawOutput);

      expect(parsed.arguments, {
        "place_names": ["Amsterdam"],
      });
      expect(parsed.validationIssues, isNotEmpty);
      expect(
        parsed.validationIssues,
        contains(
          "Unexpected schema keyword 'arguments.additionalProperties' in arguments",
        ),
      );
      expect(
        parsed.validationIssues,
        contains(
          "Field 'video_duration_seconds' must be an object, got int",
        ),
      );
      expect(
        parsed.validationIssues,
        contains(
          "Unexpected top-level 'kind' in arguments; expected time_filter.kind",
        ),
      );
    });

    test("normalizes simplified planner arguments", () {
      const rawOutput =
          "{\"name\":\"search_photos_v1\",\"arguments\":{\"media_type\":\"photo\",\"people_in_media\":[\"Laurens\"],\"people_mode\":\"all\",\"time_query\":\"last month\",\"visual_query\":\"Photo of a beach\",\"file_format\":\".heic\"}}";

      final parsed = NaturalSearchService.instance.parseModelOutput(rawOutput);

      expect(parsed.arguments, {
        "media_type": "photo",
        "people_in_media": ["Laurens"],
        "people_mode": "all",
        "time_query": "last month",
        "visual_query": "Photo of a beach",
        "file_format": "heic",
      });
    });
  });

  group("resolveTimeFilterToRanges", () {
    final now = DateTime(2026, 3, 5, 18, 20, 0);

    test("resolves calendar_year", () {
      final ranges = NaturalSearchService.resolveTimeFilterToRanges(
        {
          "kind": "calendar_year",
          "year": 2024,
        },
        searchStartYearOverride: 2016,
        nowOverride: now,
      );

      expect(ranges.length, 1);
      expect(
        ranges.first.startMicroseconds,
        DateTime(2024, 1, 1).microsecondsSinceEpoch,
      );
      expect(
        ranges.first.endMicrosecondsExclusive,
        DateTime(2025, 1, 1).microsecondsSinceEpoch,
      );
    });

    test("resolves absolute_range", () {
      final ranges = NaturalSearchService.resolveTimeFilterToRanges(
        {
          "kind": "absolute_range",
          "ranges": [
            {
              "start_local": "2024-03-01T00:00:00",
              "end_local_exclusive": "2024-04-01T00:00:00",
            },
          ],
        },
        searchStartYearOverride: 2016,
        nowOverride: now,
      );

      expect(ranges.length, 1);
      expect(
        ranges.first.startMicroseconds,
        DateTime(2024, 3, 1).microsecondsSinceEpoch,
      );
      expect(
        ranges.first.endMicrosecondsExclusive,
        DateTime(2024, 4, 1).microsecondsSinceEpoch,
      );
    });

    test("resolves day_month_every_year with leap-year handling", () {
      final ranges = NaturalSearchService.resolveTimeFilterToRanges(
        {
          "kind": "day_month_every_year",
          "day": 29,
          "month": 2,
        },
        searchStartYearOverride: 2020,
        nowOverride: now,
      );

      // 2020 and 2024 are leap years in [2020, 2026]
      expect(ranges.length, 2);
      expect(
        ranges[0].startMicroseconds,
        DateTime(2020, 2, 29).microsecondsSinceEpoch,
      );
      expect(
        ranges[1].startMicroseconds,
        DateTime(2024, 2, 29).microsecondsSinceEpoch,
      );
    });

    test("returns empty for invalid kind", () {
      final ranges = NaturalSearchService.resolveTimeFilterToRanges(
        {
          "kind": "invalid_kind",
        },
        searchStartYearOverride: 2016,
        nowOverride: now,
      );

      expect(ranges, isEmpty);
    });
  });

  group("resolveTimeQueryToRanges", () {
    final now = DateTime(2026, 3, 10, 11, 29, 6);

    test("resolves last month", () {
      final ranges = NaturalSearchService.resolveTimeQueryToRanges(
        "last month",
        searchStartYearOverride: 2016,
        nowOverride: now,
      );

      expect(ranges.length, 1);
      expect(
        ranges.first.startMicroseconds,
        DateTime(2026, 2, 1).microsecondsSinceEpoch,
      );
      expect(
        ranges.first.endMicrosecondsExclusive,
        DateTime(2026, 3, 1).microsecondsSinceEpoch,
      );
    });

    test("resolves explicit custom date range", () {
      final ranges = NaturalSearchService.resolveTimeQueryToRanges(
        "August 14 till August 20 of 2024",
        searchStartYearOverride: 2016,
        nowOverride: now,
      );

      expect(ranges.length, 1);
      expect(
        ranges.first.startMicroseconds,
        DateTime(2024, 8, 14).microsecondsSinceEpoch,
      );
      expect(
        ranges.first.endMicrosecondsExclusive,
        DateTime(2024, 8, 21).microsecondsSinceEpoch,
      );
    });
  });

  group("pruneArgumentsForQueryConsistency", () {
    test("drops hallucinated album, person, and ownership scope", () {
      final pruningResult =
          NaturalSearchService.pruneArgumentsForQueryConsistency(
        originalQuery: "photos from last month",
        normalizedArguments: {
          "album_names": ["2024"],
          "media_type": "photo",
          "ownership_scope": "mine",
          "people_in_media": ["all"],
          "people_mode": "any",
          "time_query": "last month",
        },
        canonicalAlbumNames: {"2024", "Trip to NYC"},
        canonicalPersonNames: {"Alice", "Laurens"},
        canonicalContactNames: const <String>{},
        searchStartYearOverride: 2016,
        nowOverride: DateTime(2026, 3, 10, 11, 29, 6),
      );

      expect(pruningResult.arguments, {
        "media_type": "photo",
        "time_query": "last month",
      });
      expect(pruningResult.warnings, isNotEmpty);
    });

    test("retains explicit ownership and grounded person", () {
      final pruningResult =
          NaturalSearchService.pruneArgumentsForQueryConsistency(
        originalQuery: "my photos of Laurens last month",
        normalizedArguments: {
          "ownership_scope": "mine",
          "people_in_media": ["Laurens"],
          "people_mode": "any",
          "time_query": "last month",
        },
        canonicalAlbumNames: const <String>{},
        canonicalPersonNames: {"Laurens"},
        canonicalContactNames: const <String>{},
        searchStartYearOverride: 2016,
        nowOverride: DateTime(2026, 3, 10, 11, 29, 6),
      );

      expect(pruningResult.arguments, {
        "ownership_scope": "mine",
        "people_in_media": ["Laurens"],
        "people_mode": "any",
        "time_query": "last month",
      });
    });
  });

  group("selectRelevantContextCandidates", () {
    test("does not include album names from loose token overlap alone", () {
      final selected = NaturalSearchService.selectRelevantContextCandidates(
        userQuery: "photos in France last month",
        candidates: const [
          "2023 Pas Pas France",
          "Favorites",
        ],
        entityKind: NaturalSearchContextEntityKind.album,
      );

      expect(selected, isEmpty);
    });

    test("includes person and location matches when query names them", () {
      final people = NaturalSearchService.selectRelevantContextCandidates(
        userQuery: "photos of Laurens in Amsterdam",
        candidates: const ["Laurens", "Ritu"],
        entityKind: NaturalSearchContextEntityKind.person,
      );
      final locations = NaturalSearchService.selectRelevantContextCandidates(
        userQuery: "photos of Laurens in Amsterdam",
        candidates: const ["Amsterdam", "Den Bosch"],
        entityKind: NaturalSearchContextEntityKind.locationTag,
      );

      expect(people, ["Laurens"]);
      expect(locations, ["Amsterdam"]);
    });

    test("only includes contact names when query suggests sharing", () {
      final withoutSharingIntent =
          NaturalSearchService.selectRelevantContextCandidates(
        userQuery: "photos of Tijmen",
        candidates: const ["Tijmen <tijmen@example.com>"],
        entityKind: NaturalSearchContextEntityKind.contact,
      );
      final withSharingIntent =
          NaturalSearchService.selectRelevantContextCandidates(
        userQuery: "photos shared by Tijmen",
        candidates: const ["Tijmen <tijmen@example.com>"],
        entityKind: NaturalSearchContextEntityKind.contact,
      );

      expect(withoutSharingIntent, isEmpty);
      expect(withSharingIntent, ["Tijmen <tijmen@example.com>"]);
    });
  });
}
