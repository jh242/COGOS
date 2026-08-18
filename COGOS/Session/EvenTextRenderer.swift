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
                text: "\n\n" + lines.joined(separator: "\n") + "\n",
                mode: .streaming
            )
        }

        return Frame(
            text: Array(lines.suffix(linesPerPage)).joined(separator: "\n") + "\n",
            mode: .passiveScroll
        )
    }

    static func pages(for text: String) -> [Page] {
        let lines = wrappedLines(text)
        guard !lines.isEmpty else { return [] }

        let finalWindowStart = max(0, lines.count - linesPerPage)
        var starts = Array(stride(from: 0, through: finalWindowStart, by: linesPerPage))
        if finalWindowStart > 0 {
            if starts.last != finalWindowStart {
                starts.append(finalWindowStart)
            }
        }

        let byteOffsets = starts.map { lineIndex -> Int in
            lines[..<lineIndex].reduce(0) { total, line in
                total + line.utf8.count + 1
            }
        }
        let lastOffset = byteOffsets.last ?? 0

        return starts.enumerated().map { pageIndex, lineIndex in
            let end = min(lineIndex + linesPerPage, lines.count)
            var pageText = lines[lineIndex..<end].joined(separator: "\n") + "\n"
            if pageIndex == 0 { pageText = "\n" + pageText }

            // The OEM viewer reserves 100 for its final entry packet. User
            // navigation occupies 0...90, normalized by UTF-8 scroll offset.
            let position: UInt8
            if lastOffset == 0 {
                position = 0
            } else {
                position = UInt8(min(90, (byteOffsets[pageIndex] * 90) / lastOffset))
            }
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
    private let proto: Proto
    private var pages: [EvenTextLayout.Page] = []
    private var currentPageIndex = 0
    private var isDisplayOpen = false
    private var isNavigating = false

    private(set) var isScrollViewerActive = false

    init(proto: Proto) {
        self.proto = proto
    }

    func streamAndDisplay(
        _ snapshots: AsyncThrowingStream<String, Error>,
        shouldContinue: @escaping () async -> Bool
    ) async throws -> String {
        try await beginReply()

        var latest = ""
        var lastFrame: EvenTextLayout.Frame?
        for try await snapshot in snapshots {
            try Task.checkCancellation()
            guard await shouldContinue() else { return latest }
            latest = snapshot
            let frame = EvenTextLayout.frame(for: snapshot)
            if frame != lastFrame {
                guard await proto.sendEvenAIText(frame.text, mode: frame.mode) else {
                    throw EvenTextRendererError.transportFailed
                }
                lastFrame = frame
            }
        }

        try Task.checkCancellation()
        guard !latest.isEmpty, await shouldContinue() else { return latest }
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

    func exitScrollViewer() async {
        guard isScrollViewerActive else { return }
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
            guard await proto.sendEvenAIClose() else {
                throw EvenTextRendererError.transportFailed
            }
            isDisplayOpen = false
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
}
