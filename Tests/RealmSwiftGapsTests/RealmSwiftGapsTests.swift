import XCTest
import RealmSwift
@testable import RealmSwiftGaps

final class RealmSwiftGapsTests: XCTestCase {
    func testURLPersistableValue_roundTripsAbsoluteString() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/path?q=reader#section"))

        XCTAssertEqual(url.persistableValue, "https://example.com/path?q=reader#section")
        XCTAssertEqual(URL(persistedValue: url.persistableValue), url)
    }

    func testURLPersistedValue_emptyStringUsesAboutBlank() throws {
        XCTAssertEqual(URL(persistedValue: ""), URL(string: "about:blank"))
        XCTAssertEqual(URL._rlmDefaultValue(), URL(string: "about:blank"))
    }

    func testObjectPrimaryKeyValue_supportsStringAndUUIDPrimaryKeys() throws {
        let stringObject = StringPrimaryKeyObject()
        stringObject.id = "reader"

        let uuid = UUID()
        let uuidObject = UUIDPrimaryKeyObject()
        uuidObject.id = uuid

        XCTAssertEqual(stringObject.primaryKeyValue, "reader")
        XCTAssertEqual(uuidObject.primaryKeyValue, uuid.uuidString)
        XCTAssertTrue(stringObject.isSameObjectByPrimaryKey(as: StringPrimaryKeyObject(value: ["id": "reader"])))
        XCTAssertFalse(stringObject.isSameObjectByPrimaryKey(as: StringPrimaryKeyObject(value: ["id": "other"])))
    }
}

@objc(RealmSwiftGapsStringPrimaryKeyObject)
private final class StringPrimaryKeyObject: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) var id = ""
}

@objc(RealmSwiftGapsUUIDPrimaryKeyObject)
private final class UUIDPrimaryKeyObject: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) var id = UUID()
}
