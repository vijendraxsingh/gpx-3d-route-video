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

    func testSuggestedVideoDurationStaysWithinPreviewBounds() {
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

    func testVideoDurationCanBeCustomizedWithinSupportedBounds() {
        let route = RouteActivity(
            name: "custom",
            sport: .cycling,
            points: [RoutePoint(
                coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 8),
                elevation: nil,
                timestamp: nil
            )],
            videoDuration: 125
        )

        XCTAssertEqual(route.videoDuration, 125)
        XCTAssertEqual(RouteActivity.minimumVideoDuration, 10)
        XCTAssertEqual(RouteActivity.maximumVideoDuration, 600)
    }

    func testVideoDurationInputIsClampedToSupportedBounds() {
        let point = RoutePoint(
            coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 8),
            elevation: nil,
            timestamp: nil
        )
        let tooShort = RouteActivity(name: "short", sport: .running, points: [point], videoDuration: 1)
        let tooLong = RouteActivity(name: "long", sport: .running, points: [point], videoDuration: 900)

        XCTAssertEqual(tooShort.videoDuration, RouteActivity.minimumVideoDuration)
        XCTAssertEqual(tooLong.videoDuration, RouteActivity.maximumVideoDuration)
    }

    @MainActor
    func testDefaultExportFilenameUsesFirstRouteName() {
        let project = RouteProject()
        XCTAssertEqual(project.defaultExportFilename, "route-video")

        let point = RoutePoint(
            coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 8),
            elevation: nil,
            timestamp: nil
        )
        project.activities = [
            RouteActivity(name: "morning-ride", sport: .cycling, points: [point]),
            RouteActivity(name: "afternoon-hike", sport: .hiking, points: [point])
        ]

        XCTAssertEqual(project.defaultExportFilename, "morning-ride")
    }

    func testCameraStylesIncludeThreePerspectivesWithForwardFollowAsRecommended() {
        XCTAssertEqual(
            CameraStyle.allCases,
            [.forwardFollow, .firstPerson, .chase]
        )
        XCTAssertEqual(CameraStyle.forwardFollow.title, "Forward Follow (Recommended)")
        XCTAssertGreaterThan(CameraStyle.firstPerson.pitch, CameraStyle.chase.pitch)
        XCTAssertGreaterThan(CameraStyle.chase.distance, CameraStyle.firstPerson.distance)
    }
}
