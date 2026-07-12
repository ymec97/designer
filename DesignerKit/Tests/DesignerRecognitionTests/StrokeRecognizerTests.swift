import XCTest
import DesignerModel
@testable import DesignerRecognition

/// Synthetic "hand-drawn" strokes: ideal shapes + per-point jitter, random
/// rotation of start position, and overshoot/undershoot at the ends — the
/// M3 exit criterion is ≥90% recognition on these.
final class StrokeRecognizerTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private var generator = SeededGenerator(state: 42)

    private func jitter(_ amount: Double) -> Double {
        Double.random(in: -amount...amount, using: &generator)
    }

    private func strokePoints(_ points: [Point]) -> [StrokePoint] {
        points.enumerated().map { index, point in
            StrokePoint(x: point.x, y: point.y, pressure: 0.5, time: Double(index) * 0.008)
        }
    }

    // MARK: Stroke synthesis

    private func sketchRectangle(
        x: Double, y: Double, width: Double, height: Double,
        jitterAmount: Double, closureGap: Double = 6
    ) -> [StrokePoint] {
        var points: [Point] = []
        let corners = [
            Point(x: x, y: y), Point(x: x + width, y: y),
            Point(x: x + width, y: y + height), Point(x: x, y: y + height),
        ]
        for side in 0..<4 {
            let from = corners[side]
            let to = corners[(side + 1) % 4]
            let steps = 14
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                // Stop short on the final side to leave a human closure gap.
                if side == 3, t > 1 - closureGap / max(height, 1) { break }
                points.append(Point(
                    x: from.x + (to.x - from.x) * t + jitter(jitterAmount),
                    y: from.y + (to.y - from.y) * t + jitter(jitterAmount)
                ))
            }
        }
        return strokePoints(points)
    }

    private func sketchEllipse(
        centerX: Double, centerY: Double, radiusX: Double, radiusY: Double,
        jitterAmount: Double
    ) -> [StrokePoint] {
        let startAngle = Double.random(in: 0..<(2 * .pi), using: &generator)
        var points: [Point] = []
        let steps = 48
        for step in 0...steps {
            let angle = startAngle + Double(step) / Double(steps) * 2 * .pi * 0.97
            points.append(Point(
                x: centerX + cos(angle) * radiusX + jitter(jitterAmount),
                y: centerY + sin(angle) * radiusY + jitter(jitterAmount)
            ))
        }
        return strokePoints(points)
    }

    private func sketchDiamond(
        centerX: Double, centerY: Double, width: Double, height: Double,
        jitterAmount: Double
    ) -> [StrokePoint] {
        let vertices = [
            Point(x: centerX, y: centerY - height / 2),
            Point(x: centerX + width / 2, y: centerY),
            Point(x: centerX, y: centerY + height / 2),
            Point(x: centerX - width / 2, y: centerY),
        ]
        var points: [Point] = []
        for side in 0..<4 {
            let from = vertices[side]
            let to = vertices[(side + 1) % 4]
            for step in 0..<12 {
                let t = Double(step) / 12
                if side == 3, t > 0.9 { break }
                points.append(Point(
                    x: from.x + (to.x - from.x) * t + jitter(jitterAmount),
                    y: from.y + (to.y - from.y) * t + jitter(jitterAmount)
                ))
            }
        }
        return strokePoints(points)
    }

    private func sketchLine(
        from: Point, to: Point, jitterAmount: Double, bow: Double = 0
    ) -> [StrokePoint] {
        var points: [Point] = []
        let steps = 24
        let normal = normalized(Point(x: -(to.y - from.y), y: to.x - from.x))
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let arc = sin(t * .pi) * bow
            points.append(Point(
                x: from.x + (to.x - from.x) * t + normal.x * arc + jitter(jitterAmount),
                y: from.y + (to.y - from.y) * t + normal.y * arc + jitter(jitterAmount)
            ))
        }
        return strokePoints(points)
    }

    private func normalized(_ point: Point) -> Point {
        let length = (point.x * point.x + point.y * point.y).squareRoot()
        guard length > 0 else { return .zero }
        return Point(x: point.x / length, y: point.y / length)
    }

    // MARK: The ≥90% criterion

    func testRecognitionRateAcrossJitteredShapes() {
        var attempts = 0
        var successes = 0
        var failures: [String] = []

        func expectShape(
            _ points: [StrokePoint],
            _ matches: (StrokeRecognizer.Recognition?) -> Bool,
            _ label: String
        ) {
            attempts += 1
            let result = StrokeRecognizer.recognize(points)
            if matches(result) {
                successes += 1
            } else {
                failures.append("\(label) → \(String(describing: result))")
            }
        }

        for trial in 0..<25 {
            let jitterAmount = 1.5 + Double(trial % 5)
            expectShape(
                sketchRectangle(
                    x: Double(trial) * 30, y: 100, width: 140 + Double(trial), height: 90,
                    jitterAmount: jitterAmount
                ),
                { if case .rectangle = $0 { return true }; return false },
                "rect j=\(jitterAmount) trial=\(trial)"
            )
            expectShape(
                sketchEllipse(
                    centerX: 300, centerY: 300, radiusX: 80 + Double(trial), radiusY: 55,
                    jitterAmount: jitterAmount
                ),
                { if case .ellipse = $0 { return true }; return false },
                "ellipse j=\(jitterAmount) trial=\(trial)"
            )
            expectShape(
                sketchDiamond(
                    centerX: 500, centerY: 200, width: 130, height: 110 + Double(trial),
                    jitterAmount: jitterAmount
                ),
                { if case .diamond = $0 { return true }; return false },
                "diamond j=\(jitterAmount) trial=\(trial)"
            )
            expectShape(
                sketchLine(
                    from: Point(x: 0, y: Double(trial) * 10),
                    to: Point(x: 250, y: Double(trial) * 12 + 40),
                    jitterAmount: jitterAmount, bow: Double(trial % 4) * 2
                ),
                { if case .line = $0 { return true }; return false },
                "line j=\(jitterAmount) trial=\(trial)"
            )
        }

        let rate = Double(successes) / Double(attempts)
        XCTAssertGreaterThanOrEqual(
            rate, 0.9,
            "recognition rate \(successes)/\(attempts) below 90%. Failures:\n" +
            failures.joined(separator: "\n")
        )
    }

    // MARK: Negative cases — scribbles must stay ink

    func testScribbleIsNotRecognized() {
        var points: [Point] = []
        for i in 0..<60 {
            points.append(Point(
                x: Double.random(in: 0...200, using: &generator),
                y: Double.random(in: 0...150, using: &generator) + Double(i)
            ))
        }
        XCTAssertNil(StrokeRecognizer.recognize(strokePoints(points)))
    }

    func testTinyStrokeIsNotRecognized() {
        let tiny = sketchRectangle(x: 0, y: 0, width: 8, height: 6, jitterAmount: 0.5)
        XCTAssertNil(StrokeRecognizer.recognize(tiny))
    }

    func testTooFewPointsIsNotRecognized() {
        XCTAssertNil(StrokeRecognizer.recognize(strokePoints([
            Point(x: 0, y: 0), Point(x: 100, y: 100),
        ])))
    }

    // MARK: Conversion

    private func makeBoard() -> (Board, LayerID) {
        let board = Board(title: "Sketch")
        return (board, board.layers[0].id)
    }

    private func inkElement(_ points: [StrokePoint], layer: LayerID) -> Element {
        Element(layerIDs: [layer], sortKey: "i", content: .ink(Ink(points: points)))
    }

    func testRectangleSketchConvertsToBlock() throws {
        var (board, layer) = makeBoard()
        let ink = inkElement(
            sketchRectangle(x: 50, y: 50, width: 150, height: 100, jitterAmount: 2),
            layer: layer
        )
        try board.apply(.insertElement(ink))

        let conversion = try XCTUnwrap(SketchConversion.conversion(for: ink, in: board))
        try board.apply(conversion.operation)

        XCTAssertNil(board.elements[ink.id], "ink is replaced")
        let node = try XCTUnwrap(board.elements[conversion.producedID]?.node)
        XCTAssertEqual(node.frame.x, 50, accuracy: 6)
        XCTAssertEqual(node.frame.width, 150, accuracy: 12)
    }

    func testLineBetweenBlocksConvertsToConnector() throws {
        var (board, layer) = makeBoard()
        let a = Element(
            layerIDs: [layer], sortKey: "i",
            content: .node(Node(frame: Rect(x: 0, y: 0, width: 100, height: 60)))
        )
        let b = Element(
            layerIDs: [layer], sortKey: "j",
            content: .node(Node(frame: Rect(x: 400, y: 0, width: 100, height: 60)))
        )
        try board.apply(.insertElement(a))
        try board.apply(.insertElement(b))

        let ink = inkElement(
            sketchLine(from: Point(x: 108, y: 30), to: Point(x: 392, y: 30), jitterAmount: 2, bow: 4),
            layer: layer
        )
        try board.apply(.insertElement(ink))

        let conversion = try XCTUnwrap(SketchConversion.conversion(for: ink, in: board))
        try board.apply(conversion.operation)

        let edge = try XCTUnwrap(board.elements[conversion.producedID]?.edge)
        XCTAssertEqual(edge.from.elementID, a.id)
        XCTAssertEqual(edge.to.elementID, b.id)
        XCTAssertNil(board.elements[ink.id])
    }

    func testLineWithNoNearbyBlocksStaysInk() throws {
        var (board, layer) = makeBoard()
        let ink = inkElement(
            sketchLine(from: Point(x: 0, y: 0), to: Point(x: 300, y: 10), jitterAmount: 1),
            layer: layer
        )
        try board.apply(.insertElement(ink))
        XCTAssertNil(SketchConversion.conversion(for: ink, in: board))
    }

    func testStructurizeSketchedBoxesThenLine() throws {
        var (board, layer) = makeBoard()
        // Two sketched boxes and a line between them, structurized together:
        // the line must attach to the just-converted blocks.
        let box1 = inkElement(
            sketchRectangle(x: 0, y: 0, width: 120, height: 80, jitterAmount: 2),
            layer: layer
        )
        let box2 = inkElement(
            sketchRectangle(x: 400, y: 0, width: 120, height: 80, jitterAmount: 2),
            layer: layer
        )
        let line = inkElement(
            sketchLine(from: Point(x: 128, y: 40), to: Point(x: 394, y: 40), jitterAmount: 2),
            layer: layer
        )
        for element in [box1, box2, line] {
            try board.apply(.insertElement(element))
        }

        let conversion = try XCTUnwrap(
            SketchConversion.structurize([box1.id, box2.id, line.id], in: board)
        )
        try board.apply(conversion.operation)

        let nodes = board.elements.values.filter { $0.node != nil }
        let edges = board.elements.values.filter { $0.edge != nil }
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(edges.count, 1)
        XCTAssertTrue(board.elements.values.allSatisfy { element in
            if case .ink = element.content { return false }
            return true
        }, "all ink should be converted")
    }

    func testSloppyClosedShapesStillConvert() {
        // Rotated diamond-ish quad, wobbly circle, and a pentagon-ish blob:
        // per user feedback these must all become blocks, not stay ink.
        let rotatedQuad = strokePoints((0...40).map { i -> Point in
            let t = Double(i) / 40 * 2 * .pi
            // Superellipse-ish rounded square rotated ~30°.
            let r = 80 / pow(pow(abs(cos(t)), 4) + pow(abs(sin(t)), 4), 0.25)
            let angle = t + .pi / 6
            return Point(x: 200 + cos(angle) * r + jitter(2), y: 200 + sin(angle) * r + jitter(2))
        })
        let blob = strokePoints((0...36).map { i -> Point in
            let t = Double(i) / 36 * 2 * .pi * 0.96
            let r = 70 + 12 * sin(t * 5) // five soft lobes
            return Point(x: 500 + cos(t) * r, y: 300 + sin(t) * r * 0.8)
        })
        for (label, stroke) in [("rotatedQuad", rotatedQuad), ("blob", blob)] {
            let result = StrokeRecognizer.recognize(stroke)
            let isShape: Bool
            switch result {
            case .rectangle, .ellipse, .diamond: isShape = true
            default: isShape = false
            }
            XCTAssertTrue(isShape, "\(label) should convert to a block, got \(String(describing: result))")
        }
    }

    func testCurvedStrokeBetweenBlocksConverts() throws {
        var (board, layer) = makeBoard()
        let a = Element(
            layerIDs: [layer], sortKey: "i",
            content: .node(Node(frame: Rect(x: 0, y: 0, width: 100, height: 60)))
        )
        let b = Element(
            layerIDs: [layer], sortKey: "j",
            content: .node(Node(frame: Rect(x: 400, y: 0, width: 100, height: 60)))
        )
        try board.apply(.insertElement(a))
        try board.apply(.insertElement(b))

        // Strongly bowed arrow — previously rejected by the deviation test.
        let ink = inkElement(
            sketchLine(from: Point(x: 105, y: 30), to: Point(x: 395, y: 30), jitterAmount: 2, bow: 70),
            layer: layer
        )
        try board.apply(.insertElement(ink))
        let conversion = try XCTUnwrap(
            SketchConversion.conversion(for: ink, in: board),
            "curved strokes between blocks must convert"
        )
        try board.apply(conversion.operation)
        XCTAssertNotNil(board.elements[conversion.producedID]?.edge)
    }

    func testReverseStrokeMakesConnectionBidirectional() throws {
        var (board, layer) = makeBoard()
        let a = Element(
            layerIDs: [layer], sortKey: "i",
            content: .node(Node(frame: Rect(x: 0, y: 0, width: 100, height: 60)))
        )
        let b = Element(
            layerIDs: [layer], sortKey: "j",
            content: .node(Node(frame: Rect(x: 400, y: 0, width: 100, height: 60)))
        )
        try board.apply(.insertElement(a))
        try board.apply(.insertElement(b))

        // First stroke A→B creates the edge.
        let first = inkElement(
            sketchLine(from: Point(x: 105, y: 30), to: Point(x: 395, y: 30), jitterAmount: 1),
            layer: layer
        )
        try board.apply(.insertElement(first))
        let firstConversion = try XCTUnwrap(SketchConversion.conversion(for: first, in: board))
        try board.apply(firstConversion.operation)

        // Second stroke B→A upgrades it instead of duplicating.
        let second = inkElement(
            sketchLine(from: Point(x: 395, y: 40), to: Point(x: 105, y: 40), jitterAmount: 1),
            layer: layer
        )
        try board.apply(.insertElement(second))
        let secondConversion = try XCTUnwrap(SketchConversion.conversion(for: second, in: board))
        XCTAssertEqual(secondConversion.actionName, "Make Bidirectional")
        try board.apply(secondConversion.operation)

        let edges = board.elements.values.filter { $0.edge != nil }
        XCTAssertEqual(edges.count, 1, "no duplicate edge")
        XCTAssertEqual(edges.first?.edge?.semantic.direction, .both)
    }

    func testConversionUndoRestoresInk() throws {
        var (board, layer) = makeBoard()
        let ink = inkElement(
            sketchRectangle(x: 0, y: 0, width: 150, height: 90, jitterAmount: 2),
            layer: layer
        )
        try board.apply(.insertElement(ink))
        let before = board

        let conversion = try XCTUnwrap(SketchConversion.conversion(for: ink, in: board))
        let inverse = try board.apply(conversion.operation)
        try board.apply(inverse)
        XCTAssertEqual(board, before, "undo returns the exact ink stroke")
    }
}
