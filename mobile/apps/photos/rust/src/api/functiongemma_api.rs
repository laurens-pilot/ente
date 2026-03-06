use std::sync::Mutex;

use inference_rs::{
    ContextHandleRef, ContextParams, GenerateEvent, GenerateRequest, ModelHandleRef,
    ModelLoadParams, create_context, generate_stream, init_backend, load_model,
};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::Deserialize;
use serde_json::{Map, Value, json};

const EXPECTED_TOOL_NAME: &str = "search_photos_v1";

const DEFAULT_CONTEXT_SIZE: i32 = 32_768;
const FALLBACK_CONTEXT_SIZES: [i32; 2] = [16_384, 8_192];
const DEFAULT_MAX_TOKENS: i32 = 256;
const DEFAULT_TOP_K: i32 = 64;
const DEFAULT_TOP_P: f32 = 0.95;
const DEFAULT_TEMPERATURE: f32 = 1.0;
const DEFAULT_REPEAT_PENALTY: f32 = 1.1;
const DEFAULT_SEED: i64 = 0;
const DEFAULT_N_BATCH: i32 = 512;

static FUNCTION_CALL_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?is)call\s*:?\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\(")
        .expect("Function call regex must be valid")
});

static TOOL_CALL_TAG_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?is)<tool_call>\s*([\s\S]*?)\s*</tool_call>")
        .expect("Tool call tag regex must be valid")
});

#[derive(Clone, Debug)]
pub struct RunFunctionGemmaNaturalSearchRequest {
    pub prompt_payload_json: String,
    pub model_path: String,
}

#[derive(Clone, Debug)]
pub struct RunFunctionGemmaNaturalSearchResult {
    pub raw_output: String,
    pub normalized_tool_call_json: String,
}

#[derive(Debug, Deserialize)]
struct FunctionGemmaPromptPayload {
    developer_prompt: String,
    tool_schema_json: String,
    user_query: String,
}

struct FunctionGemmaRuntime {
    model_path: String,
    context_size: i32,
    #[allow(dead_code)]
    model: ModelHandleRef,
    context: ContextHandleRef,
}

static FUNCTION_GEMMA_RUNTIME: Lazy<Mutex<Option<FunctionGemmaRuntime>>> =
    Lazy::new(|| Mutex::new(None));

pub fn run_function_gemma_natural_search(
    req: RunFunctionGemmaNaturalSearchRequest,
) -> Result<RunFunctionGemmaNaturalSearchResult, String> {
    if req.model_path.trim().is_empty() {
        return Err("FunctionGemma model path is empty".to_string());
    }
    if req.prompt_payload_json.trim().is_empty() {
        return Err("FunctionGemma prompt payload JSON is empty".to_string());
    }

    let prompt_payload: FunctionGemmaPromptPayload = serde_json::from_str(&req.prompt_payload_json)
        .map_err(|e| format!("Invalid FunctionGemma prompt payload JSON: {e}"))?;
    let prompt = build_function_gemma_prompt(&prompt_payload)?;
    let runtime = ensure_function_gemma_runtime(&req.model_path)?;

    let mut generated_text = String::new();
    let mut stream_error: Option<String> = None;
    let mut sink = |event: GenerateEvent| match event {
        GenerateEvent::Text { text, .. } => generated_text.push_str(&text),
        GenerateEvent::Error { message, .. } => stream_error = Some(message),
        GenerateEvent::Done { .. } => {}
    };

    let request = GenerateRequest {
        prompt,
        max_tokens: Some(DEFAULT_MAX_TOKENS),
        temperature: Some(DEFAULT_TEMPERATURE),
        top_p: Some(DEFAULT_TOP_P),
        top_k: Some(DEFAULT_TOP_K),
        repeat_penalty: Some(DEFAULT_REPEAT_PENALTY),
        frequency_penalty: Some(0.0),
        presence_penalty: Some(0.0),
        seed: Some(DEFAULT_SEED),
        stop_sequences: Some(vec![
            "<end_of_turn>".to_string(),
            "<start_of_turn>".to_string(),
            "<eos>".to_string(),
        ]),
        grammar: None,
    };

    generate_stream(runtime.context.as_ref(), request, &mut sink)
        .map_err(|e| format!("FunctionGemma generation failed: {e}"))?;

    if let Some(message) = stream_error {
        return Err(format!("FunctionGemma generation stream error: {message}"));
    }

    let normalized_tool_call_json = normalize_tool_call_output(&generated_text)?;
    Ok(RunFunctionGemmaNaturalSearchResult {
        raw_output: generated_text,
        normalized_tool_call_json,
    })
}

pub fn release_function_gemma_runtime() -> Result<(), String> {
    let mut guard = lock_runtime_state()?;
    *guard = None;
    Ok(())
}

fn build_function_gemma_prompt(payload: &FunctionGemmaPromptPayload) -> Result<String, String> {
    let developer_prompt = payload.developer_prompt.trim();
    if developer_prompt.is_empty() {
        return Err("FunctionGemma payload developer_prompt is empty".to_string());
    }

    let user_query = payload.user_query.trim();
    if user_query.is_empty() {
        return Err("FunctionGemma payload user_query is empty".to_string());
    }

    let tool_schema_value: Value = serde_json::from_str(&payload.tool_schema_json)
        .map_err(|e| format!("Invalid tool_schema_json: {e}"))?;
    let tools_array = match tool_schema_value {
        Value::Array(items) => Value::Array(items),
        other => Value::Array(vec![other]),
    };
    let tool_schema_compact = serde_json::to_string(&tools_array)
        .map_err(|e| format!("Could not serialize tool schema JSON: {e}"))?;

    Ok(format!(
        "<bos><start_of_turn>user\n{developer_prompt}\n\n<tools>\n{tool_schema_compact}\n</tools>\n\nUser query:\n{user_query}\n<end_of_turn>\n<start_of_turn>model\n",
    ))
}

fn ensure_function_gemma_runtime(model_path: &str) -> Result<FunctionGemmaRuntime, String> {
    init_backend().map_err(|e| format!("Failed to initialize inference backend: {e}"))?;

    let mut guard = lock_runtime_state()?;
    if let Some(runtime) = guard.as_ref()
        && runtime.model_path == model_path
    {
        return Ok(FunctionGemmaRuntime {
            model_path: runtime.model_path.clone(),
            context_size: runtime.context_size,
            model: runtime.model.clone(),
            context: runtime.context.clone(),
        });
    }

    let model = load_model(ModelLoadParams {
        model_path: model_path.to_string(),
        n_gpu_layers: Some(0),
        use_mmap: Some(true),
        use_mlock: Some(false),
    })
    .map_err(|e| format!("Failed to load FunctionGemma model: {e}"))?;

    let mut creation_errors = Vec::new();
    let mut context: Option<(ContextHandleRef, i32)> = None;
    for context_size in candidate_context_sizes() {
        match create_context(
            model.clone(),
            ContextParams {
                context_size: Some(context_size),
                n_threads: Some(default_thread_count()),
                n_batch: Some(DEFAULT_N_BATCH),
            },
        ) {
            Ok(ctx) => {
                context = Some((ctx, context_size));
                break;
            }
            Err(e) => {
                creation_errors.push(format!("{context_size}: {e}"));
            }
        }
    }

    let (context, context_size) = context.ok_or_else(|| {
        format!(
            "Failed to create FunctionGemma context. Attempted sizes {}. Errors: {}",
            candidate_context_sizes()
                .iter()
                .map(i32::to_string)
                .collect::<Vec<_>>()
                .join(", "),
            creation_errors.join(" | ")
        )
    })?;

    let runtime = FunctionGemmaRuntime {
        model_path: model_path.to_string(),
        context_size,
        model,
        context,
    };
    *guard = Some(FunctionGemmaRuntime {
        model_path: runtime.model_path.clone(),
        context_size: runtime.context_size,
        model: runtime.model.clone(),
        context: runtime.context.clone(),
    });
    Ok(runtime)
}

fn candidate_context_sizes() -> Vec<i32> {
    let mut sizes = vec![DEFAULT_CONTEXT_SIZE];
    sizes.extend(FALLBACK_CONTEXT_SIZES);
    sizes
}

fn default_thread_count() -> i32 {
    let count = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);
    let bounded = count.clamp(1, 8);
    i32::try_from(bounded).unwrap_or(4)
}

fn lock_runtime_state()
-> Result<std::sync::MutexGuard<'static, Option<FunctionGemmaRuntime>>, String> {
    FUNCTION_GEMMA_RUNTIME
        .lock()
        .map_err(|_| "FunctionGemma runtime mutex is poisoned".to_string())
}

fn normalize_tool_call_output(raw_output: &str) -> Result<String, String> {
    let text = raw_output.trim();
    if text.is_empty() {
        return Err("FunctionGemma output is empty".to_string());
    }

    if let Some(tagged_payload) = extract_tagged_tool_call_payload(text)? {
        return normalize_tool_call_payload(&tagged_payload);
    }

    if let Some((name, arguments_json)) = extract_function_call_arguments(text)? {
        return normalize_call_from_parts(&name, &arguments_json);
    }

    if let Some(first_json_object) = extract_first_json_object(text) {
        return normalize_tool_call_payload(&first_json_object);
    }

    Err(format!(
        "Could not normalize FunctionGemma output to a tool call: {}",
        text
    ))
}

fn extract_tagged_tool_call_payload(input: &str) -> Result<Option<String>, String> {
    let blocks = TOOL_CALL_TAG_REGEX
        .captures_iter(input)
        .filter_map(|cap| cap.get(1).map(|m| m.as_str().trim().to_string()))
        .collect::<Vec<_>>();

    if blocks.len() > 1 {
        return Err("Found multiple <tool_call> blocks; expected exactly one".to_string());
    }
    Ok(blocks.into_iter().next())
}

fn extract_function_call_arguments(input: &str) -> Result<Option<(String, String)>, String> {
    let Some(captures) = FUNCTION_CALL_REGEX.captures(input) else {
        return Ok(None);
    };

    let function_name = captures
        .get(1)
        .map(|m| m.as_str().trim().to_string())
        .ok_or_else(|| "Could not read function name from call output".to_string())?;
    let whole_match = captures
        .get(0)
        .ok_or_else(|| "Could not parse call expression".to_string())?;
    let after_prefix = input
        .get(whole_match.end()..)
        .ok_or_else(|| "Could not parse function-call arguments".to_string())?;
    let first_json = extract_first_json_object(after_prefix)
        .ok_or_else(|| "Missing JSON arguments in call output".to_string())?;

    Ok(Some((function_name, first_json)))
}

fn normalize_tool_call_payload(payload: &str) -> Result<String, String> {
    let parsed: Value = serde_json::from_str(payload)
        .map_err(|e| format!("Tool call payload is not valid JSON: {e}"))?;
    let Value::Object(map) = parsed else {
        return Err(format!(
            "Tool call payload must be a JSON object, got {}",
            parsed
        ));
    };

    let (name, arguments) = parse_tool_call_map(&map)?;
    normalize_call_from_parts(
        &name,
        &serde_json::to_string(&arguments).unwrap_or_default(),
    )
}

fn normalize_call_from_parts(name: &str, arguments_json: &str) -> Result<String, String> {
    if name.trim() != EXPECTED_TOOL_NAME {
        return Err(format!(
            "Unexpected FunctionGemma tool call '{}'; expected '{}'",
            name, EXPECTED_TOOL_NAME
        ));
    }

    let mut arguments = parse_arguments_object(arguments_json)
        .map_err(|e| format!("Invalid tool arguments: {e}"))?;
    normalize_string_artifacts(&mut arguments);
    let Value::Object(arguments_map) = arguments else {
        return Err("Tool arguments must resolve to a JSON object".to_string());
    };

    let normalized = json!({
        "name": EXPECTED_TOOL_NAME,
        "arguments": Value::Object(arguments_map),
    });
    serde_json::to_string(&normalized)
        .map_err(|e| format!("Could not serialize normalized tool call: {e}"))
}

fn parse_tool_call_map(map: &Map<String, Value>) -> Result<(String, Value), String> {
    if let Some(tool_calls) = map.get("tool_calls") {
        let Value::Array(calls) = tool_calls else {
            return Err("tool_calls must be an array".to_string());
        };
        if calls.len() != 1 {
            return Err("tool_calls must contain exactly one item".to_string());
        }
        let Value::Object(first_call) = &calls[0] else {
            return Err("tool_calls[0] must be an object".to_string());
        };
        return parse_tool_call_map(first_call);
    }

    if let Some(function) = map.get("function") {
        let Value::Object(function_map) = function else {
            return Err("function must be an object".to_string());
        };
        let name = function_map
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| "function.name must be a non-empty string".to_string())?;
        let arguments = function_map
            .get("arguments")
            .cloned()
            .unwrap_or_else(|| json!({}));
        return Ok((name, arguments));
    }

    let name = map
        .get("name")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| "name must be a non-empty string".to_string())?;
    let arguments = map.get("arguments").cloned().unwrap_or_else(|| json!({}));
    Ok((name, arguments))
}

fn parse_arguments_object(arguments_json: &str) -> Result<Value, String> {
    if arguments_json.trim().is_empty() {
        return Ok(json!({}));
    }

    if let Ok(value) = serde_json::from_str::<Value>(arguments_json)
        && value.is_object()
    {
        return Ok(value);
    }

    let escaped_quote_replaced = arguments_json.replace("<escape>", "\\\"");
    if let Ok(value) = serde_json::from_str::<Value>(&escaped_quote_replaced)
        && value.is_object()
    {
        return Ok(value);
    }

    let quote_replaced = arguments_json.replace("<escape>", "\"");
    if let Ok(value) = serde_json::from_str::<Value>(&quote_replaced)
        && value.is_object()
    {
        return Ok(value);
    }

    Err("Could not parse tool-call arguments as a JSON object".to_string())
}

fn normalize_string_artifacts(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for inner in map.values_mut() {
                normalize_string_artifacts(inner);
            }
        }
        Value::Array(array) => {
            for inner in array {
                normalize_string_artifacts(inner);
            }
        }
        Value::String(text) => {
            if text.contains("<escape>") {
                let mut replaced = text.replace("<escape>", "\"");
                if replaced.starts_with('"') && replaced.ends_with('"') && replaced.len() >= 2 {
                    replaced = replaced[1..replaced.len() - 1].to_string();
                }
                *text = replaced;
                return;
            }
            if text.starts_with('"') && text.ends_with('"') && text.len() >= 2 {
                let trimmed = text[1..text.len() - 1].to_string();
                *text = trimmed;
            }
        }
        _ => {}
    }
}

fn extract_first_json_object(input: &str) -> Option<String> {
    let text = input.trim();
    let start = text.find('{')?;
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escaped = false;

    for (offset, ch) in text[start..].char_indices() {
        let idx = start + offset;
        if escaped {
            escaped = false;
            continue;
        }

        if ch == '\\' {
            escaped = true;
            continue;
        }

        if ch == '"' {
            in_string = !in_string;
            continue;
        }

        if in_string {
            continue;
        }

        if ch == '{' {
            depth += 1;
        } else if ch == '}' {
            depth -= 1;
            if depth == 0 {
                return text.get(start..=idx).map(str::to_string);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::normalize_tool_call_output;

    #[test]
    fn normalizes_tagged_tool_call_payload() {
        let raw = r#"
<tool_call>
{"name":"search_photos_v1","arguments":{"limit":10}}
</tool_call>
"#;
        let normalized = normalize_tool_call_output(raw).expect("normalization should succeed");
        assert_eq!(
            normalized,
            r#"{"arguments":{"limit":10},"name":"search_photos_v1"}"#
        );
    }

    #[test]
    fn normalizes_functiongemma_call_syntax() {
        let raw = r#"call:search_photos_v1({"semantic_query":"Photo of a beach","ownership_scope":"mine"})"#;
        let normalized = normalize_tool_call_output(raw).expect("normalization should succeed");
        assert_eq!(
            normalized,
            r#"{"arguments":{"ownership_scope":"mine","semantic_query":"Photo of a beach"},"name":"search_photos_v1"}"#
        );
    }

    #[test]
    fn normalizes_escape_wrapped_string_values() {
        let raw =
            r#"call:search_photos_v1({"place_queries":["<escape>New York<escape>"],"limit":5})"#;
        let normalized = normalize_tool_call_output(raw).expect("normalization should succeed");
        assert_eq!(
            normalized,
            r#"{"arguments":{"limit":5,"place_queries":["New York"]},"name":"search_photos_v1"}"#
        );
    }

    #[test]
    fn rejects_non_matching_tool_name() {
        let raw = r#"call:wrong_tool({"limit":5})"#;
        let error = normalize_tool_call_output(raw).expect_err("should fail");
        assert!(error.contains("Unexpected FunctionGemma tool call"));
    }
}
