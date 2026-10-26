import Foundation
import Testing
@testable import SuperTrackpadCore

@Test func previewSnapsNewContactsAndRemovesLiftedContacts() {
    var filter = TouchSmoothing()
    let first = Contact(id: 1, x: 0.2, y: 0.3)
    filter.receive([first], at: 0)
    #expect(filter.render(at: 0) == [first])
    filter.receive([], at: 0.005)
    // Reused IDs must not slide in from a previous touch between display ticks.
    let next = Contact(id: 1, x: 0.8, y: 0.9)
    filter.receive([next], at: 0.006)
    #expect(filter.render(at: 0.008) == [next])
    filter.receive([], at: 0.009)
    #expect(filter.render(at: 0.016).isEmpty)
}

@Test func smoothingStaysBetweenMeasurementsAndConvergesAcrossRefreshRates() {
    var results: [Double] = []
    for hz in [60.0, 120.0] {
        var filter = TouchSmoothing()
        filter.receive([Contact(id: 1, x: 0.2, y: 0.8, pressure: 0)], at: 0)
        _ = filter.render(at: 0)
        for frame in 1...Int(hz / 10) {
            let time = Double(frame) / hz
            filter.receive([Contact(id: 1, x: 0.8, y: 0.2, pressure: 1)], at: time)
            let drawn = filter.render(at: time)[0]
            #expect((0.2...0.8).contains(drawn.position.x))
            #expect((0.2...0.8).contains(drawn.position.y))
            #expect((0...1).contains(drawn.pressure!))
        }
        results.append(filter.contacts[0].position.x)
    }
    #expect(abs(results[0] - results[1]) < 0.000_001)
    #expect(abs(results[0] - 0.8) < 0.000_01)
}

@Test func previewExpiresStaleInputAndRejectsOutOfOrderFrames() {
    var filter = TouchSmoothing()
    let contact = Contact(id: 1, x: 0.5, y: 0.5)
    filter.receive([contact], at: 10)
    filter.receive([], at: 9)
    #expect(filter.render(at: 10) == [contact])
    #expect(filter.render(at: 10.251).isEmpty)
    filter.receive([contact], at: 11)
    #expect(filter.render(at: 11) == [contact])
    filter.reset()
    #expect(filter.render(at: 11.01).isEmpty)
}

@Test func pressureCueIsOptionalBoundedAndNeverClaimsInvalidForce() {
    for value: Double? in [nil, -.infinity, .infinity, .nan, -1, 0] {
        #expect(Contact(id: 1, x: 0.5, y: 0.5, pressure: value).pressureIntensity == 0)
    }
    let values = [0.1, 0.5, 1, 10, Double.greatestFiniteMagnitude].map {
        Contact(id: 1, x: 0.5, y: 0.5, pressure: $0).pressureIntensity
    }
    #expect(values == values.sorted())
    #expect(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
}

@Test func pressureDoesNotChangeRecognitionOrCalibration() {
    var plain = GestureRecognizer(), force = GestureRecognizer()
    var plainTrainer = TipTapCalibration(), forceTrainer = TipTapCalibration()
    let frames: [(Double, [Contact])] = [
        (0, [.init(id: 1, x: 0.5, y: 0.5)]),
        (0.2, [.init(id: 1, x: 0.5, y: 0.5), .init(id: 2, x: 0.75, y: 0.5)]),
        (0.28, [.init(id: 1, x: 0.5, y: 0.5)]),
        (0.4, [])
    ]
    for (time, contacts) in frames {
        let pressured = contacts.map { contact in
            var contact = contact; contact.pressure = time * 10; return contact
        }
        #expect(plain.process(contacts, at: time) == force.process(pressured, at: time))
        #expect(plainTrainer.process(contacts, at: time, aspectRatio: 1.6) ==
                forceTrainer.process(pressured, at: time, aspectRatio: 1.6))
    }
}

@Test func displaySamplingCutsTrackingDelayWithoutPrediction() {
    // Deterministic motion replay, not a hardware FPS benchmark. Compare the old
    // 30 Hz gate with the new presentation path at 60 and 120 Hz display ticks.
    for hz in [60.0, 120.0] {
        var filter = TouchSmoothing()
        var oldPosition = 0.2, oldPaint = 0.0
        var oldError = 0.0, newError = 0.0, oldFrames = 0
        let speed = 0.4
        for index in 0...Int(hz) {
            let elapsed = Double(index) / hz, time = 100 + elapsed
            let contact = Contact(id: 1, x: 0.2 + elapsed * speed, y: 0.5)
            if time - oldPaint > 1.0 / 30 {
                oldPosition = contact.position.x; oldPaint = time; oldFrames += 1
            }
            filter.receive([contact], at: time)
            let drawn = filter.render(at: time)[0]
            #expect(drawn.position.x <= contact.position.x)
            oldError += contact.position.x - oldPosition
            newError += contact.position.x - drawn.position.x
        }
        let count = hz + 1
        let newDelay = newError / count / speed
        #expect(newError < oldError / 2)
        #expect(newDelay < 0.006)
        print("Synthetic \(Int(hz)) Hz replay: old \(oldFrames) position updates; old mean lag \(oldError / count / speed * 1000) ms, new \(newDelay * 1000) ms")
    }
}
