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
          "{\"name\":\"search_photos_v1\",\"arguments\":\"{\\\"semantic_query\\\":\\\"Photo of a beach\\\"}\"}";

      final parsed = NaturalSearchService.parseToolCallPayload(rawOutput);

      expect(parsed.name, "search_photos_v1");
      expect(parsed.arguments["semantic_query"], "Photo of a beach");
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
}
