import Foundation
import Cduckdb

public struct ParquetPreview {
    public struct Column {
        public let name: String
        public let type: String
    }

    public let columns: [Column]
    /// nil cell = NULL
    public let rows: [[String?]]
    public let totalRows: Int64
    /// Actual column count in the file; may exceed columns.count due to the column limit
    public let totalColumns: Int
    public let compression: String?
    public let rowGroupCount: Int64?
    /// Source file, kept so single cells can be re-read in full on demand.
    public let fileURL: URL
    /// `row * columns.count + column` keys of cells cut at `cellCharacterLimit`.
    public let truncatedCells: Set<Int>

    public func isTruncated(row: Int, column: Int) -> Bool {
        truncatedCells.contains(row * columns.count + column)
    }
}

public enum ParquetReaderError: LocalizedError {
    case openFailed
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed: return "Failed to initialize DuckDB."
        case .queryFailed(let message): return message
        }
    }
}

/// Thin wrapper over the DuckDB C API. Opens an in-memory database
/// and only ever reads the parquet file.
public final class ParquetReader {
    public static let previewRowLimit = 500
    public static let previewColumnLimit = 200
    public static let cellCharacterLimit = 300

    private var database: duckdb_database?
    private var connection: duckdb_connection?

    public init() throws {
        guard duckdb_open(nil, &database) == DuckDBSuccess,
              duckdb_connect(database, &connection) == DuckDBSuccess else {
            throw ParquetReaderError.openFailed
        }
        // Quick Look processes are killed aggressively on memory pressure;
        // DuckDB's default (80% of RAM) is unacceptable here.
        _ = try? query("SET memory_limit='512MiB'; SET threads TO 2;")
    }

    deinit {
        duckdb_disconnect(&connection)
        duckdb_close(&database)
    }

    public func preview(fileAt url: URL) throws -> ParquetPreview {
        let path = url.path.replacingOccurrences(of: "'", with: "''")

        let schema = try query("DESCRIBE SELECT * FROM read_parquet('\(path)')")
        let allColumns = (0..<schema.rowCount).map { row in
            ParquetPreview.Column(
                name: schema.value(row: row, column: 0) ?? "?",
                type: schema.value(row: row, column: 1) ?? "?"
            )
        }
        let columns = Array(allColumns.prefix(Self.previewColumnLimit))

        // Select only the displayed columns so very wide files
        // don't get fully materialized
        let selectList = columns
            .map { "\"\($0.name.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: ", ")
        let data = try query("SELECT \(selectList) FROM read_parquet('\(path)') LIMIT \(Self.previewRowLimit)")
        var truncatedCells = Set<Int>()
        let rows = (0..<data.rowCount).map { row in
            (0..<data.columnCount).map { column -> String? in
                let (value, truncated) = data.previewValue(row: row, column: column)
                if truncated { truncatedCells.insert(row * columns.count + column) }
                return value
            }
        }

        let count = try query("SELECT count(*) FROM read_parquet('\(path)')")
        let totalRows = Int64(count.value(row: 0, column: 0) ?? "0") ?? 0

        // File-level metadata; must not block the preview if it fails
        var compression: String? = nil
        var rowGroupCount: Int64? = nil
        if let meta = try? query("""
            SELECT string_agg(DISTINCT lower(compression), ', '),
                   count(DISTINCT row_group_id)
            FROM parquet_metadata('\(path)')
            """) {
            compression = meta.value(row: 0, column: 0)
            rowGroupCount = meta.value(row: 0, column: 1).flatMap(Int64.init)
        }

        return ParquetPreview(
            columns: columns,
            rows: rows,
            totalRows: totalRows,
            totalColumns: allColumns.count,
            compression: compression,
            rowGroupCount: rowGroupCount,
            fileURL: url,
            truncatedCells: truncatedCells
        )
    }

    /// Re-reads a single cell without the preview's `cellCharacterLimit` cap.
    /// Returns the value cut at `characterLimit` plus the cell's true length,
    /// or nil for NULL / out-of-range cells.
    public func fullValue(fileAt url: URL, row: Int, columnName: String,
                          characterLimit: Int = 4000) throws -> (value: String, totalLength: Int)? {
        let path = url.path.replacingOccurrences(of: "'", with: "''")
        let quoted = "\"" + columnName.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let result = try query("""
            SELECT substr(CAST(\(quoted) AS VARCHAR), 1, \(characterLimit)),
                   length(CAST(\(quoted) AS VARCHAR))
            FROM read_parquet('\(path)') LIMIT 1 OFFSET \(row)
            """)
        guard result.rowCount == 1,
              let value = result.value(row: 0, column: 0, limit: characterLimit),
              let totalLength = result.value(row: 0, column: 1).flatMap(Int.init) else {
            return nil
        }
        return (value, totalLength)
    }

    // MARK: - Query helpers

    private final class QueryResult {
        private var result = duckdb_result()
        let rowCount: Int
        let columnCount: Int

        init(connection: duckdb_connection?, sql: String) throws {
            guard duckdb_query(connection, sql, &result) == DuckDBSuccess else {
                let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "Query failed."
                duckdb_destroy_result(&result)
                throw ParquetReaderError.queryFailed(message)
            }
            rowCount = Int(duckdb_row_count(&result))
            columnCount = Int(duckdb_column_count(&result))
        }

        deinit {
            duckdb_destroy_result(&result)
        }

        func value(row: Int, column: Int, limit: Int = ParquetReader.cellCharacterLimit) -> String? {
            previewValue(row: row, column: column, limit: limit).value
        }

        func previewValue(row: Int, column: Int,
                          limit: Int = ParquetReader.cellCharacterLimit) -> (value: String?, truncated: Bool) {
            guard !duckdb_value_is_null(&result, idx_t(column), idx_t(row)),
                  let cString = duckdb_value_varchar(&result, idx_t(column), idx_t(row)) else {
                return (nil, false)
            }
            defer { duckdb_free(UnsafeMutableRawPointer(mutating: cString)) }
            let value = String(cString: cString)
            // A single cell can reach megabytes in BLOB / long text columns
            guard value.count > limit else { return (value, false) }
            return (String(value.prefix(limit)) + "…", true)
        }
    }

    private func query(_ sql: String) throws -> QueryResult {
        try QueryResult(connection: connection, sql: sql)
    }
}
