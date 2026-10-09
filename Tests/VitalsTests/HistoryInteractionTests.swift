import XCTest
@testable import Vitals

final class HistoryInteractionTests: XCTestCase {
    private let points = [
        HistoryPoint(time: 100, value: 0.2, startsSegment: true),
        HistoryPoint(time: 105, value: 0.8, startsSegment: false),
        HistoryPoint(time: 200, value: 0.4, startsSegment: true),
        HistoryPoint(time: 205, value: 0.6, startsSegment: false)
    ]

    func testPointerMapsToActualWindowAndClampsAtEdges() {
        XCTAssertEqual(HistoryInspection.time(at: 0, end: 1000, duration: 300), 700)
        XCTAssertEqual(HistoryInspection.time(at: 0.5, end: 1000, duration: 300), 850)
        XCTAssertEqual(HistoryInspection.time(at: 1, end: 1000, duration: 3600), 1000)
        XCTAssertEqual(HistoryInspection.time(at: -1, end: 4000, duration: 3600), 400)
        XCTAssertEqual(HistoryInspection.time(at: 2, end: 4000, duration: 3600), 4000)
    }

    func testInspectionSelectsNearestRecordedPeakWithoutBridgingSleep() {
        XCTAssertEqual(HistoryInspection.sample(in: points, at: 101), points[0])
        XCTAssertEqual(HistoryInspection.sample(in: points, at: 104), points[1])
        XCTAssertEqual(HistoryInspection.sample(in: points, at: 105), points[1])
        XCTAssertNil(HistoryInspection.sample(in: points, at: 106))
        XCTAssertNil(HistoryInspection.sample(in: points, at: 150))
        XCTAssertNil(HistoryInspection.sample(in: points, at: 199))
        XCTAssertEqual(HistoryInspection.sample(in: points, at: 200), points[2])
    }

    func testEmptyAndUnrecordedPartsOfWindowHaveNoReading() {
        XCTAssertNil(HistoryInspection.sample(in: [], at: 100))
        XCTAssertNil(HistoryInspection.sample(in: points, at: 50))
        XCTAssertNil(HistoryInspection.sample(in: points, at: 220))
        XCTAssertEqual(HistoryInspection.sample(in: points, at: 208), points.last)
        XCTAssertEqual(HistoryInspection.sample(in: [points[0]], at: 100), points[0])
    }

    func testPinPreservesBothNetworkReadingsWhenLiveBucketChanges() {
        var download = MetricHistory()
        var upload = MetricHistory()
        download.append(2000, at: 101, interval: 1)
        upload.append(100, at: 101, interval: 1)
        let pin = HistoryInspection(time: 101, points: [
            download.points(endingAt: 101, duration: 300),
            upload.points(endingAt: 101, duration: 300)
        ])
        download.append(9000, at: 102, interval: 1)
        upload.append(800, at: 102, interval: 1)
        XCTAssertEqual(pin.samples.map { $0?.value }, [2000, 100])
        XCTAssertEqual(pin.samples.map { $0?.time }, [101, 101])
        XCTAssertEqual(download.points(endingAt: 102, duration: 300).last?.value, 9000)
    }

    func testMissingSeriesDoesNotHideOtherNetworkReading() {
        let inspection = HistoryInspection(time: 104, points: [points, []])
        XCTAssertEqual(inspection.samples, [points[1], nil])
    }
}
