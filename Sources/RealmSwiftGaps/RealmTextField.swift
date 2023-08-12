import SwiftUI
import Combine
import RealmSwift

@available(macOS 13.0, iOS 16.0, *)
public struct RealmTextField<ObjectType>: View where ObjectType: RealmSwift.Object & Identifiable {
    @ObservedRealmObject var object: ObjectType
    @Binding var objectValue: String
    
    @State var realtimeValue = ""
    @State var publisher = PassthroughSubject<String, Never>()
    var label: String
    
    var valueChanged: ((_ value: String) -> Void)?
    
    @State private var debounceSeconds = 1.110
    
    public var body: some View {
        TextField(label, text: $realtimeValue,  axis: .vertical)
            .disableAutocorrection(true)
            .task {
                Task { @MainActor in
                    realtimeValue = objectValue
                }
            }
            .onChange(of: realtimeValue) { value in
                publisher.send(value)
            }
            .onReceive(
                publisher.debounce(
                    for: .seconds(debounceSeconds),
                    scheduler: DispatchQueue.main
                )
            ) { value in
                if let valueChanged = valueChanged {
                    valueChanged(value)
                }
            }
    }
    
    public init(_ title: String, object: ObjectType, objectValue: Binding<String>) {
        self.object = object
        _objectValue = objectValue
        self.label = title
    }
}
