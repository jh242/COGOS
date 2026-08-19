import Foundation

enum EvenTextRendererError: Error, LocalizedError {
    case prepareFailed
    case transportFailed

    var errorDescription: String? {
        switch self {
        case .prepareFailed:
            return "Glasses did not acknowledge the reply."
        case .transportFailed:
            return "The reply could not be sent to the glasses."
        }
    }
}

/// Pure layout used by both live rendering and interactive navigation.
struct EvenTextLayout {
    static let lineWidth = 55
    static let linesPerPage = 5

    struct Frame: Equatable {
        let text: String
        let mode: EvenAIText54.TextMode
    }

    struct Page: Equatable {
        let position: UInt8
        let text: String
    }

    static func frame(for text: String) -> Frame {
        let lines = wrappedLines(text)
        if lines.count <= linesPerPage {
            return Frame(
                text: framedBody(lines[...], leadingPadding: .streamingHeader),
                mode: .streaming
            )
        }

        let window = lines[(lines.count - linesPerPage)..<lines.count]
        return Frame(
            text: framedBody(window, leadingPadding: .none),
            mode: .passiveScroll
        )
    }

    static func pages(for text: String) -> [Page] {
        let lines = wrappedLines(text)
        guard lines.count > linesPerPage else { return [] }

        let starts = pageStarts(lineCount: lines.count)
        let byteOffsets = starts.map { byteOffset(forLine: $0, in: lines) }
        let lastOffset = byteOffsets.last ?? 0

        var previousPosition = -1
        return starts.enumerated().map { pageIndex, lineIndex in
            let end = min(lineIndex + linesPerPage, lines.count)
            let padding: LeadingPadding = lineIndex == 0 ? .interactiveFirstPage : .none
            let pageText = framedBody(lines[lineIndex..<end], leadingPadding: padding)

            var position: UInt8
            if lastOffset == 0 {
                position = 0
            } else {
                position = UInt8(min(90, (byteOffsets[pageIndex] * 90) / lastOffset))
            }
            if Int(position) <= previousPosition {
                position = UInt8(min(90, previousPosition + 1))
            }
            previousPosition = Int(position)
            return Page(position: position, text: pageText)
        }
    }

    static func wrappedLines(_ text: String) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        return normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { wrap(line: String($0)) }
    }

    private enum LeadingPadding {
        case none
        case streamingHeader
        case interactiveFirstPage
    }

    private static func framedBody<S: Sequence>(
        _ lines: S,
        leadingPadding: LeadingPadding
    ) -> String where S.Element == String {
        let body = lines.joined(separator: "\n") + "\n"
        switch leadingPadding {
        case .none:
            return body
        case .streamingHeader, .interactiveFirstPage:
            return "\n\n" + body
        }
    }

    private static func pageStarts(lineCount: Int) -> [Int] {
        let finalWindowStart = max(0, lineCount - linesPerPage)
        var starts: [Int] = []
        var start = 0
        while start < finalWindowStart {
            starts.append(start)
            start += linesPerPage
        }
        if starts.last != finalWindowStart {
            starts.append(finalWindowStart)
        }
        return starts
    }

    private static func byteOffset(forLine lineIndex: Int, in lines: [String]) -> Int {
        lines[..<lineIndex].reduce(0) { total, line in
            total + line.utf8.count + 1
        }
    }

    private static func wrap(line: String) -> [String] {
        let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [""] }

        var result: [String] = []
        var current = ""

        func flushCurrent() {
            if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }

        for word in words {
            var remainder = word
            while utf8ByteCount(remainder) > lineWidth {
                flushCurrent()
                let chunk = utf8Prefix(remainder, maxBytes: lineWidth)
                guard !chunk.isEmpty else { break }
                result.append(chunk)
                remainder = String(remainder.dropFirst(chunk.count))
            }
            guard !remainder.isEmpty else { continue }

            if current.isEmpty {
                current = remainder
            } else if utf8ByteCount(current) + 1 + utf8ByteCount(remainder) <= lineWidth {
                current += " " + remainder
            } else {
                flushCurrent()
                current = remainder
            }
        }
        flushCurrent()
        return result
    }

    private static func utf8ByteCount(_ string: String) -> Int {
        string.utf8.count
    }

    private static func utf8Prefix(_ string: String, maxBytes: Int) -> String {
        let data = Data(string.utf8)
        if data.count <= maxBytes { return string }
        var end = maxBytes
        while end > 0 && (data[end] & 0xC0) == 0x80 {
            end -= 1
        }
        return String(decoding: data.prefix(end), as: UTF8.self)
    }
}

/// Owns the complete G1 0x54 reply lifecycle, including the interactive
/// viewer that the phone drives after a long response completes.
@MainActor
final class EvenTextRenderer {
    /// Minimum time the phone keeps a glasses frame visible before replacing
    /// it during live Hermes streaming. The app UI still updates immediately.
    private static let minGlassesFrameInterval: Duration = .milliseconds(1200)

    private let proto: Proto
    private var pages: [EvenTextLayout.Page] = []
    private var currentPageIndex = 0
    private var isDisplayOpen = false
    private var isNavigating = false

    private(set) var isScrollViewerActive = false
    var isViewerActive: Bool { isDisplayOpen }

    init(proto: Proto) {
        self.proto = proto
    }

    func streamAndDisplay(
        _ snapshots: AsyncThrowingStream<String, Error>,
        onSnapshot: @escaping (String) -> Void = { _ in },
        shouldContinue: @escaping () async -> Bool
    ) async throws -> String {
        try await beginReply()

        var latest = ""
        var lastSentFrame: EvenTextLayout.Frame?
        var lastSendInstant: ContinuousClock.Instant?

        for try await snapshot in snapshots {
            try Task.checkCancellation()
            guard await shouldContinue() else { return latest }
            latest = snapshot
            onSnapshot(snapshot)
            lastSendInstant = try await sendLatestGlassesFrame(
                latest: latest,
                lastSentFrame: &lastSentFrame,
                lastSendInstant: lastSendInstant,
                force: false,
                shouldContinue: shouldContinue
            )
        }

        try Task.checkCancellation()
        guard !latest.isEmpty, await shouldContinue() else { return latest }
        _ = try await sendLatestGlassesFrame(
            latest: latest,
            lastSentFrame: &lastSentFrame,
            lastSendInstant: lastSendInstant,
            force: true,
            shouldContinue: shouldContinue
        )
        try await finishReply(latest)
        return latest
    }

    func pushReply(
        _ text: String,
        shouldContinue: @escaping () async -> Bool
    ) async -> Bool {
        do {
            try await beginReply()
            guard !Task.isCancelled, await shouldContinue() else { return false }
            let frame = EvenTextLayout.frame(for: text)
            guard await proto.sendEvenAIText(frame.text, mode: frame.mode),
                  !Task.isCancelled,
                  await shouldContinue() else { return false }
            try await finishReply(text)
            return true
        } catch {
            return false
        }
    }

    func navigate(arm: String) async {
        guard isScrollViewerActive, !pages.isEmpty, !isNavigating else { return }
        let previousIndex = currentPageIndex
        let nextIndex: Int
        if arm == "L" {
            nextIndex = max(0, currentPageIndex - 1)
        } else {
            nextIndex = min(pages.count - 1, currentPageIndex + 1)
        }
        guard nextIndex != currentPageIndex else { return }

        currentPageIndex = nextIndex
        let page = pages[nextIndex]
        isNavigating = true
        let sent = await proto.sendEvenAIText(
            page.text,
            mode: .interactive(position: page.position)
        )
        isNavigating = false
        if !sent, isScrollViewerActive, currentPageIndex == nextIndex {
            currentPageIndex = previousIndex
        }
    }

    func exitViewer() async {
        guard isViewerActive else { return }
        await reset()
    }

    func reset() async {
        let shouldClose = isDisplayOpen
        isDisplayOpen = false
        isScrollViewerActive = false
        isNavigating = false
        pages = []
        currentPageIndex = 0
        if shouldClose {
            _ = await proto.sendEvenAIClose()
        }
    }

    private func beginReply() async throws {
        await reset()
        guard await proto.sendEvenAITextPrepare() else {
            throw EvenTextRendererError.prepareFailed
        }
        isDisplayOpen = true
    }

    private func finishReply(_ text: String) async throws {
        let replyPages = EvenTextLayout.pages(for: text)
        guard replyPages.count > 1 else {
            // OEM keeps a short final answer visible. Closing here makes the
            // last update disappear as soon as response.completed follows it.
            return
        }

        pages = replyPages
        currentPageIndex = replyPages.count - 1
        guard await proto.sendEvenAIText(
            replyPages[currentPageIndex].text,
            mode: .interactive(position: 100)
        ) else {
            throw EvenTextRendererError.transportFailed
        }
        isScrollViewerActive = true
    }

    @discardableResult
    private func sendLatestGlassesFrame(
        latest: String,
        lastSentFrame: inout EvenTextLayout.Frame?,
        lastSendInstant: ContinuousClock.Instant?,
        force: Bool,
        shouldContinue: () async -> Bool
    ) async throws -> ContinuousClock.Instant? {
        let frame = EvenTextLayout.frame(for: latest)
        guard frame != lastSentFrame else { return lastSendInstant }

        if !force, let lastSendInstant {
            let elapsed = ContinuousClock.now - lastSendInstant
            if elapsed < Self.minGlassesFrameInterval {
                try await Task.sleep(for: Self.minGlassesFrameInterval - elapsed)
                try Task.checkCancellation()
                guard await shouldContinue() else { return lastSendInstant }
            }
        }

        let refreshed = EvenTextLayout.frame(for: latest)
        guard refreshed != lastSentFrame else { return lastSendInstant }
        guard isDisplayOpen else {
            throw EvenTextRendererError.transportFailed
        }
        guard await proto.sendEvenAIText(refreshed.text, mode: refreshed.mode) else {
            throw EvenTextRendererError.transportFailed
        }
        lastSentFrame = refreshed
        return ContinuousClock.now
    }
}
