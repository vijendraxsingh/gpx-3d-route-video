import AppKit
import CoreLocation
import Foundation
import ImageIO

struct RoutePoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let elevation: Double?
    let timestamp: Date?
    var distanceFromStart: CLLocationDistance = 0
}

enum Sport: String, CaseIterable, Identifiable {
    case cycling
    case hiking
    case running
    case trailRunning
    case swimming

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cycling: "Cycling"
        case .hiking: "Hiking"
        case .running: "Running"
        case .trailRunning: "Trail Running"
        case .swimming: "Swimming"
        }
    }

    var color: NSColor {
        switch self {
        case .cycling: .systemBlue
        case .hiking: .systemGreen
        case .running: .systemOrange
        case .trailRunning: .systemPurple
        case .swimming: .systemTeal
        }
    }
}

enum CameraStyle: String, CaseIterable, Identifiable, Equatable {
    case forwardFollow
    case firstPerson
    case chase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forwardFollow: "Forward Follow (Recommended)"
        case .firstPerson: "First Person"
        case .chase: "Chase Camera"
        }
    }

    var distance: CLLocationDistance {
        switch self {
        case .forwardFollow: 2_800
        case .firstPerson: 1_100
        case .chase: 5_000
        }
    }

    var pitch: CGFloat {
        switch self {
        case .forwardFollow: 65
        case .firstPerson: 76
        case .chase: 52
        }
    }

    var lookAhead: CLLocationDistance {
        switch self {
        case .forwardFollow: 450
        case .firstPerson: 180
        case .chase: 0
        }
    }
}

struct RouteActivity: Identifiable {
    let id = UUID()
    let name: String
    var sport: Sport
    let points: [RoutePoint]
    var videoDuration: Double

    var distance: CLLocationDistance { points.last?.distanceFromStart ?? 0 }

    static let minimumVideoDuration: Double = 10
    static let maximumVideoDuration: Double = 600

    init(name: String, sport: Sport, points: [RoutePoint], videoDuration: Double? = nil) {
        self.name = name
        self.sport = sport
        self.points = points
        let suggestedDuration = max(Self.minimumVideoDuration, min(60, 10 + (points.last?.distanceFromStart ?? 0) / 300))
        self.videoDuration = min(
            Self.maximumVideoDuration,
            max(Self.minimumVideoDuration, videoDuration ?? suggestedDuration)
        )
    }
}

struct GeoPhoto: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    let coordinate: CLLocationCoordinate2D?
    var matchedActivityID: UUID?
    var matchedRouteIndex: Int?
    var matchDistance: CLLocationDistance?

    var image: CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func load(from url: URL) throws -> GeoPhoto {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ImportError.invalidImage(url.lastPathComponent)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let gps = properties?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let latitude = gps?[kCGImagePropertyGPSLatitude] as? CLLocationDegrees
        let longitude = gps?[kCGImagePropertyGPSLongitude] as? CLLocationDegrees
        let latitudeRef = gps?[kCGImagePropertyGPSLatitudeRef] as? String
        let longitudeRef = gps?[kCGImagePropertyGPSLongitudeRef] as? String

        let coordinate: CLLocationCoordinate2D?
        if let latitude, let longitude {
            let signedLatitude = latitudeRef == "S" ? -latitude : latitude
            let signedLongitude = longitudeRef == "W" ? -longitude : longitude
            let candidate = CLLocationCoordinate2D(latitude: signedLatitude, longitude: signedLongitude)
            coordinate = CLLocationCoordinate2DIsValid(candidate) ? candidate : nil
        } else {
            coordinate = nil
        }

        return GeoPhoto(name: url.lastPathComponent, data: data, coordinate: coordinate)
    }
}

enum ImportError: LocalizedError {
    case noRoutePoints
    case invalidImage(String)

    var errorDescription: String? {
        switch self {
        case .noRoutePoints:
            return "The selected GPX file contains no usable track points."
        case .invalidImage(let name):
            return "\(name) could not be decoded as an image."
        }
    }
}

enum GPXParser {
    static func parse(url: URL) throws -> [RoutePoint] {
        let parser = XMLParser(contentsOf: url)
        let delegate = GPXDelegate()
        parser?.delegate = delegate
        guard let parser, parser.parse() else {
            throw parser?.parserError ?? ImportError.noRoutePoints
        }
        guard !delegate.points.isEmpty else { throw ImportError.noRoutePoints }

        var points = delegate.points
        if points.count > 1 {
            for index in 1..<points.count {
                let previous = CLLocation(
                    latitude: points[index - 1].coordinate.latitude,
                    longitude: points[index - 1].coordinate.longitude
                )
                let current = CLLocation(
                    latitude: points[index].coordinate.latitude,
                    longitude: points[index].coordinate.longitude
                )
                points[index].distanceFromStart = points[index - 1].distanceFromStart
                    + current.distance(from: previous)
            }
        }
        return points
    }
}

private final class GPXDelegate: NSObject, XMLParserDelegate {
    private(set) var points: [RoutePoint] = []
    private var currentPoint: (coordinate: CLLocationCoordinate2D, elevation: Double?, timestamp: Date?)?
    private var currentElement = ""
    private var text = ""
    private let dateFormatter = ISO8601DateFormatter()
    private let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        text = ""
        if elementName == "trkpt" || elementName == "rtept",
           let lat = Double(attributeDict["lat"] ?? ""),
           let lon = Double(attributeDict["lon"] ?? "") {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if CLLocationCoordinate2DIsValid(coordinate) {
                currentPoint = (coordinate, nil, nil)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "ele", let elevation = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let point = currentPoint {
            currentPoint = (point.coordinate, elevation, point.timestamp)
        } else if elementName == "time", let point = currentPoint {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let timestamp = dateFormatter.date(from: value) ?? fractionalDateFormatter.date(from: value)
            currentPoint = (point.coordinate, point.elevation, timestamp)
        } else if elementName == "trkpt" || elementName == "rtept" {
            if let point = currentPoint {
                points.append(RoutePoint(
                    coordinate: point.coordinate,
                    elevation: point.elevation,
                    timestamp: point.timestamp
                ))
            }
            currentPoint = nil
        }
        currentElement = ""
        text = ""
    }
}
