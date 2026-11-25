import CoreLocation
import XCTest
@testable import GPXRouteVideo

final class GPXRouteVideoTests: XCTestCase {
    func testParsesTrackPointsAndAccumulatesDistance() throws {
        let xml = """
        <?xml version="1.0"?>
        <gpx version="1.1" creator="test">
          <trk><trkseg>
            <trkpt lat="47.0" lon="8.0"><ele>500</ele><time>2024-01-01T10:00:00.123Z</time></trkpt>
            <trkpt lat="47.001" lon="8.0"><ele>510</ele><time>2024-01-01T10:01:00Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gpx")
        try Data(xml.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let route = try GPXParser.parse(url: file)
        XCTAssertEqual(route.count, 2)
        XCTAssertEqual(route[0].elevation, 500)
        XCTAssertNotNil(route[0].timestamp)
        XCTAssertGreaterThan(route[1].distanceFromStart, 100)
        XCTAssertLessThan(route[1].distanceFromStart, 120)
    }

    func testRejectsGPXWithoutTrackPoints() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gpx")
        try Data("<gpx version=\"1.1\"></gpx>".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(try GPXParser.parse(url: file))
    }

    func testVideoDurationStaysWithinPreviewBounds() {
        let shortRoute = RouteActivity(
            name: "short",
            sport: .cycling,
            points: [RoutePoint(
                coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 8),
                elevation: nil,
                timestamp: nil
            )]
        )
        let longRoute = RouteActivity(
            name: "long",
            sport: .hiking,
            points: [RoutePoint(
                coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 8),
                elevation: nil,
                timestamp: nil,
                distanceFromStart: 100_000
            )]
        )

        XCTAssertEqual(shortRoute.videoDuration, 10)
        XCTAssertEqual(longRoute.videoDuration, 60)
    }
}
