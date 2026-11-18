import XCTest
import AppKit
@testable import Marksmith

/// Coverage for the 公式 / 流程图 guide menus: template data, the LaTeX-safe
/// inline parser, Mermaid fence rendering and the actual NSTextView insertion
/// (placeholder selection + using an existing selection as the payload).
final class InsertGuideTests: XCTestCase {

    // MARK: - Template data

    func testEveryTemplateHasAReachablePlaceholder() {
        let all = InsertTemplates.math + InsertTemplates.diagram
        XCTAssertEqual(all.count, 9)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "template ids must be unique")
        for template in all {
            XCTAssertNotNil(template.placeholderRange,
                            "\(template.id): placeholder not found in snippet")
            XCTAssertFalse(template.snippet.isEmpty)
            XCTAssertFalse(template.title.isEmpty)
        }
        XCTAssertFalse(InsertTemplates.inlineMath.isBlock)
        XCTAssertTrue(InsertTemplates.displayMath.isBlock)
        XCTAssertTrue(InsertTemplates.flowchartTD.isBlock)
    }

    func testDiagramTemplatesAreValidMermaidFences() {
        for template in InsertTemplates.diagram {
            let lines = template.snippet.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertEqual(String(lines[0]), "```mermaid", template.id)
            let kind = String(lines[1])
            XCTAssertTrue(["flowchart TD", "flowchart LR", "sequenceDiagram", "gantt"]
                .contains(kind), "\(template.id): unexpected diagram type \(kind)")
            XCTAssertEqual(String(lines.last ?? ""), "")
            let html = HTMLRenderer().render(MarkdownParser().parse(template.snippet))
            XCTAssertTrue(html.contains("class=\"language-mermaid\""), template.id)
            XCTAssertTrue(html.contains(kind), template.id)
        }
    }

    // MARK: - LaTeX stays verbatim through parse → HTML

    func testDisplayMathKeepsBackslashesBracesAndUnderscores() {
        let html = HTMLRenderer().render(
            MarkdownParser().parse(InsertTemplates.summation.snippet))
        XCTAssertTrue(html.contains("$$\n\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\n$$"))
        XCTAssertTrue(html.contains("\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}"))
        XCTAssertFalse(html.contains("<em>"), "LaTeX underscores must not become emphasis")
        XCTAssertFalse(html.contains("<strong>"))
    }

    func testMultilineAlignedMathSurvivesTheInlineParser() {
        let html = HTMLRenderer().render(
            MarkdownParser().parse(InsertTemplates.aligned.snippet))
        XCTAssertTrue(html.contains("\\begin{aligned}"))
        XCTAssertTrue(html.contains("E &amp;= mc^2 \\\\"))
        XCTAssertTrue(html.contains("\\end{aligned}"))
    }

    func testInlineMathPriceGuardStillWorks() {
        let html = HTMLRenderer().render(
            MarkdownParser().parse("价格 $5 和 $10，公式 $x^2 + y^2$ 结束"))
        XCTAssertTrue(html.contains("$5 和 $10"))
        XCTAssertTrue(html.contains("$x^2 + y^2$"))
        XCTAssertFalse(html.contains("<em>"))
        XCTAssertFalse(html.contains("<del>"))
    }

    func testMathEscapesAreNotStripped() {
        // `\_` / `\{` are legitimate LaTeX; previously the generic escape
        // handler dropped the backslash.
        let html = HTMLRenderer().render(
            MarkdownParser().parse("行内 $\\{a\\_b\\}$ 与 $$\\alpha$$"))
        XCTAssertTrue(html.contains("$\\{a\\_b\\}$"))
        XCTAssertTrue(html.contains("$$\\alpha$$"))
    }

    // MARK: - Real insertion into NSTextView

    @MainActor
    func testInlineMathInsertSelectsPlaceholder() {
        let tv = makeTextView("质量为 ")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.apply(.template(InsertTemplates.inlineMath))

        XCTAssertEqual(tv.string, "质量为 $E = mc^2$", "inline math must stay on the same line")
        XCTAssertEqual((tv.string as NSString).substring(with: tv.selectedRange), "E = mc^2")
    }

    @MainActor
    func testSelectedTextBecomesTheFormula() {
        let tv = makeTextView("x^2 + y^2")
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        tv.apply(.template(InsertTemplates.inlineMath))
        XCTAssertEqual(tv.string, "$x^2 + y^2$")
    }

    @MainActor
    func testBlockTemplateStartsOnANewLine() {
        let tv = makeTextView("前面的段落")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.apply(.template(InsertTemplates.flowchartTD))

        XCTAssertTrue(tv.string.hasPrefix("前面的段落\n```mermaid\n"))
        let model = MarkdownParser().parse(tv.string)
        XCTAssertTrue(model.blocks.contains { block in
            if case .codeBlock(let language, let code) = block {
                return language == "mermaid" && code.contains("flowchart TD")
            }
            return false
        })
    }

    @MainActor
    func testDisplayMathBlockIsSeparatedFromProse() {
        let tv = makeTextView("推导如下：")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.apply(.template(InsertTemplates.displayMath))
        XCTAssertEqual(tv.string, "推导如下：\n$$\nE = mc^2\n$$\n")
        XCTAssertEqual((tv.string as NSString).substring(with: tv.selectedRange), "E = mc^2")
    }

    // MARK: - Cheat sheets

    func testCheatSheetsContainTheSyntaxBasics() {
        let math = InsertTemplates.cheatSheet(for: .math)
        XCTAssertTrue(math.contains("$...$"))
        XCTAssertTrue(math.contains("\\frac{a}{b}"))
        XCTAssertTrue(math.contains("LaTeX"))
        let diagram = InsertTemplates.cheatSheet(for: .diagram)
        XCTAssertTrue(diagram.contains("```mermaid"))
        XCTAssertTrue(diagram.contains("flowchart TD"))
        XCTAssertTrue(diagram.contains("sequenceDiagram"))
    }

    // MARK: - Fixture

    @MainActor
    private func makeTextView(_ initial: String) -> MarkdownEditorTextView {
        let storage = HighlightingTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let view = MarkdownEditorTextView(frame: NSRect.zero, textContainer: container)
        view.isRichText = true
        view.minSize = NSSize.zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        storage.setText(initial)
        return view
    }
}
