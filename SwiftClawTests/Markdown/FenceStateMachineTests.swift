import Foundation
import Testing
@testable import SwiftClaw

#if os(macOS)
/// Regression coverage for the review finding that `FenceStateMachine`
/// tracked only the fence *character*, not its run length — so a four-
/// backtick opener would incorrectly close on any three-backtick line inside
/// its own content. These construct the state machine directly (it's an
/// internal, not private, type) rather than going through the highlighter's
/// styling attributes, per the preference for a small testable helper.
@MainActor
struct FenceStateMachineTests {
    @Test func fourBacktickOpenerStaysOpenAcrossAThreeBacktickLineInsideItsContent() {
        let text = "````\nsome content\n```\nstill inside\n````\nafter"
        var machine = FenceStateMachine()
        machine.recompute(for: text)

        #expect(machine.isInsideFence(atLine: 0) == false) // the opening ```` line itself
        #expect(machine.isInsideFence(atLine: 1) == true)
        #expect(machine.isInsideFence(atLine: 2) == true) // the inner ``` line must not close it
        #expect(machine.isInsideFence(atLine: 3) == true)
        #expect(machine.isInsideFence(atLine: 4) == true) // the matching ```` closer starts inside
        #expect(machine.isInsideFence(atLine: 5) == false)
    }

    @Test func aLongerClosingRunThanTheOpenerStillClosesTheFence() {
        let text = "```\ncontent\n````\nafter"
        var machine = FenceStateMachine()
        machine.recompute(for: text)

        #expect(machine.isInsideFence(atLine: 0) == false)
        #expect(machine.isInsideFence(atLine: 1) == true)
        #expect(machine.isInsideFence(atLine: 2) == true) // the closer line itself starts inside
        #expect(machine.isInsideFence(atLine: 3) == false)
    }

    @Test func tildeFencesTrackRunLengthTheSameWayAsBackticks() {
        let text = "~~~~\n~~~\nstill inside\n~~~~\nafter"
        var machine = FenceStateMachine()
        machine.recompute(for: text)

        #expect(machine.isInsideFence(atLine: 0) == false)
        #expect(machine.isInsideFence(atLine: 1) == true)
        #expect(machine.isInsideFence(atLine: 2) == true) // the inner ~~~ line must not close it
        #expect(machine.isInsideFence(atLine: 3) == true)
        #expect(machine.isInsideFence(atLine: 4) == false)
    }

    @Test func aDifferentMarkerCharacterNeverClosesTheFence() {
        let text = "````\n~~~\nstill inside\n````\nafter"
        var machine = FenceStateMachine()
        machine.recompute(for: text)

        #expect(machine.isInsideFence(atLine: 1) == true)
        #expect(machine.isInsideFence(atLine: 2) == true) // the ~~~ line never matches the ` opener
        #expect(machine.isInsideFence(atLine: 3) == true)
        #expect(machine.isInsideFence(atLine: 4) == false)
    }

    /// Regression coverage for the review finding that any run of the marker
    /// character long enough to close the fence was accepted as a closer,
    /// even with trailing non-whitespace content — so a line like `` ```swift ``
    /// nested inside a four-backtick fence was treated as closing it instead
    /// of being ordinary content. Per CommonMark, only spaces/tabs may follow
    /// a closing fence's marker run.
    @Test func aLongBacktickRunFollowedByNonWhitespaceStaysInsideTheFence() {
        let text = "````\n```swift\nstill inside\n````\nafter"
        var machine = FenceStateMachine()
        machine.recompute(for: text)

        #expect(machine.isInsideFence(atLine: 0) == false)
        #expect(machine.isInsideFence(atLine: 1) == true)
        #expect(machine.isInsideFence(atLine: 2) == true) // "```swift" is content, not a closer
        #expect(machine.isInsideFence(atLine: 3) == true)
        #expect(machine.isInsideFence(atLine: 4) == false)
    }

    @Test func aTildeRunFollowedByNonWhitespaceStaysInsideTheFence() {
        let text = "~~~~\n~~~diff\nstill inside\n~~~~\nafter"
        var machine = FenceStateMachine()
        machine.recompute(for: text)

        #expect(machine.isInsideFence(atLine: 1) == true)
        #expect(machine.isInsideFence(atLine: 2) == true) // "~~~diff" is content, not a closer
        #expect(machine.isInsideFence(atLine: 3) == true)
        #expect(machine.isInsideFence(atLine: 4) == false)
    }

    @Test func aClosingRunWithOnlyTrailingWhitespaceStillClosesTheFence() {
        let text = "````\ncontent\n````  \t \nafter"
        var machine = FenceStateMachine()
        machine.recompute(for: text)

        #expect(machine.isInsideFence(atLine: 1) == true)
        #expect(machine.isInsideFence(atLine: 2) == true) // the closer line itself starts inside
        #expect(machine.isInsideFence(atLine: 3) == false)
    }
}
#endif
