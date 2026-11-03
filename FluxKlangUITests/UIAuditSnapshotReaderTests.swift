import XCTest

/// Pure metadata fixtures only: never constructs an application or calls read(in:).
@MainActor
final class UIAuditSnapshotReaderTests: XCTestCase {
    private let reader = UIAuditSnapshotReader()
    private let captureIdentifier = "fluxklang.audit.capture"

    func testAbsentRequiresExactIdentifierAndNeverReadsValues() {
        let counts = SnapshotReadCounts()
        let children = ["fluxklang.audit.capture.extra", "Fluxklang.audit.capture", ""].map {
            SnapshotFixture(identifier: $0, value: "ignored", counts: counts)
        }
        let root = SnapshotFixture(identifier: " fluxklang.audit.capture", children: children, counts: counts)

        XCTAssertEqual(reader.inspect(root), .absent)
        XCTAssertEqual(counts.identifiers, 4)
        XCTAssertEqual(counts.children, 4)
        XCTAssertEqual(counts.values, 0)
    }

    func testUniqueRootAndNestedValuesAreClassifiedWithoutChangingStrings() {
        let cases: [(Any?, UIAuditSnapshotReader.Observation)] = [
            (nil, .missingValue),
            ("", .receipt("")),
            ("{\"receipt\":\"e\u{301} 🎛\"}\n", .receipt("{\"receipt\":\"e\u{301} 🎛\"}\n")),
            (" \n{malformed\u{0000}", .receipt(" \n{malformed\u{0000}")),
            (42, .nonStringValue)
        ]
        for (value, expected) in cases {
            for nested in [false, true] {
                let counts = SnapshotReadCounts()
                let match = SnapshotFixture(identifier: captureIdentifier, value: value, counts: counts)
                let other = SnapshotFixture(value: "unrelated", counts: counts)
                let root: SnapshotFixture
                if nested {
                    let branch = SnapshotFixture(children: [match], counts: counts)
                    root = SnapshotFixture(children: [other, branch], counts: counts)
                } else {
                    match.childNodes = [other]
                    root = match
                }

                let observation = reader.inspect(root)
                XCTAssertEqual(observation, expected)
                if case let .receipt(original) = expected, case let .receipt(actual) = observation {
                    XCTAssertEqual(Array(actual.utf8), Array(original.utf8))
                }
                XCTAssertEqual(counts.values, 1)
                XCTAssertEqual(counts.children, nested ? 4 : 2)
                XCTAssertEqual(counts.childrenAtValueRead, [nested ? 4 : 2])
            }
        }
    }

    func testDuplicatesRefuseImmediatelyWithoutReadingEvenEqualValues() {
        for secondValue: Any? in ["same", "different", nil] {
            for rootMatches in [false, true] {
                let counts = SnapshotReadCounts()
                let first = SnapshotFixture(identifier: captureIdentifier, value: "same", counts: counts)
                let second = SnapshotFixture(identifier: captureIdentifier, value: secondValue, counts: counts)
                let unvisited = SnapshotFixture(identifier: captureIdentifier, value: "ignored", counts: counts)
                let root: SnapshotFixture
                if rootMatches {
                    first.childNodes = [unvisited, second]
                    root = first
                } else {
                    root = SnapshotFixture(children: [unvisited, second, first], counts: counts)
                }

                XCTAssertEqual(reader.inspect(root), .ambiguous)
                XCTAssertEqual(counts.values, 0)
                XCTAssertEqual(counts.identifiers, rootMatches ? 2 : 3)
                XCTAssertEqual(counts.children, rootMatches ? 1 : 2)
            }
        }
    }

    func testDeepTraversalAcceptsInclusiveLimitAndRefusesIncompleteUniquenessOrAbsence() {
        for nodeCount in [4096, 4097] {
            for hasCandidate in [false, true] {
                let counts = SnapshotReadCounts()
                let nodes = (0..<nodeCount).map { _ in SnapshotFixture(counts: counts) }
                // Retain every node and disconnect iteratively as well as building iteratively.
                defer { nodes.forEach { $0.childNodes = [] } }
                for index in 0..<(nodes.count - 1) {
                    nodes[index].childNodes = [nodes[index + 1]]
                }
                if hasCandidate {
                    // In the exceeded case a known candidate must not be read.
                    let candidate = nodeCount == 4096 ? nodes[nodeCount - 1] : nodes[0]
                    candidate.fixtureIdentifier = captureIdentifier
                    candidate.fixtureValue = "exact"
                }

                let expected: UIAuditSnapshotReader.Observation = nodeCount > 4096
                    ? .observationIncomplete : (hasCandidate ? .receipt("exact") : .absent)
                XCTAssertEqual(reader.inspect(nodes[0]), expected)
                XCTAssertEqual(counts.identifiers, 4096)
                XCTAssertEqual(counts.children, 4096)
                XCTAssertEqual(counts.values, nodeCount == 4096 && hasCandidate ? 1 : 0)
                XCTAssertEqual(counts.childrenAtValueRead, nodeCount == 4096 && hasCandidate ? [4096] : [])
            }
        }
    }

    func testWideTraversalBoundsPendingWorkBeforeAppendingChildren() {
        for childCount in [4095, 4096, 4097] {
            let counts = SnapshotReadCounts()
            let children = (0..<childCount).map { _ in SnapshotFixture(value: "ignored", counts: counts) }
            let root = SnapshotFixture(
                identifier: captureIdentifier, value: "root", children: children, counts: counts
            )

            XCTAssertEqual(reader.inspect(root), childCount == 4095 ? .receipt("root") : .observationIncomplete)
            // 4096 pending entries are permitted, but cannot all be visited after the root.
            // 4097 are rejected before any child is visited.
            XCTAssertEqual(counts.identifiers, childCount == 4097 ? 1 : 4096)
            XCTAssertEqual(counts.children, childCount == 4097 ? 1 : 4096)
            XCTAssertEqual(counts.values, childCount == 4095 ? 1 : 0)
            XCTAssertEqual(counts.childrenAtValueRead, childCount == 4095 ? [4096] : [])
        }
    }

    func testPendingCapacityIncludesAlreadyQueuedSiblings() {
        for branchChildCount in [1, 2] {
            let counts = SnapshotReadCounts()
            let siblings = (0..<4095).map { _ in SnapshotFixture(counts: counts) }
            let grandchildren = (0..<branchChildCount).map { _ in SnapshotFixture(counts: counts) }
            let branch = SnapshotFixture(children: grandchildren, counts: counts)
            let root = SnapshotFixture(
                identifier: captureIdentifier, value: "unread", children: siblings + [branch], counts: counts
            )

            XCTAssertEqual(reader.inspect(root), .observationIncomplete)
            XCTAssertEqual(counts.identifiers, branchChildCount == 1 ? 4096 : 2)
            XCTAssertEqual(counts.children, branchChildCount == 1 ? 4096 : 2)
            XCTAssertEqual(counts.values, 0)
        }
    }
}

@MainActor
private final class SnapshotReadCounts {
    var identifiers = 0
    var children = 0
    var values = 0
    var childrenAtValueRead: [Int] = []
}

@MainActor
private final class SnapshotFixture: NSObject, XCUIElementSnapshot {
    var fixtureIdentifier: String
    var fixtureValue: Any?
    var childNodes: [any XCUIElementSnapshot]
    private let counts: SnapshotReadCounts

    init(
        identifier: String = "",
        value: Any? = nil,
        children: [any XCUIElementSnapshot] = [],
        counts: SnapshotReadCounts
    ) {
        fixtureIdentifier = identifier
        fixtureValue = value
        childNodes = children
        self.counts = counts
        super.init()
    }

    var identifier: String {
        counts.identifiers += 1
        return fixtureIdentifier
    }

    var value: Any? {
        counts.values += 1
        counts.childrenAtValueRead.append(counts.children)
        return fixtureValue
    }

    var children: [any XCUIElementSnapshot] {
        counts.children += 1
        return childNodes
    }

    var dictionaryRepresentation: [XCUIElement.AttributeName: Any] {
        XCTFail("The reader must not convert snapshots to dictionaries")
        return [:]
    }

    let frame: CGRect = .zero
    let title = ""
    let label = ""
    let elementType: XCUIElement.ElementType = .other
    let isEnabled = true
    let horizontalSizeClass: XCUIElement.SizeClass = .unspecified
    let verticalSizeClass: XCUIElement.SizeClass = .unspecified
    let placeholderValue: String? = nil
    let isSelected = false
    let hasFocus = false
}
