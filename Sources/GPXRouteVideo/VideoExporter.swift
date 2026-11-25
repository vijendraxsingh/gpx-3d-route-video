import AppKit
import AVFoundation
import CoreLocation
import CoreText
import MapKit

enum VideoExporter {
    private struct PreparedActivity {
        let activity: RouteActivity
        let mapImage: CGImage
        let routePoints: [CGPoint]
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
        to outputURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        let renderableActivities = activities.filter { $0.points.count > 1 }
        guard !renderableActivities.isEmpty else { throw ImportError.noRoutePoints }
        let width = 1280
        let height = 720
        let fps: Int32 = 24
        let duration = renderableActivities.reduce(0) { $0 + $1.videoDuration }
        let frameCount = max(1, Int(duration * Double(fps)))

        var preparedActivities: [PreparedActivity] = []
        for (index, activity) in renderableActivities.enumerated() {
            try Task.checkCancellation()
            progress(0, "Loading map \(index + 1) of \(renderableActivities.count)…")
            let mapSnapshot = try await snapshot(for: activity, width: width, height: height)
            guard let image = mapSnapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ExportError.cannotCreateSnapshot
            }
            let routePoints = activity.points.map { point -> CGPoint in
                let mapPoint = mapSnapshot.point(for: point.coordinate)
                return CGPoint(x: mapPoint.x, y: CGFloat(height) - mapPoint.y)
            }
            preparedActivities.append(PreparedActivity(
                activity: activity,
                mapImage: image,
                routePoints: routePoints
            ))
        }
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
            var selected = preparedActivities[0]
            var localElapsed = 0.0
            for prepared in preparedActivities {
                selected = prepared
                localElapsed = elapsed - activityStart
                if localElapsed < prepared.activity.videoDuration { break }
                activityStart += prepared.activity.videoDuration
            }
            let activity = selected.activity
            let segmentProgress = min(1, max(0, localElapsed / activity.videoDuration))
            let route = activity.points
            let totalDistance = max(activity.distance, 1)
            let targetDistance = totalDistance * segmentProgress
            let routeIndex = upperBound(in: route, distance: targetDistance)
            guard let buffer = makePixelBuffer(
                prepared: selected,
                visiblePointCount: routeIndex,
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
        for activity: RouteActivity,
        width: Int,
        height: Int
    ) async throws -> MKMapSnapshotter.Snapshot {
        let coordinates = activity.points.map(\.coordinate)
        let routeRect = coordinates.reduce(MKMapRect.null) { rect, coordinate in
            let point = MKMapPoint(coordinate)
            return rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        let aspectRatio = Double(width) / Double(height)
        let mapWidth = max(max(routeRect.width, routeRect.height * aspectRatio), 1_000)
        let mapHeight = max(max(routeRect.height, routeRect.width / aspectRatio), 1_000)
        let paddedRect = MKMapRect(
            x: routeRect.midX - mapWidth * 2.5,
            y: routeRect.midY - mapHeight * 2.5,
            width: mapWidth * 5,
            height: mapHeight * 5
        )
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(paddedRect)
        options.size = CGSize(width: width, height: height)
        options.mapType = .standard
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
        prepared: PreparedActivity,
        visiblePointCount: Int,
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
        let cameraIndex = min(max(visiblePointCount - 1, 0), prepared.routePoints.count - 1)
        let cameraPoint = prepared.routePoints[cameraIndex]
        let zoom: CGFloat = 2.2
        context.saveGState()
        context.translateBy(
            x: CGFloat(width) / 2 - cameraPoint.x * zoom,
            y: CGFloat(height) / 2 - cameraPoint.y * zoom
        )
        context.scaleBy(x: zoom, y: zoom)
        context.draw(prepared.mapImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        if visiblePointCount > 1 {
            context.setStrokeColor(prepared.activity.sport.color.cgColor)
            context.setLineWidth(7)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            let pointStride = max(1, prepared.routePoints.count / 1_500)
            for index in stride(from: 0, to: visiblePointCount, by: pointStride) {
                let point = prepared.routePoints[index]
                if index == 0 { context.move(to: point) }
                else { context.addLine(to: point) }
            }
            if (visiblePointCount - 1) % pointStride != 0 {
                context.addLine(to: prepared.routePoints[visiblePointCount - 1])
            }
            context.strokePath()
        }
        context.restoreGState()

        if let photo = photos.first(where: { photo in
            guard photo.activityID == prepared.activity.id else { return false }
            let photoDistance = prepared.activity.points[photo.routeIndex].distanceFromStart
            let overlayDistance = prepared.activity.distance / prepared.activity.videoDuration * 3
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
            string: "\(prepared.activity.sport.title) - \(prepared.activity.name)",
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

    private static func upperBound(in route: [RoutePoint], distance: CLLocationDistance) -> Int {
        var lower = 0
        var upper = route.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if route[middle].distanceFromStart <= distance {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(1, lower)
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
