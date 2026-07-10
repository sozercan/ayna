//
//  AnyCodableTests.swift
//  AynaTests
//
//  Focused regression tests for NSNumber encoding.
//

@testable import Ayna
import Foundation
import Testing

@Suite("AnyCodable Tests", .tags(.fast))
struct AnyCodableTests {
    @Test
    func `JSONSerialization integers re-encode as numbers`() throws {
        let data = Data(#"{"line":1,"offset":0,"count":2}"#.utf8)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let wrapped = object.mapValues(AnyCodable.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(wrapped)
        let encodedString = try #require(String(bytes: encoded, encoding: .utf8))

        #expect(encodedString == #"{"count":2,"line":1,"offset":0}"#)
    }

    @Test
    func `JSONSerialization booleans remain booleans`() throws {
        let data = Data(#"{"enabled":true,"disabled":false}"#.utf8)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let wrapped = object.mapValues(AnyCodable.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(wrapped)
        let encodedString = try #require(String(bytes: encoded, encoding: .utf8))

        #expect(encodedString == #"{"disabled":false,"enabled":true}"#)
    }

    @Test
    func `high-precision NSDecimalNumber encodes losslessly`() throws {
        let number = NSDecimalNumber(string: "1234567890.123456789012345678")

        let encoded = try JSONEncoder().encode(AnyCodable(number))
        let decoded = try JSONDecoder().decode(Decimal.self, from: encoded)

        #expect(decoded == number.decimalValue)
    }

    @Test
    func `native Swift numeric types preserve null fallback`() throws {
        let values: [Any] = [Float(1.5), Int8(1), CGFloat(1.5)]

        for value in values {
            let encoded = try JSONEncoder().encode(AnyCodable(value))
            #expect(String(bytes: encoded, encoding: .utf8) == "null")
        }
    }

    @Test
    func `signed Foundation integers use full Int64 range`() throws {
        let cases: [(number: NSNumber, expected: String)] = [
            (NSNumber(value: Int64(-2_147_483_649)), "-2147483649"),
            (NSNumber(value: Int64.min), String(Int64.min))
        ]

        for testCase in cases {
            let encoded = try JSONEncoder().encode(AnyCodable(testCase.number))
            #expect(String(bytes: encoded, encoding: .utf8) == testCase.expected)
        }
    }

    @Test
    func `large unsigned Foundation integers remain exact numbers`() throws {
        for expected in [UInt64(1) << 63, UInt64.max] {
            let encoded = try JSONEncoder().encode(AnyCodable(NSNumber(value: expected)))
            #expect(String(bytes: encoded, encoding: .utf8) == String(expected))
        }
    }

    @Test
    func `finite class-backed floating NSNumber values encode as numbers`() throws {
        let float = Float(1.5)
        let double = Double(2.25)
        let cgFloat = CGFloat(3.5)
        let cases: [(number: NSNumber, expected: Double)] = [
            (NSNumber(value: float), Double(float)),
            (NSNumber(value: double), double),
            (NSNumber(value: cgFloat), Double(cgFloat))
        ]

        for testCase in cases {
            #expect(Mirror(reflecting: testCase.number).displayStyle == .class)

            let encoded = try JSONEncoder().encode(AnyCodable(testCase.number))
            let decoded = try JSONDecoder().decode(Double.self, from: encoded)

            #expect(decoded == testCase.expected)
        }
    }

    @Test
    func `nonfinite Foundation numbers preserve null fallback`() throws {
        let values: [NSNumber] = [
            NSDecimalNumber.notANumber,
            NSNumber(value: Double.nan),
            NSNumber(value: Double.infinity)
        ]

        for value in values {
            let encoded = try JSONEncoder().encode(AnyCodable(value))
            #expect(String(bytes: encoded, encoding: .utf8) == "null")
        }
    }
}
