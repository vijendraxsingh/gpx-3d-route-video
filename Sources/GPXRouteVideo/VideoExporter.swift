import AppKit
import AVFoundation
import CoreLocation
import CoreText
import MapKit

enum VideoExporter {
    static func export(
        activities: [RouteActivity],
        photos: [GeoPhoto],
        matchingRadius: CLLocationDistance,
        to outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let renderableActivities = activities.filter { $0.points.count > 1 }
        guard !renderableActivities.isEmpty else { throw ImportError.noRoutePoints }
        let width = 1280
        let height = 720
        let fps: Int32 = 30
        let duration = renderableActivities.reduce(0) { $0 + $1.estimatedDuration }
        let frameCount = max(1, Int(duration * Double(fps)))

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        guard writer.canAdd(input) else { throw ExportError.cannotAddVideoInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ExportError.cannotStartWriter
        }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }

            let elapsed = Double(frame) / Double(fps)
            var activityStart = 0.0
            var selected = renderableActivities[0]
            var localElapsed = 0.0
            for activity in renderableActivities {
                selected = activity
                localElapsed = elapsed - activityStart
                if localElapsed < activity.estimatedDuration { break }
                activityStart += activity.estimatedDuration
            }
            let segmentProgress = min(1, max(0, localElapsed / selected.estimatedDuration))
            let route = selected.points
            let totalDistance = max(selected.distance, 1)
            let targetDistance = totalDistance * segmentProgress
            let routeIndex = route.firstIndex { $0.distanceFromStart >= targetDistance } ?? route.count - 1
            let center = route[routeIndex].coordinate
            let heading = routeIndex + 1 < route.count ? bearing(from: center, to: route[routeIndex + 1].coordinate) : 0
            let cameraAltitude = max(2_000, min(80_000, totalDistance * 0.8))
            let camera = MKMapCamera(
                lookingAtCenter: center,
                fromDistance: cameraAltitude,
                pitch: 55,
                heading: heading
            )
            let mapSnapshot = try await snapshot(camera: camera, width: width, height: height)
            guard let buffer = makePixelBuffer(
                snapshot: mapSnapshot,
                route: route,
                visibleDistance: targetDistance,
                activityID: selected.id,
                routeColor: selected.sport.color.cgColor,
                photoOverlayDistance: selected.sport.estimatedSpeed * 8,
                activityTitle: "\(selected.sport.title) - \(selected.name)",
                photos: photos,
                matchingRadius: matchingRadius,
                width: width,
                height: height,
                adaptor: adaptor
            ) else {
                throw ExportError.cannotCreateFrame
            }

            let time = CMTime(value: Int64(frame), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? ExportError.cannotAppendFrame
            }
            progress(Double(frame + 1) / Double(frameCount))
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? ExportError.cannotFinish
        }
    }

    private static func snapshot(camera: MKMapCamera, width: Int, height: Int) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.camera = camera
        options.size = CGSize(width: width, height: height)
        options.mapType = .standard
        let snapshotter = MKMapSnapshotter(options: options)
        return try await withCheckedThrowingContinuation { continuation in
            snapshotter.start { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: ExportError.cannotCreateSnapshot)
                }
            }
        }
    }

    private static func makePixelBuffer(
        snapshot: MKMapSnapshotter.Snapshot,
        route: [RoutePoint],
        visibleDistance: CLLocationDistance,
        activityID: UUID,
        routeColor: CGColor,
        photoOverlayDistance: CLLocationDistance,
        activityTitle: String,
        photos: [GeoPhoto],
        matchingRadius: CLLocationDistance,
        width: Int,
        height: Int,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var optionalBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &optionalBuffer) == kCVReturnSuccess,
              let buffer = optionalBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        guard let mapImage = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        context.draw(mapImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let visiblePoints = route.prefix { $0.distanceFromStart <= visibleDistance }
        if visiblePoints.count > 1 {
            context.setStrokeColor(routeColor)
            context.setLineWidth(7)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            for (index, point) in visiblePoints.enumerated() {
                let mapPoint = snapshot.point(for: point.coordinate)
                let pointInMap = CGPoint(x: mapPoint.x, y: CGFloat(height) - mapPoint.y)
                if index == 0 { context.move(to: pointInMap) }
                else { context.addLine(to: pointInMap) }
            }
            context.strokePath()
        }

        if let photo = photos.first(where: { photo in
            guard photo.matchedActivityID == activityID,
                  let index = photo.matchedRouteIndex, let distance = photo.matchDistance,
                  distance <= matchingRadius else { return false }
            return route[index].distanceFromStart <= visibleDistance
                && visibleDistance - route[index].distanceFromStart < photoOverlayDistance
        }), let image = photo.image {
            let box = CGRect(x: width - 330, y: height - 240, width: 300, height: 210)
            context.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor)
            context.fill(box.insetBy(dx: -6, dy: -6))
            let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let destination = CGRect(
                x: box.midX - size.width / 2,
                y: box.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            context.draw(image, in: destination)
        }
        let title = NSAttributedString(
            string: activityTitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        let titleWidth = Int(min(680, title.size().width + 28))
        context.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        context.fill(CGRect(x: 24, y: height - 66, width: titleWidth, height: 42))
        context.textPosition = CGPoint(x: 38, y: height - 52)
        CTLineDraw(CTLineCreateWithAttributedString(title), context)
        return buffer
    }

    private static func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        return atan2(y, x) * 180 / .pi
    }
}

enum ExportError: LocalizedError {
    case cannotAddVideoInput
    case cannotStartWriter
    case cannotCreateFrame
    case cannotAppendFrame
    case cannotFinish
    case cannotCreateSnapshot

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput: "The video encoder rejected its input configuration."
        case .cannotStartWriter: "The MP4 export could not be started."
        case .cannotCreateFrame: "A video frame could not be created."
        case .cannotAppendFrame: "A video frame could not be encoded."
        case .cannotFinish: "The MP4 file could not be finalized."
        case .cannotCreateSnapshot: "The map renderer returned no image."
        }
    }
}
