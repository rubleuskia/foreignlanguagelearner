import SwiftUI
import PDFKit
import UIKit

@MainActor enum ExamSourcePageRenderer {
    static func thumbnail(url: URL, page: Int) -> UIImage? {
        guard url.isFileURL, page > 0 else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        guard let file = components?.url, let document = PDFDocument(url: file),
              page <= document.pageCount, let original = document.page(at: page - 1) else { return nil }
        return original.thumbnail(of: CGSize(width: 900, height: 1280), for: .mediaBox)
    }
}

private struct ExamSourcePageImage: View {
    let url: URL
    let page: Int
    let label: String
    @State private var image: UIImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(label) }
            else if !finished { ProgressView() }
            else { Text(AppLanguage.text("Open original exam page")).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: "\(url.absoluteString)|\(page)") {
            image = ExamSourcePageRenderer.thumbnail(url: url, page: page)
            finished = true
        }
    }
}

@MainActor
struct ExamTaskView: View {
    @ObservedObject var store: ExamStore
    @ObservedObject var audio: ExamAudioController
    let task: ExamTask

    private var layout: String { task.presentation?.layout ?? (task.interactionType == "true_false" ? "true_false_table" : "question_list") }
    private var visibleBlocks: [ExamBlock] { task.blocks.filter { !(task.presentation?.suppressExampleBlocks == true && $0.type == "example") } }

    var body: some View {
        ExamSurface {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .top) {
                    Text(task.label).font(.system(.title2, design: .serif)).frame(minWidth: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title ?? "Zadanie \(task.label)").font(.headline)
                        Text(AppLanguage.format("%@ points", ExamDisplay.points(task.maxScoreUnits))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    sourceLink(task.sourceRefs)
                }
                Text(task.instruction).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                if store.currentAttempt?.mode == .training, store.currentAttempt?.sectionID == "listening",
                   let range = store.audioWindow(for: task.id) {
                    ExamTrainingTransport(title: "Zadanie \(task.label)", playing: audio.isPlaying && audio.activeTaskID == task.id,
                                          position: audioPosition(range), range: range) {
                        if audio.isPlaying && audio.activeTaskID == task.id { audio.pause() }
                        else { Task { await store.playTask(task.id) } }
                    }
                }
                taskBody
                if !itemResults.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(itemResults, id: \.itemID) { result in
                            HStack(spacing: 9) {
                                Image(systemName: resultIcon(result.status)).foregroundStyle(resultColor(result.status))
                                Text(task.items.first(where: { $0.id == result.itemID })?.label ?? "")
                                    .font(.caption.weight(.semibold)).frame(minWidth: 18, alignment: .leading)
                                Text(AppLanguage.text(resultTitle(result.status))).font(.caption)
                                Spacer()
                                if let awarded = result.awardedScoreUnits {
                                    Text("\(ExamDisplay.points(awarded)) / \(ExamDisplay.points(result.maxScoreUnits))")
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("exam.feedback.\(result.itemID)")
                        }
                    }
                }
                if let assessment = store.currentAttempt?.aiResults?[task.id] {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(AppLanguage.text("AI assessment"), systemImage: "sparkles").font(.headline)
                        Text("\(ExamDisplay.points(assessment.scoreUnits)) / \(ExamDisplay.points(assessmentMaximum))")
                            .font(.title3.weight(.semibold)).monospacedDigit()
                        Text(assessment.rationale).font(.subheadline).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        .accessibilityIdentifier("exam.task.\(task.id)")
    }

    private var itemResults: [ExamItemResult] {
        let ids = Set(task.items.map(\.id))
        return store.currentAttempt?.result?.sections.flatMap(\.items).filter { ids.contains($0.itemID) } ?? []
    }
    private var assessmentMaximum: Int {
        let pending = itemResults.filter { ["pending_ai", "assessed_at_task_level"].contains($0.status) }
        return pending.isEmpty ? task.maxScoreUnits : pending.reduce(0) { $0 + $1.maxScoreUnits }
    }
    private func resultTitle(_ status: String) -> String {
        switch status {
        case "correct": "Correct"
        case "partial": "Partly correct"
        case "incorrect": "Incorrect"
        case "assessed_at_task_level": "Assessed with the task"
        default: "Waiting for assessment"
        }
    }
    private func resultIcon(_ status: String) -> String {
        switch status {
        case "correct": "checkmark.circle.fill"
        case "partial": "circle.lefthalf.filled"
        case "incorrect": "xmark.circle.fill"
        case "assessed_at_task_level": "sparkles"
        default: "clock"
        }
    }
    private func resultColor(_ status: String) -> Color {
        switch status {
        case "correct": .green
        case "partial": .orange
        case "incorrect": .red
        default: .secondary
        }
    }

    @ViewBuilder private var taskBody: some View {
        switch layout {
        case "true_false_table":
            ForEach(task.blocks.filter { $0.type != "example" }) { block in blockView(block) }
            ExamTrueFalseGrid(options: choices(task.options), rows: trueFalseRows, disabled: !store.canEdit) { itemID, value in store.setAnswer(itemID: itemID, value: value) }
        case "token_table":
            ForEach(task.blocks.filter { $0.type != "example" }) { block in blockView(block) }
            if !task.options.isEmpty { optionBank }
            tokenTable
        case "matching_table": matchingTable
        case "source_form":
            ForEach(visibleBlocks) { block in blockView(block) }
            sourceForm
        case "inline_choices", "inline_bank", "inline_text":
            if layout == "inline_bank", task.presentation?.bankPosition != "after_text" { optionBank }
            ForEach(visibleBlocks) { block in blockView(block) }
            if layout == "inline_bank", task.presentation?.bankPosition == "after_text" { optionBank }
            let covered = Set(visibleBlocks.flatMap { ExamInlinePiece.parse($0.text).compactMap { piece -> String? in if case .field(let id) = piece.kind { id } else { nil } } })
            ForEach(task.items.filter { !covered.contains($0.id) }) { item in question(item) }
        default:
            ForEach(visibleBlocks) { block in blockView(block) }
            ForEach(task.items) { item in question(item) }
        }
    }

    private func choices(_ options: [ExamOption]) -> [ExamChoiceDisplay] { options.map { ExamChoiceDisplay(id: $0.id, label: $0.label, text: $0.text) } }
    private func binding(_ itemID: String) -> Binding<String> {
        Binding(get: { store.answer(for: itemID) }, set: { store.setAnswer(itemID: itemID, value: $0) })
    }
    private func audioPosition(_ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { audio.activeTaskID == task.id ? min(max(audio.position, range.lowerBound), range.upperBound) : range.lowerBound },
                set: { value in Task { await store.seekTask(task.id, seconds: value) } })
    }
    @ViewBuilder private func sourceLink(_ refs: [ExamSourceReference]) -> some View {
        if let ref = refs.first(where: { $0.sourceID != "keys" }), let url = store.sourceURL(ref) {
            Link(destination: url) { Label(ref.page.map { "PDF · \($0)" } ?? "PDF", systemImage: "arrow.up.right") }
                .font(.caption2).accessibilityLabel(AppLanguage.text("Open original exam page"))
        }
    }
    private var trueFalseRows: [ExamTrueFalseRow] {
        var rows: [ExamTrueFalseRow] = []
        if let example = task.blocks.first(where: { $0.type == "example" }) {
            let selected = task.options.first { $0.label == example.answer || $0.text == example.answer }?.id ?? ""
            rows.append(ExamTrueFalseRow(id: example.id, label: "PRZYKŁAD", text: example.text, selectedID: selected, isExample: true))
        }
        rows += task.items.map { ExamTrueFalseRow(id: $0.id, label: $0.label, text: $0.prompt, selectedID: store.answer(for: $0.id)) }
        return rows
    }

    @ViewBuilder private func blockView(_ block: ExamBlock) -> some View {
        if block.type == "image" {
            if let ref = block.sourceRefs.first(where: { $0.sourceID == "paper" && $0.page != nil }),
               let url = store.sourceURL(ref), let page = ref.page {
                ExamSourcePageImage(url: url, page: page, label: block.text)
            }
            sourceLink(block.sourceRefs)
        } else if block.type == "heading" { Text(block.text).font(.system(.title3, design: .serif)).fontWeight(.semibold) }
        else if block.role == "attribution" { Text(block.text).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
        else if block.type == "example" {
            VStack(alignment: .leading, spacing: 7) {
                Text("PRZYKŁAD").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ExamPaperText(text: block.text, underlined: block.underlinedText)
                if let answer = block.answer { Text("Odpowiedź: \(answer)").font(.caption).foregroundStyle(.secondary) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        } else if block.text.contains("{{") || block.text.contains("[PRZYKŁAD:") { inlineText(block.text) }
        else { ExamPaperText(text: block.text, underlined: block.underlinedText) }
    }

    private enum RenderKind {
        case word(String), field(String), choice(String, ExamChoiceDisplay), example(String), lineBreak
    }
    private struct RenderPiece: Identifiable { let id: Int; let kind: RenderKind }
    private func renderPieces(_ text: String) -> [RenderPiece] {
        var result: [RenderPiece] = []
        func append(_ kind: RenderKind) { result.append(RenderPiece(id: result.count, kind: kind)) }
        for piece in ExamInlinePiece.parse(text) {
            switch piece.kind {
            case .word(let value): append(.word(value))
            case .lineBreak: append(.lineBreak)
            case .example(let value): append(.example(value))
            case .field(let id):
                if layout == "inline_choices", let item = task.items.first(where: { $0.id == id }) {
                    append(.word("\(item.label)("))
                    let options = task.options.filter { item.optionIDs.contains($0.id) }
                    for (index, option) in options.enumerated() {
                        append(.choice(item.id, ExamChoiceDisplay(id: option.id, label: option.label, text: option.text)))
                        if index < options.count - 1 { append(.word(",")) }
                    }
                    append(.word(")"))
                } else { append(.field(id)) }
            }
        }
        return result
    }
    private func inlineText(_ text: String) -> some View {
        ExamInlineFlow {
            ForEach(renderPieces(text)) { piece in
                switch piece.kind {
                case .word(let word): Text(word).font(.system(.body, design: .serif))
                case .lineBreak: ExamFlowBreak()
                case .example(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(value).font(.system(.body, design: .serif)).padding(.horizontal, value.count == 1 ? 10 : 0)
                            .background(value.count == 1 ? Color.secondary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        Text("przykład").font(.caption2).foregroundStyle(.secondary)
                    }
                case .choice(let itemID, let option):
                    ExamWordChoice(option: option, selected: store.answer(for: itemID) == option.id, disabled: !store.canEdit) { store.setAnswer(itemID: itemID, value: option.id) }
                case .field(let itemID):
                    if let item = task.items.first(where: { $0.id == itemID }) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(item.label).font(.caption2).foregroundStyle(.secondary)
                            ExamAnswerInput(label: "\(task.label). \(item.label)", value: binding(itemID),
                                            compact: ["letter", "number"].contains(task.presentation?.inputFormat ?? ""),
                                            disabled: !store.canEdit, identifier: "exam.answer.\(itemID)")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var optionBank: some View {
        let examples = Set(task.presentation?.exampleOptionIDs ?? [])
        if task.presentation?.optionBank == "table" {
            VStack(spacing: 0) {
                ForEach(task.options) { option in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 3) {
                            Text(task.presentation?.displayCodes?[option.id] ?? option.label).font(.caption.weight(.semibold))
                            if examples.contains(option.id) { Text("Przykład").font(.system(size: 9)).foregroundStyle(.secondary) }
                        }.frame(width: 48)
                        ExamPaperText(text: option.text).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(11).background(examples.contains(option.id) ? Color.secondary.opacity(0.07) : .clear)
                    Divider()
                }
            }.overlay { RoundedRectangle(cornerRadius: 7).stroke(.quaternary) }
        } else {
            ExamInlineFlow(spacing: 15, lineSpacing: 8) {
                ForEach(task.options) { option in Text(option.text).font(.system(.body, design: .serif)) }
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var tokenTable: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                tableCell { Text(task.presentation?.promptHeader ?? "Opinia").font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading) }
                tableCell { Text(task.presentation?.answerHeader ?? "O tym mówi").font(.caption.weight(.semibold)).frame(width: 115) }
            }.background(Color.secondary.opacity(0.07))
            if let example = task.blocks.first(where: { $0.type == "example" }) {
                GridRow {
                    tableCell { VStack(alignment: .leading) { Text("PRZYKŁAD").font(.caption2); ExamPaperText(text: example.text) } }
                    tableCell { Text(example.answer ?? "").font(.system(.body, design: .serif)).frame(width: 115) }
                }.foregroundStyle(.secondary).background(Color.secondary.opacity(0.05))
            }
            ForEach(task.items) { item in
                GridRow {
                    tableCell { Text("\(item.label). \(item.prompt)").font(.system(.body, design: .serif)).frame(maxWidth: .infinity, alignment: .leading) }
                    tableCell {
                        VStack(spacing: 4) {
                            ExamAnswerInput(label: "Odpowiedź: \(item.label)", value: binding(item.id), disabled: !store.canEdit, identifier: "exam.answer.\(item.id)")
                            if let count = item.input?.object?["slot_count"]?.int { Text("\(count) odpowiedzi").font(.caption2).foregroundStyle(.secondary) }
                        }.frame(width: 115)
                    }
                }
            }
        }
    }

    private var matchingTable: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(visibleBlocks.filter { $0.type == "heading" }) { block in blockView(block) }
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { tableCell { Text("I").frame(width: 180) }.gridCellColumns(2); tableCell { Text("II").frame(width: 260) }.gridCellColumns(2) }
                    ForEach(Array((task.presentation?.rows ?? []).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            tableCell { Text(row.label ?? "").font(.caption2).frame(width: 30) }
                            tableCell { ExamPaperText(text: row.left ?? "").frame(width: 150, alignment: .leading) }
                            tableCell { Text(row.rightLabel ?? "").font(.caption.weight(.semibold)).frame(width: 25) }
                            tableCell { ExamPaperText(text: row.right ?? "").frame(width: 250, alignment: .leading) }
                        }
                    }
                }
            }
            Text(task.presentation?.inputFormat == "letter" ? "Wpisz litery odpowiedzi" : "Wpisz numery odpowiedzi").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 9) { Text("PRZYKŁAD").font(.caption2); Text(task.presentation?.exampleAnswer ?? "").frame(height: 35) }.frame(width: 75).foregroundStyle(.secondary)
                    ForEach(task.items) { item in
                        VStack(spacing: 9) {
                            Text(item.label).font(.caption.weight(.semibold))
                            ExamAnswerInput(label: "Odpowiedź \(item.label)", value: binding(item.id), compact: true, disabled: !store.canEdit, identifier: "exam.answer.\(item.id)")
                        }.frame(width: 60)
                    }
                }
            }
        }
    }

    private var sourceForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array((task.presentation?.rows ?? []).enumerated()), id: \.offset) { _, row in
                if let itemID = row.itemID, let item = task.items.first(where: { $0.id == itemID }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(row.label ?? item.label).").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ExamPaperText(text: row.statement ?? "", underlined: row.underlinedText)
                        if let word = row.requiredWord { Text("(\(word))").font(.system(.body, design: .serif)).foregroundStyle(.secondary) }
                        if let template = row.questionTemplate { inlineText(template) }
                        else {
                            TextField("…", text: binding(itemID), axis: .vertical)
                                .font(.system(.body, design: .serif)).textFieldStyle(.roundedBorder)
                                .lineLimit(2...5).autocorrectionDisabled().disabled(!store.canEdit)
                                .accessibilityLabel("\(task.label). \(item.label)")
                                .accessibilityIdentifier("exam.answer.\(itemID)")
                        }
                        if let answer = row.answerLine { ExamPaperText(text: answer) }
                    }
                    Divider()
                }
            }
        }
    }

    private func question(_ item: ExamItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if let context = item.context { ExamPaperText(text: context, underlined: item.underlinedText) }
            HStack(alignment: .firstTextBaseline) {
                Text("\(item.label).").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ExamPaperText(text: item.prompt, underlined: item.underlinedText).frame(maxWidth: .infinity, alignment: .leading)
            }
            if item.responseType == "single_choice" {
                ForEach(task.options.filter { item.optionIDs.contains($0.id) }) { option in
                    ExamObjectiveChoice(option: ExamChoiceDisplay(id: option.id, label: option.label, text: option.text),
                                        selected: store.answer(for: item.id) == option.id, disabled: !store.canEdit) {
                        store.setAnswer(itemID: item.id, value: option.id)
                    }
                }
            } else {
                ExamAnswerInput(label: "\(task.label). \(item.label)", value: binding(item.id), disabled: !store.canEdit, identifier: "exam.answer.\(item.id)")
            }
        }.padding(.vertical, 8)
    }
    private func tableCell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(9).frame(maxHeight: .infinity).overlay { Rectangle().stroke(.quaternary, lineWidth: 0.5) }
    }
}
