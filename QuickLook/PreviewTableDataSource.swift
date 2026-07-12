import Cocoa

/// Data source + cell production for the NSTableView.
final class PreviewTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let indexColumnID = "row_index"

    private let preview: ParquetPreview
    private let numericColumns: Set<Int>

    private static let cellFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private static let numericTypePrefixes = [
        "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
        "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT",
        "FLOAT", "DOUBLE", "DECIMAL",
    ]

    init(preview: ParquetPreview) {
        self.preview = preview
        self.numericColumns = Set(preview.columns.enumerated().compactMap { index, column in
            Self.numericTypePrefixes.contains { column.type.hasPrefix($0) } ? index : nil
        })
    }

    static func indexColumnWidth(rowCount: Int) -> CGFloat {
        max(28, CGFloat(String(rowCount).count) * 8 + 14)
    }

    /// Column width estimate based on the header and the first rows.
    func estimatedWidth(forColumn index: Int) -> CGFloat {
        let column = preview.columns[index]
        var maxLength = column.name.count + column.type.count + 2
        for row in preview.rows.prefix(30) {
            maxLength = max(maxLength, row[index]?.count ?? 4)
        }
        return min(max(CGFloat(maxLength) * 7 + 16, 60), 360)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        preview.rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let identifier = tableColumn.identifier

        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.font = Self.cellFont
            cell.lineBreakMode = .byTruncatingTail
            cell.usesSingleLineMode = true
        }

        if identifier.rawValue == Self.indexColumnID {
            cell.stringValue = String(row + 1)
            cell.textColor = .tertiaryLabelColor
            cell.alignment = .right
            return cell
        }

        guard let columnIndex = Int(identifier.rawValue.dropFirst("col_".count)),
              columnIndex < preview.columns.count else { return nil }

        if let value = preview.rows[row][columnIndex] {
            cell.stringValue = value
            cell.textColor = .labelColor
        } else {
            cell.stringValue = "NULL"
            cell.textColor = .tertiaryLabelColor
        }
        cell.alignment = numericColumns.contains(columnIndex) ? .right : .left
        return cell
    }
}
