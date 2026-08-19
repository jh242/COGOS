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
    /// G1 AI rows overflow around 40–43 glyphs. Wrapping at 55 made firmware
    /// re-wrap inside the five-line viewport and clip the last words.
    static let lineWidth = 40
    static let linesPerPage = 5

    struct Frame: Equatable {
        let text: String
        let mode: EvenAIText54.TextMode
    }

    struct Page: Equatable {
        let position: UInt8
        let text: String
        let lines: ArraySlice<String>
    }

    static func frame(for text: String, pageIndex: Int = 0) -> Frame {
        let all = pages(for: text)
        guard !all.isEmpty else {
            return Frame(text: "\n\n", mode: .streaming)
        }
        let index = min(max(0, pageIndex), all.count - 1)
        return Frame(
            text: all[index].text,
            mode: all.count == 1 ? .streaming : .passiveScroll
        )
    }

    static func pages(for text: String) -> [Page] {
        let lines = wrappedLines(text)
        guard !lines.isEmpty else { return [] }

        let starts = Array(stride(from: 0, to: lines.count, by: linesPerPage))
        let byteOffsets = starts.map { byteOffset(forLine: $0, in: lines) }
        let lastOffset = byteOffsets.last ?? 0

        var previousPosition = -1
        return starts.enumerated().map { pageIndex, lineIndex in
            let end = min(lineIndex + linesPerPage, lines.count)
            let slice = lines[lineIndex..<end]
            let padding: LeadingPadding = lineIndex == 0 ? .header : .none
            let pageText = framedBody(slice, leadingPadding: padding)

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
            return Page(position: position, text: pageText, lines: slice)
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
        case header
    }

    private static func framedBody<S: Sequence>(
        _ lines: S,
        leadingPadding: LeadingPadding
    ) -> String where S.Element == String {
        let body = lines.joined(separator: "\n") + "\n"
        switch leadingPadding {
        case .none:
            return body
        case .header:
            return "\n\n" + body
        }
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
            while remainder.count > lineWidth {
                flushCurrent()
                result.append(String(remainder.prefix(lineWidth)))
                remainder = String(remainder.dropFirst(lineWidth))
            }
            guard !remainder.isEmpty else { continue }

            if current.isEmpty {
                current = remainder
            } else if current.count + 1 + remainder.count <= lineWidth {
                current += " " + remainder
            } else {
                flushCurrent()
                current = remainder
            }
        }
        flushCurrent()
        return result
    }
}

/// Owns the complete G1 0x54 reply lifecycle, including the interactive
/// viewer that the phone drives after a long response completes.
@MainActor
final class EvenTextRenderer {
    /// Minimum time the phone keeps a glasses page visible before replacing
    /// it during live Hermes streaming. The app UI still updates immediately.
    private static let minGlassesFrameInterval: Duration = .milliseconds(1200)

    private let proto: Proto
    private var pages: [EvenTextLayout.Page] = []
    private var currentPageIndex = 0
    private var visiblePageIndex = 0
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
            lastSendInstant = try await presentBufferedPages(
                latest,
                lastSentFrame: &lastSentFrame,
                lastSendInstant: lastSendInstant,
                catchUp: true,
                force: false,
                shouldContinue: shouldContinue
            )
        }

        try Task.checkCancellation()
        guard !latest.isEmpty, await shouldContinue() else { return latest }
        _ = try await presentBufferedPages(
            latest,
            lastSentFrame: &lastSentFrame,
            lastSendInstant: lastSendInstant,
            catchUp: true,
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
        visiblePageIndex = 0
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
    private func presentBufferedPages(
        _ text: String,
        lastSentFrame: inout EvenTextLayout.Frame?,
        lastSendInstant: ContinuousClock.Instant?,
        catchUp: Bool,
        force: Bool,
        shouldContinue: () async -> Bool
    ) async throws -> ContinuousClock.Instant? {
        var sendInstant = lastSendInstant
        let pages = EvenTextLayout.pages(for: text)
        guard !pages.isEmpty else { return sendInstant }

        visiblePageIndex = min(visiblePageIndex, pages.count - 1)
        sendInstant = try await sendPage(
            pages[visiblePageIndex],
            totalPages: pages.count,
            lastSentFrame: &lastSentFrame,
            lastSendInstant: sendInstant,
            force: force,
            shouldContinue: shouldContinue
        )

        guard catchUp else { return sendInstant }
        while visiblePageIndex + 1 < pages.count {
            guard await shouldContinue() else { return sendInstant }
            visiblePageIndex += 1
            sendInstant = try await sendPage(
                pages[visiblePageIndex],
                totalPages: pages.count,
                lastSentFrame: &lastSentFrame,
                lastSendInstant: sendInstant,
                force: false,
                shouldContinue: shouldContinue
            )
        }
        return sendInstant
    }

    @discardableResult
    private func sendPage(
        _ page: EvenTextLayout.Page,
        totalPages: Int,
        lastSentFrame: inout EvenTextLayout.Frame?,
        lastSendInstant: ContinuousClock.Instant?,
        force: Bool,
        shouldContinue: () async -> Bool
    ) async throws -> ContinuousClock.Instant? {
        let frame = EvenTextLayout.Frame(
            text: page.text,
            mode: totalPages == 1 ? .streaming : .passiveScroll
        )
        guard frame != lastSentFrame else { return lastSendInstant }

        if !force, let lastSendInstant {
            let elapsed = ContinuousClock.now - lastSendInstant
            if elapsed < Self.minGlassesFrameInterval {
                try await Task.sleep(for: Self.minGlassesFrameInterval - elapsed)
                try Task.checkCancellation()
                guard await shouldContinue() else { return lastSendInstant }
            }
        }

        guard frame != lastSentFrame else { return lastSendInstant }
        guard isDisplayOpen else {
            throw EvenTextRendererError.transportFailed
        }
        guard await proto.sendEvenAIText(frame.text, mode: frame.mode) else {
            throw EvenTextRendererError.transportFailed
        }
        lastSentFrame = frame
        return ContinuousClock.now
    }
}
