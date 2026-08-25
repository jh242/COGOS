import Foundation
import FoundationModels

struct WeatherTool: Tool {
    let name = "get_weather"
    let description = "Current weather at the wearer's last known location."
    let context: AgentDeviceContext

    @Generable
    struct Arguments {}

    @Generable
    struct Output {
        var summary: String
    }

    func call(arguments: Arguments) async throws -> Output {
        let summary = await context.weatherSummary()
        return Output(summary: summary)
    }
}
