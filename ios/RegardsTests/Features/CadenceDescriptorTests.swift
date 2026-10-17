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
}
