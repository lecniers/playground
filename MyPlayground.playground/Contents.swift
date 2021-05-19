import UIKit
import Foundation
import MyPlayground_Sources
import PlaygroundSupport
import Combine
import SwiftUI

PlaygroundPage.current.needsIndefiniteExecution = true

private extension Dictionary where Key == UUID {
    mutating func insert(_ value: Value) -> UUID {
        let id = UUID()
        self[id] = value
        return id
    }
}

public class ADTSignal<T> {
    public init() {
    }
    
    @discardableResult
    public func observe<Observer: AnyObject>(_ observer: Observer, closure: @escaping (Observer, T) -> Void) -> ADTObservationToken {
        return ADTObservationToken { }
    }
}
// This is a simple solution is not thread safe yet
public class ADTPublisher<T>: ADTSignal<T> {
    public typealias EventHandler = (T) -> Void
    private var observations = [UUID: EventHandler]()
    
    public override init() {
        super.init()
    }
      
    @discardableResult
    public override func observe<Observer: AnyObject>(_ observer: Observer, closure: @escaping (Observer, T) -> Void) -> ADTObservationToken {
        let id = UUID()
        observations[id] = { [weak self, weak observer] data in
            // If the observer has been deallocated, we can
            // automatically remove the observation closure.
            guard let observer = observer else {
                self?.observations.removeValue(forKey: id)
                return
            }

            closure(observer, data)
        }
        return ADTObservationToken { [weak self] in
            self?.observations.removeValue(forKey: id)
        }
    }

    public func raise(data: T) {
        observations.values.forEach { closure in
            closure(data)
        }
    }
}

// This is a simple solution is not thread safe yet
public class ADTBindable<Value> {
    public typealias EventHandler = (Value) -> Void
    private var observations = [UUID: EventHandler]()
    public private(set) var lastValue: Value
    
    public init(_ value: Value) {
        lastValue = value
    }
      
    @discardableResult
    public func observe<Observer: AnyObject>(_ observer: Observer, closure: @escaping (Observer, Value) -> Void) -> ADTObservationToken {
        // If we already have a value available, we'll give the
        // handler access to it directly.
        closure(observer, lastValue)
//        lastValue.map { closure(observer, $0) }
        
        let id = UUID()
        observations[id] = { [weak self, weak observer] data in
            // If the observer has been deallocated, we can
            // automatically remove the observation closure.
            guard let observer = observer else {
                self?.observations.removeValue(forKey: id)
                return
            }

            closure(observer, data)
        }
        return ADTObservationToken { [weak self] in
            self?.observations.removeValue(forKey: id)
        }
    }

    fileprivate func raise(data: Value) {
        lastValue = data
        observations.values.forEach { closure in
            closure(data)
        }
    }
    
    @discardableResult
    public func bind<Observer: AnyObject, T>(_ sourceKeyPath: KeyPath<Value, T>, to object: Observer, _ objectKeyPath: ReferenceWritableKeyPath<Observer, T>) -> ADTObservationToken {
        return observe(object) { object, observed in
            let value = observed[keyPath: sourceKeyPath]
            object[keyPath: objectKeyPath] = value
        }
    }
    
    @discardableResult
    public func bind<Observer: AnyObject, T>(_ sourceKeyPath: KeyPath<Value, T>, to object: Observer, _ objectKeyPath: ReferenceWritableKeyPath<Observer, T?>) -> ADTObservationToken {
        return observe(object) { object, observed in
            let value = observed[keyPath: sourceKeyPath]
            object[keyPath: objectKeyPath] = value
        }
    }
}

@propertyWrapper
public class ADTDriver<Value> {
    
    private let bindable: ADTBindable<Value>
    public var projectedValue: ADTBindable<Value> {
        return bindable
    }
    public var wrappedValue: Value {
        get {
            assert(Thread.current.isMainThread, "ADTDriver value get should be called only from the MainThread")
            return bindable.lastValue
        }
        set {
            if Thread.current.isMainThread {
                projectedValue.raise(data: newValue)
            } else {
                GCD.main.queue.async(flags: .barrier) {[weak self] in
                    self?.projectedValue.raise(data: newValue)
                }
            }
        }
    }
    
    public init(wrappedValue: Value) {
        assert(Thread.current.isMainThread, "ADTDriver init should be called only from the MainThread")
        self.bindable = ADTBindable(wrappedValue)
    }
}

extension ADTDriver where Value: Equatable {
    @discardableResult
    public func setIfChanged(_ newValue: Value) -> Bool {
        guard wrappedValue != newValue else { return false }
        wrappedValue = newValue
        return true
    }
}

public class ADTObservationToken {
    private let cancellationClosure: () -> Void

    init(cancellationClosure: @escaping () -> Void) {
        self.cancellationClosure = cancellationClosure
    }

    public func cancel() {
        cancellationClosure()
    }
}

/// Relay that automanages cancellation
public class ADTRelay<Value> {
    fileprivate let storage: CurrentValueSubject<Value, Never>
    private var observations = [UUID: AnyCancellable]()
    
    public var value: Value {
        storage.value
    }
    public var publisher: AnyPublisher<Value, Never> {
        storage.eraseToAnyPublisher()
    }
    
    public init(_ value: Value) {
        storage = .init(value)
    }
    
    /// internally calls sink, but will auto-manage the observer and subscription
    /// Call ADTObservationToken.cancel() to kill the subscription
    /// When the server deallocates will kill the subscription
    @discardableResult
    public func observe<Observer: AnyObject>(_ observer: Observer, closure: @escaping (Observer, Value) -> Void) -> ADTObservationToken {
        let id = UUID()
        // create a subscription capturing the observer (to cancel the subscription on deallocating the observer)
        observations[id] = storage.sink { [weak self, weak observer] value in
            guard let self = self else { return }
            
            // If the observer has been deallocated, we can remove the subscription
            guard let observer = observer else {
                self.cancelSubscription(id: id)
                return
            }
            closure(observer, value)
        }
        
        return ADTObservationToken { [weak self] in
            self?.cancelSubscription(id: id)
        }
    }
    
    private func cancelSubscription(id: UUID) {
        if observations.removeValue(forKey: id) != nil {
            print("Subscription removed: \(id)")
        }
    }

    /// emit a new value
    fileprivate func raise(data: Value) {
        storage.send(data)
    }
    
    @discardableResult
    public func bind<Observer: AnyObject, T>(_ sourceKeyPath: KeyPath<Value, T>, to object: Observer, _ objectKeyPath: ReferenceWritableKeyPath<Observer, T>) -> ADTObservationToken {
        return observe(object) { object, observed in
            let value = observed[keyPath: sourceKeyPath]
            object[keyPath: objectKeyPath] = value
        }
    }

    @discardableResult
    public func bind<Observer: AnyObject, T>(_ sourceKeyPath: KeyPath<Value, T>, to object: Observer, _ objectKeyPath: ReferenceWritableKeyPath<Observer, T?>) -> ADTObservationToken {
        return observe(object) { object, observed in
            let value = observed[keyPath: sourceKeyPath]
            object[keyPath: objectKeyPath] = value
        }
    }
}

extension ADTRelay: Publisher {
    public typealias Output = Value
    public typealias Failure = Never
    
    // Combine will call this method on our publisher whenever
    // a new object started observing it. Within this method,
    public func receive<S: Subscriber>( subscriber: S)
        where S.Input == Output, S.Failure == Failure {
        self.storage.receive(subscriber: subscriber)
    }
}

@propertyWrapper
class ADTPublished<Value> {
    private let bindable: ADTRelay<Value>
    public var projectedValue: ADTRelay<Value> {
        return bindable
    }
    
    init(wrappedValue value: Value) {
        self.bindable = .init(value)
    }

    var wrappedValue: Value {
        get { bindable.value }
        set { bindable.raise(data: newValue) }
    }
}

@dynamicMemberLookup
final class Observable<Value>: ObservableObject {
    @Published private(set) var value: Value
    private var cancellable: AnyCancellable?

    init<T: Publisher>(
        value: Value,
        publisher: T
    ) where T.Output == Value, T.Failure == Never {
        self.value = value
        self.cancellable = publisher.assign(to: \.value, on: self)
    }

    subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
        value[keyPath: keyPath]
    }
}

extension CurrentValueSubject where Failure == Never {
    func asObservable() -> Observable<Output> {
        Observable(value: value, publisher: self)
    }
}

struct Podcast{
    let name: String
}

class ADTStore {
    @ADTDriver public private(set) var nums: Int = 1
    let subject: CurrentValueSubject<Podcast, Never>
    @ADTPublished public private(set) var published: Int = 1
    
    var relay = ADTRelay(1)
    
    init() {
        self.subject = CurrentValueSubject(Podcast(name: "First"))
    }
    
    func emit(num: Int) {
        _nums.setIfChanged(num)
        subject.send(Podcast(name: "num_\(num)"))
        self.published = num
        relay.raise(data: num)
    }
    
    func freeRelay() {
        relay = ADTRelay(100)
    }
}

var store = ADTStore()

class TempView {
    init(store: ADTStore) {
        store.$published.observe(self) { this, value in
            print("got published - obse: \(value) - from TempView")
        }
    }
}

class Listener {
//    @ObservedObject var podcast: Observable<Podcast>
    private var subscriptions = Set<AnyCancellable>()
    
    var cancelToken: ADTObservationToken?
    
    var tempView: TempView?
    
    init(store: ADTStore) {
        self.tempView = TempView(store: store)
//        self.podcast = store.subject.asObservable()
//        store.$nums.observe(self) { this, value in
//            print("got value: \(value)")
//        }
//
//        store.subject.sink { podcast in
//            print("got podcast: \(podcast.name)")
//        }.store(in: &subscriptions)
//
        // SwiftUI/Combine way
        store.$published.sink { val in
            print("got published - sink: \(val)")
        }.store(in: &subscriptions)
        
        // our way that auto-manages self reference and subscription lifecycle
        cancelToken = store.$published.observe(self) { this, value in
            print("got published - obse: \(value) - \(this.subscriptions.count)")
            
            // test cancelling this subs
            if value > 15 {
                this.cancelToken?.cancel()
                this.cancelToken = nil
                this.tempView = nil
            }
        }
    }
}

var listener = Listener(store: store)

var greeting = "Hello, playground"

DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
//    store.emit(num: 2)
//    store.freeRelay()
    (10...19).publisher.sink { value in
        store.emit(num: value)
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    store.emit(num: 100)
    print("Done")
    PlaygroundPage.current.finishExecution()
}

print("Wait")





