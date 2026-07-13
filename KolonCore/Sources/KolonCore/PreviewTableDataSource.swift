import Cocoa

/// Label whose tooltip text is produced lazily, only when AppKit actually
/// decides to show it (i.e. after the system hover delay) — sweeping the
/// mouse across cells never invokes the provider.
final class LazyTooltipTextField: NSTextField {
    private var toolTipTag: NSView.ToolTipTag?

    var tooltipProvider: (() -> String?)? {
        didSet {
            if let tag = toolTipTag {
                removeToolTip(tag)
                toolTipTag = nil
            }
            if tooltipProvider != nil {
                toolTipTag = addToolTip(bounds, owner: self, userData: nil)
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Tooltip rects don't track resizes (e.g. manual column widening)
        if tooltipProvider != nil, let tag = toolTipTag {
            removeToolTip(tag)
            toolTipTag = addToolTip(bounds, owner: self, userData: nil)
        }
    }

    // NSViewToolTipOwner (informal protocol, dispatched via the ObjC selector)
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tooltipProvider?() ?? ""
    }
}

/// Data source + cell production for the NSTableView.
public final class PreviewTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public static let indexColumnID = "row_index"

    private let preview: ParquetPreview
    private let numericColumns: Set<Int>
    /// Full cell values fetched on demand for tooltips, keyed like truncatedCells
    private var fullValueCache: [Int: String] = [:]
    private lazy var detailReader: ParquetReader? = try? ParquetReader()

    private static let cellFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private static let numericTypePrefixes = [
        "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
        "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT",
        "FLOAT", "DOUBLE", "DECIMAL",
    ]

    public init(preview: ParquetPreview) {
        self.preview = preview
        self.numericColumns = Set(preview.columns.enumerated().compactMap { index, column in
            Self.numericTypePrefixes.contains { column.type.hasPrefix($0) } ? index : nil
        })
    }

    public static func indexColumnWidth(rowCount: Int) -> CGFloat {
        max(28, CGFloat(String(rowCount).count) * 8 + 14)
    }

    /// Column width estimate based on the header and the first rows.
    public func estimatedWidth(forColumn index: Int) -> CGFloat {
        let column = preview.columns[index]
        var maxLength = column.name.count + column.type.count + 2
        for row in preview.rows.prefix(30) {
            maxLength = max(maxLength, row[index]?.count ?? 4)
        }
        return min(max(CGFloat(maxLength) * 7 + 16, 60), 360)
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        preview.rows.count
    }

    // MARK: - NSTableViewDelegate

    /// Lets the QL shell substitute a row view with custom selection
    /// drawing; nil falls back to the standard NSTableRowView.
    public var rowViewProvider: ((NSTableView) -> NSTableRowView)?

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        rowViewProvider?(tableView)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let identifier = tableColumn.identifier

        let cell: LazyTooltipTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? LazyTooltipTextField {
            cell = reused
        } else {
            cell = LazyTooltipTextField(labelWithString: "")
            cell.identifier = identifier
            cell.font = Self.cellFont
            cell.lineBreakMode = .byTruncatingTail
            cell.usesSingleLineMode = true
        }
        cell.tooltipProvider = nil

        if identifier.rawValue == Self.indexColumnID {
            cell.stringValue = String(row + 1)
            cell.textColor = .tertiaryLabelColor
            cell.alignment = .right
            return cell
        }

        guard let columnIndex = Int(identifier.rawValue.dropFirst("col_".count)),
              columnIndex < preview.columns.count else { return nil }

        let value = preview.rows[row][columnIndex]
        if let value {
            cell.stringValue = Self.displayText(value)
            cell.textColor = .labelColor
        } else {
            cell.stringValue = "NULL"
            cell.textColor = .tertiaryLabelColor
        }
        cell.alignment = numericColumns.contains(columnIndex) ? .right : .left
        if preview.isTruncated(row: row, column: columnIndex) {
            // Cut at cellCharacterLimit — re-read the real value on hover
            cell.allowsExpansionToolTips = false
            cell.tooltipProvider = { [weak self] in self?.fullValue(row: row, column: columnIndex) }
        } else if let value, value != cell.stringValue {
            // Control characters are shown escaped — hover reveals the real,
            // multi-line value (an expansion tooltip would echo the escapes)
            cell.allowsExpansionToolTips = false
            cell.tooltipProvider = { value }
        } else {
            // Only clipped by column width at worst; the stored copy is complete
            cell.allowsExpansionToolTips = true
        }
        return cell
    }

    /// Control characters rendered as visible escapes so multi-line values
    /// stay legible in the single-line cell; only the displayed text changes —
    /// copy and tooltips use the stored value with the real characters.
    static func displayText(_ value: String) -> String {
        // Scalar-level scan: "\r\n" is a single Character in Swift, so a
        // Character-based contains would miss values whose only control
        // characters are CRLF pairs.
        guard value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) else {
            return value
        }
        return value
            .replacingOccurrences(of: "\r\n", with: "\\r\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Clipboard support

    /// Complete value of one cell for copying: cells cut at
    /// `cellCharacterLimit` are re-read from the file. nil means NULL.
    public func copyValue(row: Int, column: Int) -> String? {
        guard let stored = preview.rows[row][column] else { return nil }
        guard preview.isTruncated(row: row, column: column),
              let reader = detailReader,
              let result = (try? reader.fullValue(fileAt: preview.fileURL, row: row,
                                                  columnName: preview.columns[column].name,
                                                  characterLimit: 1_000_000)) ?? nil else {
            return stored
        }
        return result.value
    }

    /// How many truncated cells a CSV copy will re-read in full before
    /// falling back to the previewed text — the re-reads run on the main
    /// thread, so a pathological selection must stay bounded.
    static let csvFullReadBudget = 500

    /// Selected rows as CSV (RFC 4180 quoting). NULL becomes an empty
    /// field; cells the preview truncated are re-read in full, up to
    /// `csvFullReadBudget` cells per copy.
    public func csv(forRows rows: IndexSet) -> String {
        var budget = Self.csvFullReadBudget
        return rows.map { row in
            preview.rows[row].indices.map { column in
                var value = preview.rows[row][column]
                if budget > 0, value != nil, preview.isTruncated(row: row, column: column) {
                    budget -= 1
                    value = copyValue(row: row, column: column)
                }
                return Self.csvField(value)
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    static func csvField(_ value: String?) -> String {
        guard let value else { return "" }
        // Scalar-level scan — see displayText for why (CRLF grapheme)
        guard value.unicodeScalars.contains(where: {
            $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r"
        }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Tooltip text for a cell the preview truncated: the full value is
    /// re-read from the file (once — results are cached).
    private func fullValue(row: Int, column: Int) -> String? {
        let key = row * preview.columns.count + column
        if let cached = fullValueCache[key] { return cached }

        let fallback = preview.rows[row][column]
        guard let reader = detailReader,
              let result = (try? reader.fullValue(fileAt: preview.fileURL, row: row,
                                                  columnName: preview.columns[column].name)) ?? nil else {
            return fallback  // file gone or unreadable — show the stored copy
        }
        var text = result.value
        if result.totalLength > result.value.count {
            text += "\n… \(result.totalLength) characters total"
        }
        fullValueCache[key] = text
        return text
    }
}
