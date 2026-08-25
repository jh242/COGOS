import Foundation
import FoundationModels

struct CalendarTool: Tool {
    let name = "get_calendar"
    let description = "Upcoming events on the wearer's device calendar."
    let context: AgentDeviceContext

    @Generable
    struct Arguments {
        @Guide(description: "Hours of upcoming events to include. Use 24 if the user did not specify a window.")
        var hoursAhead: Int
    }

    @Generable
    struct Output {
        var summary: String
    }

    func call(arguments: Arguments) async throws -> Output {
        let hours = arguments.hoursAhead == 0 ? 24 : arguments.hoursAhead
        let summary = await context.calendarSummary(hoursAhead: hours)
        return Output(summary: summary)
    }
}
