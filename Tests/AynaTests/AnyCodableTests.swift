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
    func `ordinary fractional numbers continue decoding as Double`() throws {
        for expected in [0.1, 2.5, 1e-20] {
            let encoded = Data(String(expected).utf8)
            let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)

            #expect(decoded.value is Double)
            #expect(decoded.value as? Double == expected)
        }
    }

    @Test
    func `UInt64 max remains exact after decode and re-encode`() throws {
        let expected = String(UInt64.max)
        let encoded = try JSONEncoder().encode(AnyCodable(NSNumber(value: UInt64.max)))

        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        let reencoded = try JSONEncoder().encode(decoded)

        #expect(String(bytes: encoded, encoding: .utf8) == expected)
        #expect(Mirror(reflecting: decoded.value).displayStyle == .class)
        #expect((decoded.value as? NSNumber)?.stringValue == expected)
        #expect(reencoded == encoded)
    }

    @Test
    func `high-precision decimal remains exact after decode and re-encode`() throws {
        let expected = "1234567890.123456789012345678"
        let number = NSDecimalNumber(string: expected)
        let encoded = try JSONEncoder().encode(AnyCodable(number))

        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        let reencoded = try JSONEncoder().encode(decoded)

        #expect(String(bytes: encoded, encoding: .utf8) == expected)
        #expect(Mirror(reflecting: decoded.value).displayStyle == .class)
        #expect((decoded.value as? NSDecimalNumber)?.stringValue == expected)
        #expect(reencoded == encoded)
    }

    @Test
    func `large and high-precision decoded numbers compare exactly`() throws {
        let unsignedMax = try JSONDecoder().decode(
            AnyCodable.self,
            from: Data(String(UInt64.max).utf8)
        )
        let unsignedPredecessor = try JSONDecoder().decode(
            AnyCodable.self,
            from: Data(String(UInt64.max - 1).utf8)
        )
        let decimal = try JSONDecoder().decode(
            AnyCodable.self,
            from: Data("1234567890.123456789012345678".utf8)
        )
        let adjacentDecimal = try JSONDecoder().decode(
            AnyCodable.self,
            from: Data("1234567890.123456789012345679".utf8)
        )

        #expect(unsignedMax == unsignedMax)
        #expect(unsignedMax != unsignedPredecessor)
        #expect(decimal == decimal)
        #expect(decimal != adjacentDecimal)
        #expect(AnyCodable(NSNumber(value: 1)) != AnyCodable(NSNumber(value: true)))
    }

    @Test
    func `nested decoded numbers use exact equality`() throws {
        let first = try JSONDecoder().decode(
            AnyCodable.self,
            from: Data(#"{"values":[18446744073709551615,1234567890.123456789012345678]}"#.utf8)
        )
        let same = try JSONDecoder().decode(
            AnyCodable.self,
            from: Data(#"{"values":[18446744073709551615,1234567890.123456789012345678]}"#.utf8)
        )
        let different = try JSONDecoder().decode(
            AnyCodable.self,
            from: Data(#"{"values":[18446744073709551614,1234567890.123456789012345679]}"#.utf8)
        )

        #expect(first == same)
        #expect(first != different)
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
