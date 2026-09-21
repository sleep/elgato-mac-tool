import AppKit

/// Renders a GitHub release body (Markdown) for the update alert. Foundation's parser only
/// understands inline Markdown, so block syntax — headings, bullets, rules — is mapped line by
/// line here.
enum ReleaseNotes {
    /// Shows `lead` followed by the rendered notes as the alert's informative text.
    ///
    /// NSAlert only takes a plain string there, and an accessory view would switch it from the wide
    /// layout to the stacked one, so the alert's own label is restyled in place after layout. That
    /// label is private AppKit hierarchy: if it can't be found, the plain-text notes simply stay.
    @MainActor
    static func show(_ markdown: String, after lead: String, in alert: NSAlert) {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let plain = lead + "\n\n"
            + attributed(markdown, font: base).string.replacingOccurrences(of: "•\t", with: "• ")

        // Bold runs and hanging indents can wrap onto more lines than the plain text the alert
        // sized itself for, so pad with blank lines until the styled text fits.
        for padding in 0..<4 {
            let text = plain + String(repeating: "\n", count: padding)
            alert.informativeText = text
            alert.layout()
            guard let label = textFields(in: alert.window.contentView).first(where: { $0.stringValue == text }),
                  let font = label.font else { break }

            let color = label.textColor ?? .labelColor
            let rich = NSMutableAttributedString(string: lead + "\n\n",
                                                 attributes: [.font: font, .foregroundColor: color])
            rich.append(attributed(markdown, font: font, color: color))
            label.attributedStringValue = rich

            let bounds = NSRect(x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)
            if let needed = label.cell?.cellSize(forBounds: bounds).height, needed <= label.frame.height { return }
        }
        alert.informativeText = plain
        alert.layout()
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        (view?.subviews ?? []).flatMap { ($0 as? NSTextField).map { [$0] } ?? textFields(in: $0) }
    }

    static func attributed(_ markdown: String, font: NSFont, color: NSColor = .labelColor,
                           limit: Int = 600) -> NSAttributedString {
        let bold = NSFont.boldSystemFont(ofSize: font.pointSize)
        let out = NSMutableAttributedString()
        var blankPending = false

        // GitHub's web editor saves CRLF, which Swift treats as a single Character.
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blankPending = out.length > 0
                continue
            }
            if line.count >= 3, line.allSatisfy({ "-*_".contains($0) }) { continue }  // horizontal rule

            if out.length > 0 { out.append(NSAttributedString(string: blankPending ? "\n\n" : "\n")) }
            blankPending = false

            if let heading = headingText(line) {
                out.append(inline(heading, font: bold, color: color))
            } else if let item = bulletText(line) {
                let bullet = NSMutableAttributedString(string: "•\t", attributes: [.font: font, .foregroundColor: color])
                bullet.append(inline(item, font: font, color: color))
                bullet.addAttribute(.paragraphStyle, value: bulletStyle,
                                    range: NSRange(location: 0, length: bullet.length))
                out.append(bullet)
            } else {
                out.append(inline(line, font: font, color: color))
            }
        }
        return truncated(out, limit: limit)
    }

    // MARK: - Blocks

    /// "## Fixed" → "Fixed"
    private static func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        let rest = line.dropFirst(hashes.count)
        guard (1...6).contains(hashes.count), rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// "- item" / "* item" / "+ item" → "item". "**bold** …" is not a bullet: no space after the marker.
    private static func bulletText(_ line: String) -> String? {
        guard let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " else { return nil }
        return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    private static let bulletStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 11)]
        style.headIndent = 11
        return style
    }()

    // MARK: - Inline

    private static func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }

        // AppKit doesn't draw the parser's presentation intents, so turn them into fonts.
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }

            var runFont = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
            if !traits.isEmpty {
                let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits))
                runFont = NSFont(descriptor: descriptor, size: font.pointSize) ?? runFont
            }

            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    // MARK: - Truncation

    /// Cuts at a word boundary in the rendered text, so Markdown markers are never split.
    private static func truncated(_ text: NSAttributedString, limit: Int) -> NSAttributedString {
        let plain = text.string
        guard plain.count > limit else { return text }
        var cut = plain.prefix(limit)
        if let space = cut.lastIndex(where: \.isWhitespace) { cut = cut[..<space] }
        let out = NSMutableAttributedString(
            attributedString: text.attributedSubstring(from: NSRange(location: 0, length: cut.utf16.count)))
        out.append(NSAttributedString(string: "…", attributes: out.attributes(at: out.length - 1, effectiveRange: nil)))
        return out
    }
}
