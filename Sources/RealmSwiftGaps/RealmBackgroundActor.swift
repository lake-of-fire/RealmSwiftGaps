import Foundation
import Realm
import RealmSwift

extension RealmSwiftObject: @unchecked Sendable { }

public enum RealmBackgroundActorError: Error {
    case unableToResolveObject
}

@globalActor
public actor RealmBackgroundActor {
    public static var shared = RealmBackgroundActor()
    
    public init() { }
    
    public func run(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            print("Realm operation failed: \(error.localizedDescription)")
        }
    }
    
    public func write<T: ThreadConfined>(_ reference: ThreadSafeReference<T>, configuration: Realm.Configuration, operation: @escaping (T) throws -> Void) async throws {
        let realm = try await Realm(configuration: configuration, actor: self)
        guard let resolvedObject = realm.resolve(reference) else { throw RealmBackgroundActorError.unableToResolveObject }
        
        try await realm.asyncWrite {
            try operation(resolvedObject)
        }
    }
}
