import Cocoa
import Quartz

/// Theme-aware opaque backdrop; the dynamic color resolves against effectiveAppearance on every draw.
private final class BackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

final class PreviewViewController: NSViewController, QLPreviewingController {

    private var dataSource: PreviewTableDataSource?

    override func loadView() {
        view = BackgroundView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        do {
            let preview = try await Task.detached(priority: .userInitiated) {
                try ParquetReader().preview(fileAt: url)
            }.value

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
            await MainActor.run {
                buildInterface(preview: preview, fileSize: fileSize)
            }
        } catch {
            // Swallow the error and render it ourselves; rethrowing would
            // only get us Quick Look's generic "can't preview" screen.
            await MainActor.run {
                buildErrorInterface(message: error.localizedDescription, fileName: url.lastPathComponent)
            }
        }
    }

    @MainActor
    private func buildErrorInterface(message: String, fileName: String) {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 36, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "Can't read \(fileName)")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        // Strip DuckDB's trailing internal SQL dump ("LINE 1: ...") from the message
        let cleanedMessage = message.components(separatedBy: "\nLINE ").first ?? message
        let detail = NSTextField(wrappingLabelWithString: cleanedMessage)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center

        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -80),
        ])
    }

    @MainActor
    private func buildInterface(preview: ParquetPreview, fileSize: Int64) {
        let dataSource = PreviewTableDataSource(preview: preview)
        self.dataSource = dataSource

        let tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 22
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.gridColor = .separatorColor

        // Row number column
        let indexColumn = NSTableColumn(identifier: .init(PreviewTableDataSource.indexColumnID))
        indexColumn.title = "#"
        indexColumn.width = PreviewTableDataSource.indexColumnWidth(rowCount: preview.rows.count)
        indexColumn.resizingMask = []
        tableView.addTableColumn(indexColumn)

        for (i, column) in preview.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: .init("col_\(i)"))
            tableColumn.headerCell.attributedStringValue = Self.headerTitle(for: column)
            tableColumn.width = dataSource.estimatedWidth(forColumn: i)
            tableColumn.minWidth = 50
            tableColumn.maxWidth = 600
            tableView.addTableColumn(tableColumn)
        }

        tableView.dataSource = dataSource
        tableView.delegate = dataSource

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = Self.makeStatusBar(preview: preview, fileSize: fileSize)

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(scrollView)
        view.addSubview(statusBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private static func headerTitle(for column: ParquetPreview.Column) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: column.name,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.headerTextColor,
            ]
        )
        title.append(NSAttributedString(
            string: "  \(column.type)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 2),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return title
    }

    private static func makeStatusBar(preview: ParquetPreview, fileSize: Int64) -> NSView {
        let container = NSVisualEffectView()
        container.material = .titlebar
        container.blendingMode = .withinWindow
        container.translatesAutoresizingMaskIntoConstraints = false

        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal

        var parts: [String] = []
        let totalRows = numberFormatter.string(from: NSNumber(value: preview.totalRows)) ?? "\(preview.totalRows)"
        parts.append("\(totalRows) rows × \(preview.totalColumns) columns")
        parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
        if let compression = preview.compression, !compression.isEmpty {
            parts.append(compression)
        }
        if let groups = preview.rowGroupCount {
            parts.append(groups == 1 ? "1 row group" : "\(groups) row groups")
        }
        if preview.totalRows > Int64(preview.rows.count) {
            parts.append("showing first \(numberFormatter.string(from: NSNumber(value: preview.rows.count)) ?? "\(preview.rows.count)") rows")
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let separator = "  ·  "
        let text = NSMutableAttributedString(
            string: parts.joined(separator: separator),
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
        if preview.totalColumns > preview.columns.count {
            let totalColumns = numberFormatter.string(from: NSNumber(value: preview.totalColumns)) ?? "\(preview.totalColumns)"
            text.append(NSAttributedString(
                string: separator,
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            ))
            text.append(NSAttributedString(
                string: "⚠ only the first \(preview.columns.count) of \(totalColumns) columns are shown",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.systemOrange,
                ]
            ))
        }

        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = text
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(border)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 26),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            border.topAnchor.constraint(equalTo: container.topAnchor),
            border.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }
}
