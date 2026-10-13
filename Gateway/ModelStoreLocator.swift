import CoreAIKit
import Foundation

/// Finds a downloaded model in the CoreAIKit cache. Only resolves a path: the model itself is
/// loaded by the worker, so the Gateway never holds weights.
struct ModelStoreLocator: ModelLocating {
    func localPath(for model: ModelReference) -> String? {
        let id = ModelID(model.repo, path: model.path, revision: model.revision)
        return ModelStore.default.localURL(for: id)?.path
    }
}
