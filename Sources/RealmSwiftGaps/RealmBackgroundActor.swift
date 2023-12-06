import Foundation

@globalActor
public actor RealmBackgroundActor {
    public static var shared = RealmBackgroundActor()
    
    public init() { }
}
