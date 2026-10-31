import Testing
@testable import Regards

struct CadenceDescriptorTests {

    @Test("A cadence of 0 or fewer days reads as not tracked, not as a schedule", arguments: [0, -1, -7, -14])
    func nonPositiveCadenceReadsAsNotTracked(days: Int) {
        #expect(CadenceDescriptor.describe(days: days) == "not tracked")
    }

    @Test("Preset and custom cadences keep their wording", arguments: [
        (1, "daily"), (7, "weekly"), (14, "every 2 weeks"), (30, "monthly"),
        (365, "yearly"), (10, "every 10 days"), (35, "every 5 weeks"),
    ])
    func positiveCadencesKeepTheirWording(days: Int, expected: String) {
        #expect(CadenceDescriptor.describe(days: days) == expected)
    }

    /// Owner ruling 6 on PR #66: a corrupt 0-day cadence reads like no cadence
    /// on All Contacts, since such a contact gets no reminders.
    @Test("The All Contacts row leaves out the cadence segment for no cadence or one under 1 day",
          arguments: [Int?.none, 0, -1, -14])
    func allContactsRowOmitsTheSegmentWithoutAWorkableCadence(days: Int?) {
        #expect(AllContactsViewModel.cadenceSegment(days: days) == nil)
    }

    @Test("The All Contacts row shows the cadence wording from 1 day up", arguments: [
        (1, "daily"), (7, "weekly"), (10, "every 10 days"), (365, "yearly"),
    ])
    func allContactsRowShowsThePositiveCadence(days: Int, expected: String) {
        #expect(AllContactsViewModel.cadenceSegment(days: days) == expected)
    }
}
