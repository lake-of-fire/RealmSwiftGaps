import SwiftUI
import RealmSwift

//// From https://www.mongodb.com/docs/realm/sdk/swift/crud/threading/#std-label-ios-async-write
//public extension Realm {
//    func writeAsync<T: ThreadConfined>(_ passedObject: T, errorHandler: @escaping ((_ error: Swift.Error) -> Void) = { _ in return }, block: @escaping ((Realm, T?) -> Void)) {
//        let objectReference = ThreadSafeReference(to: passedObject)
//        let configuration = self.configuration
//        DispatchQueue(label: "background", autoreleaseFrequency: .workItem).async {
//            do {
//                let realm = try Realm(configuration: configuration)
//                try realm.write {
//                    // Resolve within the transaction to ensure you get the latest changes from other threads
//                    let object = realm.resolve(objectReference)
//                    block(realm, object)
//                }
//            } catch {
//                errorHandler(error)
//            }
//        }
//    }
//}

public extension Realm {
    static func writeAsync<T: ThreadConfined>(_ passedObject: T, configuration: Realm.Configuration, block: @escaping ((Realm, T) -> Void)) {
        let ref = ThreadSafeReference(to: passedObject)
        Task { @RealmBackgroundActor in
            do {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                guard let object = realm.resolve(ref) else { return }
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    block(realm, object)
                }
            }
        }
    }
    
    static func writeAsync(configuration: Realm.Configuration, block: @escaping ((Realm) -> Void)) {
        Task { @RealmBackgroundActor in
            do {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    block(realm)
                }
            }
        }
    }
    
    @_unsafeInheritExecutor
    static func asyncWrite(configuration: Realm.Configuration, block: @escaping ((Realm) -> Void)) async throws {
        try await { @RealmBackgroundActor in
            do {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    block(realm)
                }
            }
        }()
    }
    
    @_unsafeInheritExecutor
    static func asyncWrite<T: ThreadConfined>(_ passedObject: ThreadSafeReference<T>, configuration: Realm.Configuration, block: @escaping ((Realm, T) -> Void)) async throws {
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            guard let object = realm.resolve(passedObject) else { return }
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                block(realm, object)
            }
        }()
    }
    
    @_unsafeInheritExecutor
    static func asyncWrite<T: ThreadConfined>(_ passedObjects: [ThreadSafeReference<T>], configuration: Realm.Configuration, block: @escaping ((Realm, T) -> Void)) async throws {
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let objects = passedObjects.compactMap { realm.resolve($0) }
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                for object in objects {
                    block(realm, object)
                }
            }
        }()
    }
}

///// Forked from:
///// https://github.com/realm/realm-swift/blob/9f7a605dfcf6a60e019a296dc8d91c3b23837a82/RealmSwift/SwiftUI.swift
///// and https://github.com/realm/realm-swift/issues/4818
//public func safeWrite<Value>(_ value: Value, configuration: Realm.Configuration? = nil, _ block: (Realm?, Value) -> Void) where Value: ThreadConfined {
//    let thawed = !value.isFrozen ? value : value.thaw() ?? value
//    var realm = thawed.realm
//    if realm?.isFrozen ?? false {
//        realm = realm?.thaw()
//    }
//    if realm == nil, let configuration = configuration {
//        realm = try! Realm(configuration: configuration)
//    }
//    if let realm = realm {
//        if realm.isInWriteTransaction {
//            block(realm, thawed)
//        } else {
//            try! realm.write {
//                block(realm, thawed)
//            }
//            // Needed to avoid err "Cannot register notifcaiton block from within write tranasaction"
//            // See @Brandon's comment: https://github.com/realm/realm-swift/issues/4818
////            realm.refresh()
//        }
//    } else {
//        block(nil, thawed)
//    }
//}
//
//public func safeWrite(configuration: Realm.Configuration = Realm.Configuration.defaultConfiguration, _ block: (Realm) -> Void) {
//    let realm = try! Realm(configuration: configuration)
//    if realm.isInWriteTransaction {
//        block(realm)
//    } else {
//        try! realm.write {
//            block(realm)
//        }
//        // Needed to avoid err "Cannot register notifcaiton block from within write tranasaction"
//        // See @Brandon's comment: https://github.com/realm/realm-swift/issues/4818
////        realm.refresh()
//    }
//}

extension URL: FailableCustomPersistable {
    public typealias PersistedType = String
    
    static let aboutBlankURL = URL(string: "about:blank")!
    
    public init?(persistedValue: String) {
        guard !persistedValue.isEmpty else {
            self = Self.aboutBlankURL
            return
        }
        guard let url = URL(string: persistedValue) else {
            self = Self.aboutBlankURL
            return
        }
        self = url
    }
    
    public var persistableValue: String {
        absoluteString
    }
    
    public static func _rlmDefaultValue() -> Self {
        .init(string: "about:blank")!
    }
}

public extension Object {
    var primaryKeyValue: String? {
        guard let pkName = type(of: self).sharedSchema()?.primaryKeyProperty?.name else { return nil }
        guard let pkType = type(of: self).sharedSchema()?.primaryKeyProperty?.type else { return nil }
        guard let pkValue = self.value(forKey: pkName) else { return nil }
        switch pkType {
        case .UUID:
            return (pkValue as? UUID)?.uuidString
        default:
            return pkValue as? String
        }
    }
    
    func isSameObjectByPrimaryKey(as other: Object?) -> Bool {
        guard let other = other else { return false }
        guard type(of: self) == type(of: other) else { return false }
        guard let pk1Value = self.primaryKeyValue else { return false }
        return !pk1Value.isEmpty && pk1Value == other.primaryKeyValue
    }
}

//public extension Results where Element: Object & Decodable {
//    func replace<O>(with objects: [O]) throws where O: Encodable {
//        let encodedObjects = try objects.map { try JSONEncoder().encode($0) }
//        let realmObjects = try encodedObjects.map { try JSONDecoder().decode(Element.self, from: $0) }
//        
//        safeWrite(self) { realm, results in
//            guard let realm = realm else {
//                print("No realm?")
//                return
//            }
//            
//            realm.add(realmObjects, update: .modified)
//            let addedPKs = Set(realmObjects.compactMap { $0.primaryKeyValue })
//            
//            for existingObject in self {
//                guard let existingPK = existingObject.primaryKeyValue else { continue }
//                if !addedPKs.contains(existingPK) {
//                    if existingObject.objectSchema.properties.contains(where: { $0.name == "isDeleted" }) {
//                        existingObject.setValue(true, forKey: "isDeleted")
//                    } else {
//                        realm.delete(existingObject)
//                    }
//                }
//            }
//        }
//    }
//}
//
//public extension BoundCollection where Value == Results<Element>, Element: Object & Decodable {
//    func replace<O>(with objects: [O]) throws where O: Encodable {
//        let encodedObjects = try objects.map { try JSONEncoder().encode($0) }
//        let realmObjects = try encodedObjects.map { try JSONDecoder().decode(Element.self, from: $0) }
//        
//        safeWrite(wrappedValue) { realm, results in
//            guard let realm = realm else {
//                print("No realm?")
//                return
//            }
//            
//            realm.add(realmObjects, update: .modified)
//            let addedPKs = Set(realmObjects.compactMap { $0.primaryKeyValue })
//            
//            for existingObject in self.wrappedValue {
//                guard let existingPK = existingObject.primaryKeyValue else { continue }
//                if !addedPKs.contains(existingPK) {
//                    if existingObject.objectSchema.properties.contains(where: { $0.name == "isDeleted" }) {
//                        existingObject.setValue(true, forKey: "isDeleted")
//                    } else {
//                        remove(existingObject)
//                    }
//                }
//            }
//        }
//    }
//}

///// See: https://github.com/realm/realm-swift/issues/7889
//@propertyWrapper
//public struct ObservedRealmCollection<Collection>: DynamicProperty where Collection: RealmCollection {
//    final private class Storage: ObservableObject {
//        var objects: Collection
//        var notificationToken: NotificationToken?
//
//        init(_ objects: Collection) {
//            self.objects = objects
//            self.notificationToken = objects.thaw()?.observe { changes in
//                switch changes {
//                case .initial:
//                    break;
//                case .update(let results, _, _, _):
//                    self.objects = results.freeze()
//                    self.objectWillChange.send()
//                case .error(let error):
//                    print(error.localizedDescription)
//                }
//            }
//        }
//    }
//    
//    @StateObject private var storage: Storage
//
//    public var wrappedValue: Collection { storage.objects }
//    
//    public init(wrappedValue: Collection) {
//        self._storage = .init(wrappedValue: Storage(wrappedValue))
//    }
//}

//public extension BoundCollection where Value == Results<Element>, Element: ObjectBase & ThreadConfined {
/*@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension BoundCollection where Value == Results<Element>, Element: ObjectBase & ThreadConfined {
    /// :nodoc:
    func remove(_ object: Value.Element) {
        guard let thawed = object.thaw(),
              let index = wrappedValue.thaw()?.index(of: thawed) else {
            return
        }
        safeWrite(self.wrappedValue) { results in
            results.realm?.delete(results[index])
        }
    }
    /// :nodoc:
    func remove(atOffsets offsets: IndexSet) {
        safeWrite(self.wrappedValue) { results in
            results.realm?.delete(Array(offsets.map { results[$0] }))
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension BoundCollection where Value == MutableSet<Element> {
    /// :nodoc:
    func remove(_ element: Value.Element) {
        safeWrite(self.wrappedValue) { mutableSet in
            mutableSet.remove(element)
        }
    }
    /// :nodoc:
    func insert(_ value: Value.Element) {
        safeWrite(self.wrappedValue) { mutableSet in
            mutableSet.insert(value)
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension BoundCollection where Value == MutableSet<Element>, Element: ObjectBase & ThreadConfined {
    /// :nodoc:
    func remove(_ object: Value.Element) {
        safeWrite(self.wrappedValue) { mutableSet in
            mutableSet.remove(thawObjectIfFrozen(object))
        }
    }
    /// :nodoc:
    func insert(_ value: Value.Element) {
        // if the value is unmanaged but the set is managed, we are adding this value to the realm
        if value.realm == nil && self.wrappedValue.realm != nil {
            SwiftUIKVO.observedObjects[value]?.cancel()
        }
        safeWrite(self.wrappedValue) { mutableSet in
            mutableSet.insert(thawObjectIfFrozen(value))
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension BoundCollection where Value == Results<Element>, Element: Object {
    /// :nodoc:
    func append(_ value: Value.Element) {
        if value.realm == nil && self.wrappedValue.realm != nil {
            SwiftUIKVO.observedObjects[value]?.cancel()
        }
        safeWrite(self.wrappedValue) { results in
            results.realm?.add(thawObjectIfFrozen(value))
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension BoundCollection where Value == Results<Element>, Element: ProjectionObservable & ThreadConfined, Element.Root: Object {
    /// :nodoc:
    func append(_ value: Value.Element) {
        if value.realm == nil && self.wrappedValue.realm != nil {
            SwiftUIKVO.observedObjects[value.rootObject]?.cancel()
        }
        safeWrite(self.wrappedValue) { results in
            results.realm?.add(thawObjectIfFrozen(value.rootObject))
        }
    }
}
*/
