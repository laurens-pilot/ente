import "package:logging/logging.dart";
import "package:photos/services/machine_learning/ml_model.dart";

class FunctionGemmaNaturalSearchModel extends MlModel {
  static const _modelName = "FunctionGemmaNaturalSearchModel";

  // TODO(laurens): Replace with the final fine-tuned FunctionGemma GGUF URL.
  // Note: google/functiongemma-270m-it is distributed as safetensors and is
  // gated; our current Rust runtime loads GGUF, so we use a GGUF variant here.
  static const _kBaseFunctionGemmaGgufUrl =
      "https://huggingface.co/ggml-org/functiongemma-270m-it-GGUF/resolve/main/functiongemma-270m-it-q8_0.gguf";

  @override
  String get modelRemotePath => _kBaseFunctionGemmaGgufUrl;

  @override
  Logger get logger => _logger;
  static final _logger = Logger(_modelName);

  @override
  String get modelName => _modelName;

  FunctionGemmaNaturalSearchModel._privateConstructor();
  static final instance = FunctionGemmaNaturalSearchModel._privateConstructor();
  factory FunctionGemmaNaturalSearchModel() => instance;
}
