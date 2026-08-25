import Foundation
import FoundationModels

struct LocationTool: Tool {
    let name = "get_location"
    let description = "The wearer's last known place name and coordinates."
    let context: AgentDeviceContext

    @Generable
    struct Arguments {}

    @Generable
    struct Output {
        var summary: String
    }

    func call(arguments: Arguments) async throws -> Output {
        let summary = await context.placeSummary()
        return Output(summary: summary)
    }
}
