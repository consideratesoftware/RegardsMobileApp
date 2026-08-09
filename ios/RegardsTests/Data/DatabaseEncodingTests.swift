import Foundation
import Testing
@testable import Regards

struct DatabaseEncodingTests {
    @Test("Migration JSON helper rejects invalid UTF-8")
    func migrationJSONHelperRejectsInvalidUTF8() {
        #expect(throws: DataError.invalidJSONEncoding) {
            _ = try JSONEncoder.regardsJSONString(from: Data([0xFF]))
        }
    }
}
