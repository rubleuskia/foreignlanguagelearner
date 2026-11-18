import SwiftUI

struct ExamChoiceDisplay: Identifiable {
    let id: String
    let label: String
    let text: String
}

struct ExamAnswerInput: View {
    let label: String
    @Binding var value: String
    var compact = false
    var disabled = false
    var identifier: String?
    var body: some View {
        TextField("…", text: $value, axis: .horizontal)
            .font(.system(.body, design: .serif))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: compact ? 48 : 90, idealWidth: compact ? 58 : 140, maxWidth: compact ? 82 : 230)
            .disabled(disabled).accessibilityLabel(label)
            .accessibilityIdentifier(identifier ?? label)
    }
}

struct ExamWordChoice: View {
    let option: ExamChoiceDisplay
    let selected: Bool
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(option.text).fontWeight(selected ? .bold : .regular).underline(selected)
                .font(.system(.body, design: .serif)).foregroundStyle(.primary)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityLabel(option.text)
        .accessibilityValue(AppLanguage.text(selected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("exam.option.\(option.id)")
    }
}

struct ExamObjectiveChoice: View {
    let option: ExamChoiceDisplay
    let selected: Bool
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(option.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(option.text).font(.system(.body, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).background(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("exam.option.\(option.id)")
    }
}

struct ExamTrueFalseRow: Identifiable {
    let id: String
    let label: String
    let text: String
    let selectedID: String
    var isExample = false
}

struct ExamTrueFalseGrid: View {
    let options: [ExamChoiceDisplay]
    let rows: [ExamTrueFalseRow]
    let disabled: Bool
    let select: (String, String) -> Void
    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                cell { Text("Zdanie").font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(options) { option in cell { Text(option.label).font(.caption.weight(.semibold)).frame(width: 44) } }
            }.background(Color.secondary.opacity(0.08))
            ForEach(rows) { row in
                GridRow {
                    cell {
                        VStack(alignment: .leading, spacing: 5) {
                            if row.isExample { Text("PRZYKŁAD").font(.caption2).foregroundStyle(.secondary) }
                            Text(row.isExample ? row.text : "\(row.label). \(row.text)")
                                .font(.system(.body, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(options) { option in
                        cell {
                            Button { select(row.id, option.id) } label: {
                                Image(systemName: row.selectedID == option.id ? "xmark.square.fill" : "square")
                                    .font(.title3).frame(width: 44, height: 44)
                                    .foregroundStyle(row.isExample ? Color.secondary : Color.accentColor)
                            }.buttonStyle(.plain).disabled(disabled || row.isExample)
                                .accessibilityLabel("\(row.label). \(row.text): \(option.label)")
                                .accessibilityValue(row.selectedID == option.id ? "Selected" : "Not selected")
                                .accessibilityIdentifier("exam.table.\(row.id).\(option.label)")
                        }
                    }
                }.background(row.isExample ? Color.secondary.opacity(0.06) : .clear)
            }
        }
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
    }
    private func cell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(8).frame(maxHeight: .infinity)
            .overlay { Rectangle().stroke(.quaternary, lineWidth: 0.5) }
    }
}

struct ExamTrainingTransport: View {
    let title: String
    let playing: Bool
    @Binding var position: Double
    let range: ClosedRange<Double>
    let toggle: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: toggle) { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 42, height: 42) }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .accessibilityLabel(AppLanguage.text(playing ? "Pause recording" : "Play recording"))
                Slider(value: $position, in: range).accessibilityLabel(AppLanguage.text("Recording position"))
            }
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(ExamDisplay.clock(position - range.lowerBound)) / \(ExamDisplay.clock(range.upperBound - range.lowerBound))")
                    .monospacedDigit().font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12).background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ExamLockedTransport: View {
    let position: Double
    let duration: Double
    let started: Bool
    let finished: Bool
    let playing: Bool
    let resume: () -> Void
    var body: some View {
        ExamSurface {
            VStack(alignment: .leading, spacing: 12) {
                Label(AppLanguage.text("Original recording"), systemImage: "headphones").font(.headline)
                ProgressView(value: min(max(0, position), max(duration, 1)), total: max(duration, 1))
                    .accessibilityLabel(AppLanguage.text("Recording progress"))
                Text("\(ExamDisplay.clock(position)) / \(ExamDisplay.clock(duration))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if finished { Label(AppLanguage.text("Recording completed"), systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                else if !playing { Button(AppLanguage.text(started ? "Continue recording" : "Start recording"), action: resume).buttonStyle(.borderedProminent) }
                Text(AppLanguage.text("The original plays once without pause or seeking. Its repeats are already included. After a system interruption, continue from the saved position."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ExamScoreSummary: View {
    let objective: Int
    let objectiveMaximum: Int
    let pendingMaximum: Int
    let overallMaximum: Int
    let total: Int?
    var body: some View {
        ExamSurface {
            VStack(alignment: .leading, spacing: 9) {
                Label(AppLanguage.text(total == nil ? "Partial result" : "Result"), systemImage: total == nil ? "clock" : "checkmark.seal")
                    .font(.headline)
                if let total {
                    Text("\(ExamDisplay.points(total)) / \(ExamDisplay.points(overallMaximum))")
                        .font(.largeTitle.weight(.semibold)).monospacedDigit()
                } else if objectiveMaximum > 0 {
                    Text("\(ExamDisplay.points(objective)) / \(ExamDisplay.points(objectiveMaximum))")
                        .font(.largeTitle.weight(.semibold)).monospacedDigit()
                    Text(AppLanguage.text("Points checked automatically")).font(.caption).foregroundStyle(.secondary)
                } else { Text("—").font(.largeTitle) }
                if total == nil {
                    Text(AppLanguage.text("The overall result is waiting for AI assessment.")).font(.subheadline)
                    if pendingMaximum > 0 { Text(AppLanguage.format("Up to %@ points require assessment.", ExamDisplay.points(pendingMaximum))).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
