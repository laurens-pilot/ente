import "package:logging/logging.dart";
import "package:photos/services/machine_learning/ml_model.dart";

class FunctionGemmaNaturalSearchModel extends MlModel {
  static const kRemoteBucketModelPath = "functiongemma_ente_search_v1_Q8.gguf";
  static const _modelName = "FunctionGemmaNaturalSearchModel";

  @override
  String get modelRemotePath => kModelBucketEndpoint + kRemoteBucketModelPath;

  @override
  Logger get logger => _logger;
  static final _logger = Logger(_modelName);

  @override
  String get modelName => _modelName;

  FunctionGemmaNaturalSearchModel._privateConstructor();
  static final instance = FunctionGemmaNaturalSearchModel._privateConstructor();
  factory FunctionGemmaNaturalSearchModel() => instance;
}
