import AppKit
import AVFoundation
import CoreLocation
import CoreText
import MapKit

enum VideoExporter {
    private struct CapturedMap {
        let activity: RouteActivity
        let mapImage: CGImage
        let routePoints: [ProjectedRoutePoint]
    }

    private struct ProjectedRoutePoint {
        let routeIndex: Int
        let point: CGPoint
    }

    private struct RoutePosition {
        let coordinate: CLLocationCoordinate2D
        let index: Int
        let fraction: Double
    }

    private struct PreparedPhoto {
        let activityID: UUID
        let routeIndex: Int
        let image: CGImage
    }

    static func export(
        activities: [RouteActivity],
        photos: [GeoPhoto],
        matchingRadius: CLLocationDistance,
        cameraStyle: CameraStyle,
        to outputURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        let renderableActivities = activities.filter { $0.points.count > 1 }
        guard !renderableActivities.isEmpty else { throw ImportError.noRoutePoints }
        let width = 1280
        let height = 720
        let fps: Int32 = 12
        let duration = renderableActivities.reduce(0) { $0 + $1.videoDuration }
        let frameCount = max(1, Int(duration * Double(fps)))
        let preparedPhotos = photos.compactMap { photo -> PreparedPhoto? in
            guard let activityID = photo.matchedActivityID,
                  let routeIndex = photo.matchedRouteIndex,
                  let activity = renderableActivities.first(where: { $0.id == activityID }),
                  activity.points.indices.contains(routeIndex),
                  (photo.matchDistance ?? .infinity) <= matchingRadius,
                  let image = photo.image else { return nil }
            return PreparedPhoto(activityID: activityID, routeIndex: routeIndex, image: image)
        }

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
                guard writer.status == .writing else {
                    throw writer.error ?? ExportError.cannotAppendFrame
                }
                try await Task.sleep(for: .milliseconds(5))
            }

            let elapsed = Double(frame) / Double(fps)
            var activityStart = 0.0
            var selected = renderableActivities[0]
            var localElapsed = 0.0
            for activity in renderableActivities {
                selected = activity
                localElapsed = elapsed - activityStart
                if localElapsed < activity.videoDuration { break }
                activityStart += activity.videoDuration
            }
            let activity = selected
            let segmentProgress = min(1, max(0, localElapsed / activity.videoDuration))
            let targetDistance = activity.distance * segmentProgress
            let cameraDistance = min(activity.distance, targetDistance + cameraStyle.lookAhead)
            let routePosition = position(on: activity.points, at: targetDistance)
            let cameraPosition = position(on: activity.points, at: cameraDistance)
            let visibleRouteIndex = min(
                activity.points.count,
                routePosition.index + (routePosition.fraction > 0 ? 2 : 1)
            )
            progress(
                0.05 + 0.94 * Double(frame) / Double(frameCount),
                "Capturing moving terrain view \(frame + 1) of \(frameCount)…"
            )
            let bearingStart = position(
                on: activity.points,
                at: max(0, cameraDistance - 1_500)
            )
            let bearingEnd = position(
                on: activity.points,
                at: min(activity.distance, cameraDistance + 1_500)
            )
            let bearing = heading(from: bearingStart.coordinate, to: bearingEnd.coordinate)
            let mapSnapshot = try await snapshot(
                center: cameraPosition.coordinate,
                heading: bearing,
                cameraStyle: cameraStyle,
                width: width,
                height: height
            )
            guard let image = mapSnapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ExportError.cannotCreateSnapshot
            }
            let routeStride = max(1, activity.points.count / 2_000)
            var routePoints = stride(from: 0, to: activity.points.count, by: routeStride).map { index in
                let mapPoint = mapSnapshot.point(for: activity.points[index].coordinate)
                return ProjectedRoutePoint(
                    routeIndex: index,
                    point: mapPoint
                )
            }
            let lastIndex = activity.points.count - 1
            if lastIndex >= 0, lastIndex % routeStride != 0 {
                let mapPoint = mapSnapshot.point(for: activity.points[lastIndex].coordinate)
                routePoints.append(ProjectedRoutePoint(
                    routeIndex: lastIndex,
                    point: mapPoint
                ))
            }
            let capturedMap = CapturedMap(
                activity: activity,
                mapImage: image,
                routePoints: routePoints
            )
            guard let buffer = makePixelBuffer(
                capturedMap: capturedMap,
                visibleRouteIndex: visibleRouteIndex,
                visibleDistance: targetDistance,
                photos: preparedPhotos,
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
            let fraction = Double(frame + 1) / Double(frameCount)
            progress(0.05 + fraction * 0.94, "Rendering video… \(Int(fraction * 100))%")
        }

        progress(0.99, "Finalizing MP4…")
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? ExportError.cannotFinish
        }
    }

    private static func snapshot(
        center: CLLocationCoordinate2D,
        heading: CLLocationDirection,
        cameraStyle: CameraStyle,
        width: Int,
        height: Int
    ) async throws -> MKMapSnapshotter.Snapshot {
        do {
            return try await snapshot(
                center: center,
                heading: heading,
                cameraStyle: cameraStyle,
                width: width,
                height: height,
                mapType: .satelliteFlyover
            )
        } catch let flyoverError {
            try Task.checkCancellation()
            do {
                return try await snapshot(
                    center: center,
                    heading: heading,
                    cameraStyle: cameraStyle,
                    width: width,
                    height: height,
                    mapType: .satellite
                )
            } catch let satelliteError {
                try Task.checkCancellation()
                throw ExportError.mapSnapshotFailed(
                    "Flyover: \(flyoverError.localizedDescription) Satellite: \(satelliteError.localizedDescription)"
                )
            }
        }
    }

    private static func snapshot(
        center: CLLocationCoordinate2D,
        heading: CLLocationDirection,
        cameraStyle: CameraStyle,
        width: Int,
        height: Int,
        mapType: MKMapType
    ) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.camera = MKMapCamera(
            lookingAtCenter: center,
            fromDistance: cameraStyle.distance,
            pitch: cameraStyle.pitch,
            heading: heading
        )
        options.size = CGSize(width: width, height: height)
        options.mapType = mapType
        options.showsBuildings = true
        let snapshotter = MKMapSnapshotter(options: options)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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
        } onCancel: {
            snapshotter.cancel()
        }
    }

    private static func makePixelBuffer(
        capturedMap: CapturedMap,
        visibleRouteIndex: Int,
        visibleDistance: CLLocationDistance,
        photos: [PreparedPhoto],
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
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(capturedMap.mapImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        if capturedMap.routePoints.count > 1 {
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            for (index, routePoint) in capturedMap.routePoints.enumerated() {
                if index == 0 { context.move(to: routePoint.point) }
                else { context.addLine(to: routePoint.point) }
            }
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(12)
            context.strokePath()

            context.beginPath()
            for (index, routePoint) in capturedMap.routePoints.enumerated() {
                if index == 0 { context.move(to: routePoint.point) }
                else { context.addLine(to: routePoint.point) }
            }
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(8)
            context.strokePath()

            let traversedPoints = capturedMap.routePoints.filter { $0.routeIndex <= visibleRouteIndex }
            if traversedPoints.count > 1 {
                context.beginPath()
                for (index, routePoint) in traversedPoints.enumerated() {
                    if index == 0 { context.move(to: routePoint.point) }
                    else { context.addLine(to: routePoint.point) }
                }
                context.setStrokeColor(capturedMap.activity.sport.color.cgColor)
                context.setLineWidth(5)
                context.strokePath()
            }
        }
        context.restoreGState()

        if let photo = photos.first(where: { photo in
            guard photo.activityID == capturedMap.activity.id else { return false }
            let photoDistance = capturedMap.activity.points[photo.routeIndex].distanceFromStart
            let overlayDistance = capturedMap.activity.distance / capturedMap.activity.videoDuration * 3
            return photoDistance <= visibleDistance
                && visibleDistance - photoDistance < overlayDistance
        }) {
            let image = photo.image
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
            string: "\(capturedMap.activity.sport.title) - \(capturedMap.activity.name)",
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

    private static func position(on route: [RoutePoint], at distance: CLLocationDistance) -> RoutePosition {
        guard route.count > 1 else {
            return RoutePosition(coordinate: route[0].coordinate, index: 0, fraction: 0)
        }
        if distance <= route[0].distanceFromStart {
            return RoutePosition(coordinate: route[0].coordinate, index: 0, fraction: 0)
        }
        if distance >= route[route.count - 1].distanceFromStart {
            return RoutePosition(coordinate: route[route.count - 1].coordinate, index: route.count - 1, fraction: 0)
        }

        var lower = 0
        var upper = route.count - 1
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if route[middle].distanceFromStart <= distance {
                lower = middle
            } else {
                upper = middle
            }
        }
        let start = route[lower]
        let end = route[upper]
        let segmentDistance = end.distanceFromStart - start.distanceFromStart
        let fraction = segmentDistance > 0 ? (distance - start.distanceFromStart) / segmentDistance : 0
        let longitudeDelta = ((end.coordinate.longitude - start.coordinate.longitude + 540)
            .truncatingRemainder(dividingBy: 360)) - 180
        let coordinate = CLLocationCoordinate2D(
            latitude: start.coordinate.latitude + (end.coordinate.latitude - start.coordinate.latitude) * fraction,
            longitude: start.coordinate.longitude + longitudeDelta * fraction
        )
        return RoutePosition(coordinate: coordinate, index: lower, fraction: fraction)
    }

    private static func heading(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDirection {
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2) - sin(latitude1) * cos(latitude2) * cos(longitudeDelta)
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
    case mapSnapshotFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput: "The video encoder rejected its input configuration."
        case .cannotStartWriter: "The MP4 export could not be started."
        case .cannotCreateFrame: "A video frame could not be created."
        case .cannotAppendFrame: "A video frame could not be encoded."
        case .cannotFinish: "The MP4 file could not be finalized."
        case .cannotCreateSnapshot: "The map renderer returned no image."
        case .mapSnapshotFailed(let reason):
            "Map imagery could not be loaded for this route. Check your internet connection and try again. MapKit error: \(reason)"
        }
    }
}
