import Foundation

/// Host-side contract check using the actual iOS Codable models, without a simulator.
@main struct ExamModelProbe {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func bytes(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: root[key]!) }
        let catalog = try ExamJSON.decoder().decode(ExamCatalogEnvelope.self, from: bytes("catalog"))
        let envelope = try ExamJSON.decoder().decode(ExamPackageEnvelope.self, from: bytes("package"))
        let attempt = try ExamJSON.decoder().decode(ExamAttempt.self, from: bytes("attempt"))
        let package = envelope.exam
        precondition(catalog.exams.count == 1)
        precondition(package.interactiveSections.count == 3)
        let count = package.interactiveSections.flatMap(\.tasks).flatMap(\.items).count
        precondition(count == 125)
        precondition(envelope.audio?.tasks.count == 5)
        precondition(attempt.responses["grammar-V-1"] == .text("Komu?"))
        precondition(attempt.submittedSectionIDs == ["grammar"])
        precondition(attempt.result != nil)
        let roundTrip = try ExamJSON.decoder().decode(ExamAttempt.self, from: ExamJSON.encoder().encode(attempt))
        precondition(roundTrip.responses == attempt.responses)
        print("PASS native Codable: \(count) fields, 3 sections, 5 audio tasks, submitted attempt and Polish response round-trip; revision \(package.revision)")
    }
}
