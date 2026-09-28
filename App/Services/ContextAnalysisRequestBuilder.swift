import Foundation

struct ContextAnalysisRequestBuilder {
    struct Input: Equatable, Sendable {
        let requestID: UUID
        let subject: ContextAnalysisSubject
        let revision: Int
        let expectedSelectedText: String
        let context: SelectionContext?
        let sourceLanguage: String
        let targetLanguage: String
        let promptVersion: String

        init(requestID: UUID = UUID(), subject: ContextAnalysisSubject, revision: Int,
             expectedSelectedText: String, context: SelectionContext?, sourceLanguage: String,
             targetLanguage: String, promptVersion: String) {
            self.requestID = requestID
            self.subject = subject
            self.revision = revision
            self.expectedSelectedText = expectedSelectedText
            self.context = context
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
            self.promptVersion = promptVersion
        }
    }

    static func build(_ input: Input) throws -> ContextAnalysisRequest {
        guard let context = input.context else { throw ContextAnalysisError.invalidContext }
        guard !input.sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextAnalysisError.invalidLanguage
        }

        let validated = try validatedSelection(in: context.text, range: context.selection)
        guard validated.lengthUTF16 <= ContextAnalysisLimits.maximumSelectionUTF16 else {
            throw ContextAnalysisError.inputTooLarge
        }
        guard ContextAnalysisText.normalized(validated.selectedText) ==
                ContextAnalysisText.normalized(input.expectedSelectedText) else {
            throw ContextAnalysisError.invalidContext
        }

        let fragment = try fragment(
            text: context.text,
            selectionRange: validated.range,
            maximumLengthUTF16: ContextAnalysisLimits.maximumContextUTF16
        )
        return ContextAnalysisRequest(
            requestID: input.requestID,
            subject: input.subject,
            revision: input.revision,
            selectedText: validated.selectedText,
            contextFragment: fragment.text,
            selectionLocationUTF16: fragment.selectionLocationUTF16,
            selectionLengthUTF16: validated.lengthUTF16,
            contextWasReduced: fragment.wasReduced,
            sourceLanguage: input.sourceLanguage,
            targetLanguage: input.targetLanguage,
            promptVersion: input.promptVersion
        )
    }

    static func reducing(_ request: ContextAnalysisRequest,
                         maximumLengthUTF16: Int = ContextAnalysisLimits.retryContextUTF16) throws
        -> ContextAnalysisRequest {
        let range = NSRange(location: request.selectionLocationUTF16,
                            length: request.selectionLengthUTF16)
        let validated = try validatedSelection(in: request.contextFragment, range: range)
        guard validated.selectedText == request.selectedText else {
            throw ContextAnalysisError.invalidContext
        }
        let surroundingLength = request.contextFragment.utf16.count - request.selectionLengthUTF16
        let requestedLimit = min(maximumLengthUTF16,
                                 request.selectionLengthUTF16 + max(0, surroundingLength / 2))
        let fragment = try fragment(text: request.contextFragment, selectionRange: validated.range,
                                    maximumLengthUTF16: requestedLimit)
        return ContextAnalysisRequest(
            requestID: request.requestID,
            subject: request.subject,
            revision: request.revision,
            selectedText: request.selectedText,
            contextFragment: fragment.text,
            selectionLocationUTF16: fragment.selectionLocationUTF16,
            selectionLengthUTF16: request.selectionLengthUTF16,
            contextWasReduced: request.contextWasReduced || fragment.wasReduced,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            promptVersion: request.promptVersion
        )
    }

    private struct ValidatedSelection {
        let range: Range<String.Index>
        let selectedText: String
        let lengthUTF16: Int
    }

    private struct Fragment {
        let text: String
        let selectionLocationUTF16: Int
        let wasReduced: Bool
    }

    private static func validatedSelection(in text: String, range: NSRange) throws -> ValidatedSelection {
        let count = text.utf16.count
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              range.location <= count,
              range.length <= count - range.location,
              let swiftRange = Range(range, in: text),
              isCharacterBoundary(swiftRange.lowerBound, in: text),
              isCharacterBoundary(swiftRange.upperBound, in: text) else {
            throw ContextAnalysisError.invalidContext
        }
        let selected = String(text[swiftRange])
        guard selected.utf16.count == range.length else { throw ContextAnalysisError.invalidContext }
        return ValidatedSelection(range: swiftRange, selectedText: selected, lengthUTF16: range.length)
    }

    private static func isCharacterBoundary(_ index: String.Index, in text: String) -> Bool {
        index == text.endIndex || text.indices.contains(index)
    }

    private static func fragment(text: String, selectionRange: Range<String.Index>,
                                 maximumLengthUTF16: Int) throws -> Fragment {
        let selected = text[selectionRange]
        let selectedLength = selected.utf16.count
        guard maximumLengthUTF16 >= selectedLength else { throw ContextAnalysisError.inputTooLarge }

        let totalLength = text.utf16.count
        guard totalLength > maximumLengthUTF16 else {
            let location = text[..<selectionRange.lowerBound].utf16.count
            return Fragment(text: text, selectionLocationUTF16: location, wasReduced: false)
        }

        let prefix = text[..<selectionRange.lowerBound]
        let suffix = text[selectionRange.upperBound...]
        let surroundingBudget = maximumLengthUTF16 - selectedLength
        var prefixBudget = min(prefix.utf16.count, surroundingBudget / 2)
        var suffixBudget = min(suffix.utf16.count, surroundingBudget - surroundingBudget / 2)
        var unused = surroundingBudget - prefixBudget - suffixBudget

        if unused > 0 {
            let additionalPrefix = min(unused, prefix.utf16.count - prefixBudget)
            prefixBudget += additionalPrefix
            unused -= additionalPrefix
        }
        if unused > 0 {
            suffixBudget += min(unused, suffix.utf16.count - suffixBudget)
        }

        let keptPrefix = suffixWithinUTF16Budget(prefix, budget: prefixBudget)
        let keptSuffix = prefixWithinUTF16Budget(suffix, budget: suffixBudget)
        let reduced = String(keptPrefix) + String(selected) + String(keptSuffix)
        let newRange = NSRange(location: keptPrefix.utf16.count, length: selectedLength)
        _ = try validatedSelection(in: reduced, range: newRange)
        guard reduced.utf16.count <= maximumLengthUTF16 else {
            throw ContextAnalysisError.inputTooLarge
        }
        return Fragment(text: reduced, selectionLocationUTF16: newRange.location, wasReduced: true)
    }

    private static func prefixWithinUTF16Budget(_ text: Substring, budget: Int) -> Substring {
        guard budget > 0, !text.isEmpty else { return text[text.startIndex..<text.startIndex] }
        var end = text.startIndex
        var used = 0
        for index in text.indices {
            let next = text.index(after: index)
            let length = text[index..<next].utf16.count
            guard used + length <= budget else { break }
            used += length
            end = next
        }
        return text[..<end]
    }

    private static func suffixWithinUTF16Budget(_ text: Substring, budget: Int) -> Substring {
        guard budget > 0, !text.isEmpty else { return text[text.endIndex..<text.endIndex] }
        var start = text.endIndex
        var used = 0
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            let length = text[previous..<index].utf16.count
            guard used + length <= budget else { break }
            used += length
            start = previous
            index = previous
        }
        return text[start...]
    }
}
