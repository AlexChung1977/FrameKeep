import Foundation

final class JobStore {
    private let db: SQLiteStore

    init(db: SQLiteStore) {
        self.db = db
    }

    func all() throws -> [DownloadJob] {
        let rows = try db.query("SELECT * FROM jobs ORDER BY updated_at DESC")
        return rows.compactMap(Self.job(from:))
    }

    func upsert(_ job: DownloadJob) throws {
        try db.run(
            """
            INSERT INTO jobs (
                id, url, title, state, format_id, format_label, progress, speed, eta,
                failure_kind, failure_message, output_path, probe_json, source, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                url=excluded.url,
                title=excluded.title,
                state=excluded.state,
                format_id=excluded.format_id,
                format_label=excluded.format_label,
                progress=excluded.progress,
                speed=excluded.speed,
                eta=excluded.eta,
                failure_kind=excluded.failure_kind,
                failure_message=excluded.failure_message,
                output_path=excluded.output_path,
                source=excluded.source,
                updated_at=excluded.updated_at
            """
        ) { [db] stmt in
            db.bindText(stmt, 1, job.id.uuidString)
            db.bindText(stmt, 2, job.url.absoluteString)
            db.bindText(stmt, 3, job.title)
            db.bindText(stmt, 4, job.state.rawValue)
            db.bindText(stmt, 5, job.formatID)
            db.bindText(stmt, 6, job.formatLabel)
            db.bindDouble(stmt, 7, job.progress)
            db.bindText(stmt, 8, job.speed)
            db.bindText(stmt, 9, job.eta)
            db.bindText(stmt, 10, job.failureKind?.rawValue)
            db.bindText(stmt, 11, job.failureMessage)
            db.bindText(stmt, 12, job.outputPath)
            db.bindText(stmt, 13, job.source.rawValue)
            db.bindDouble(stmt, 14, job.createdAt.timeIntervalSince1970)
            db.bindDouble(stmt, 15, job.updatedAt.timeIntervalSince1970)
        }
    }

    func delete(id: UUID) throws {
        try db.run("DELETE FROM jobs WHERE id = ?") { [db] stmt in
            db.bindText(stmt, 1, id.uuidString)
        }
    }

    func clearFinished() throws {
        try db.execute("DELETE FROM jobs WHERE state IN ('completed', 'cancelled')")
    }

    private static func job(from row: [String: SQLiteValue]) -> DownloadJob? {
        guard let idText = row["id"]?.string, let id = UUID(uuidString: idText),
              let urlText = row["url"]?.string, let url = URL(string: urlText),
              let stateRaw = row["state"]?.string, let state = JobState(rawValue: stateRaw)
        else { return nil }
        let created = Date(timeIntervalSince1970: row["created_at"]?.double ?? 0)
        let updated = Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0)
        return DownloadJob(
            id: id,
            url: url,
            title: row["title"]?.string ?? url.host ?? url.absoluteString,
            state: state,
            formatID: row["format_id"]?.string,
            formatLabel: row["format_label"]?.string,
            progress: row["progress"]?.double ?? 0,
            speed: row["speed"]?.string,
            eta: row["eta"]?.string,
            failureKind: row["failure_kind"]?.string.flatMap(FailureKind.init(rawValue:)),
            failureMessage: row["failure_message"]?.string,
            outputPath: row["output_path"]?.string,
            source: IngestSource(rawValue: row["source"]?.string ?? "") ?? .manual,
            createdAt: created,
            updatedAt: updated,
            webpageID: nil,
            host: url.host ?? ""
        )
    }
}
