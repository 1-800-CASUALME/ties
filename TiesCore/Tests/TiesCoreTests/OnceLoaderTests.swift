import Testing
import Foundation
@testable import TiesCore

private enum OnceLoaderTestError: Error, Equatable {
    case boom
}

@Test func onceLoaderSharesASingleConcurrentLoad() async throws {
    // `CallCounter` is the actor shared across test files (see ScannerTests.swift).
    let counter = CallCounter()
    let loader = OnceLoader<Int> {
        let n = await counter.increment()
        try await Task.sleep(for: .milliseconds(50))
        return n
    }

    let results = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<10 {
            group.addTask { try await loader.value() }
        }
        var values: [Int] = []
        for try await value in group { values.append(value) }
        return values
    }

    #expect(results.count == 10)
    #expect(results.allSatisfy { $0 == 1 })   // every caller observed the one, first load
    #expect(await counter.count == 1)          // the loader body itself ran exactly once
}

@Test func onceLoaderRetriesAfterAFailure() async throws {
    let counter = CallCounter()
    let loader = OnceLoader<String> {
        let n = await counter.increment()
        if n == 1 { throw OnceLoaderTestError.boom }
        return "loaded"
    }

    await #expect(throws: OnceLoaderTestError.self) { try await loader.value() }
    let second = try await loader.value()
    #expect(second == "loaded")
    #expect(await counter.count == 2)
}
