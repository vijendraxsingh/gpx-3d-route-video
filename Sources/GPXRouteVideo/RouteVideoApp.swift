import AppKit
import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct RouteVideoApp: App {
    @NSApplicationDelegateAdaptor(RouteStudioAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 680)
        }
    }
}

final class RouteStudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

@MainActor
final class RouteProject: ObservableObject {
    @Published var activities: [RouteActivity] = []
    @Published var photos: [GeoPhoto] = []
    @Published var matchingRadius: Double = 100
    @Published var status = "Import a GPX track to get started."
    @Published var errorMessage: String?
    @Published var isExporting = false
    @Published var exportProgress = 0.0
    @Published var previewProgress = 0.0

    var routeDistance: CLLocationDistance { activities.reduce(0) { $0 + $1.distance } }

    func importGPX(_ urls: [URL]) {
        var added = 0
        var failures: [String] = []
        for url in urls {
            do {
                let points = try GPXParser.parse(url: url)
                activities.append(RouteActivity(name: url.deletingPathExtension().lastPathComponent, sport: .cycling, points: points))
                added += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        updatePhotoMatches()
        status = "Imported \(added) route\(added == 1 ? "" : "s"). Choose a sport for each route."
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func importPhotos(_ urls: [URL]) {
        var added = 0
        var failures: [String] = []
        for url in urls where ["jpg", "jpeg", "heic", "png", "tif", "tiff"].contains(url.pathExtension.lowercased()) {
            do {
                photos.append(try GeoPhoto.load(from: url))
                added += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        updatePhotoMatches()
        status = "Added \(added) photo\(added == 1 ? "" : "s"). \(unmatchedCount) have no route match."
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    var unmatchedCount: Int {
        photos.filter {
            $0.coordinate == nil || $0.matchedActivityID == nil
                || $0.matchedRouteIndex == nil || ($0.matchDistance ?? .infinity) > matchingRadius
        }.count
    }

    func updatePhotoMatches() {
        for photoIndex in photos.indices {
            guard let coordinate = photos[photoIndex].coordinate else {
                photos[photoIndex].matchedActivityID = nil
                photos[photoIndex].matchedRouteIndex = nil
                photos[photoIndex].matchDistance = nil
                continue
            }
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let nearest = activities.flatMap { activity in
                activity.points.enumerated().map { index, point in
                    (activity.id, index, location.distance(from: CLLocation(
                        latitude: point.coordinate.latitude,
                        longitude: point.coordinate.longitude
                    )))
                }
            }.min { $0.2 < $1.2 }
            if let nearest {
                photos[photoIndex].matchedActivityID = nearest.0
                photos[photoIndex].matchedRouteIndex = nearest.1
                photos[photoIndex].matchDistance = nearest.2
            } else {
                photos[photoIndex].matchedActivityID = nil
                photos[photoIndex].matchedRouteIndex = nil
                photos[photoIndex].matchDistance = nil
            }
        }
    }

    func export(to url: URL) {
        guard !isExporting else { return }
        isExporting = true
        exportProgress = 0
        status = "Preparing video export…"
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                try await VideoExporter.export(
                    activities: activities,
                    photos: photos,
                    matchingRadius: matchingRadius,
                    to: url
                ) { value, message in
                    Task { @MainActor in
                        self.exportProgress = value
                        self.status = message
                    }
                }
                status = "Exported video to \(url.path)."
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}

struct ContentView: View {
    @StateObject private var project = RouteProject()
    @State private var showGPXPicker = false
    @State private var showPhotoPicker = false
    @State private var showExportPicker = false
    @State private var isDropTargeted = false
    @State private var cameraPosition: MapCameraPosition = .automatic

    private var matchedPhotos: [GeoPhoto] {
        project.photos.filter {
            $0.matchedActivityID != nil && $0.matchedRouteIndex != nil
                && ($0.matchDistance ?? .infinity) <= project.matchingRadius
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                mapPanel
                Divider()
                photoPanel
                    .frame(width: 310)
            }
            Divider()
            footer
        }
        .fileImporter(
            isPresented: $showGPXPicker,
            allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result) { project.importGPX($0) }
        }
        .fileImporter(
            isPresented: $showPhotoPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in handleImport(result) { project.importPhotos($0) } }
        .fileExporter(
            isPresented: $showExportPicker,
            document: EmptyVideoDocument(),
            contentType: UTType(filenameExtension: "mp4") ?? .mpeg4Movie,
            defaultFilename: "route-video"
        ) { result in
            switch result {
            case .success(let url): project.export(to: url)
            case .failure(let error): project.errorMessage = error.localizedDescription
            }
        }
        .alert("Notice", isPresented: Binding(
            get: { project.errorMessage != nil },
            set: { if !$0 { project.errorMessage = nil } }
        )) {
            Button("OK") { project.errorMessage = nil }
        } message: {
            Text(project.errorMessage ?? "")
        }
        .onChange(of: project.activities.count) { _, _ in updateCamera() }
        .onChange(of: project.previewProgress) { _, progress in
            cameraPosition = .camera(cameraForProgress(progress))
        }
        .onChange(of: project.matchingRadius) { _, _ in project.updatePhotoMatches() }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "map.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            Text("RouteStudio")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("Import GPX", systemImage: "point.topleft.down.to.point.bottomrightcurve") {
                showGPXPicker = true
            }
            Button("Add Photos", systemImage: "photo.badge.plus") {
                showPhotoPicker = true
            }
            .disabled(project.activities.isEmpty)
            Button("Export MP4", systemImage: "film") {
                showExportPicker = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!project.activities.contains(where: { $0.points.count > 1 }) || project.isExporting)
        }
        .padding(16)
    }

    private var mapPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("3D Route Preview").font(.headline)
                Spacer()
                if project.routeDistance > 0 {
                    Text(String(format: "%.1f km", project.routeDistance / 1_000))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            Map(position: $cameraPosition) {
                ForEach(project.activities) { activity in
                    MapPolyline(coordinates: activity.points.map(\.coordinate))
                        .stroke(Color(nsColor: activity.sport.color), lineWidth: 5)
                }
                ForEach(matchedPhotos) { photo in
                    if let activity = project.activities.first(where: { $0.id == photo.matchedActivityID }),
                       let index = photo.matchedRouteIndex,
                       activity.points.indices.contains(index) {
                        Marker(photo.name, coordinate: activity.points[index].coordinate)
                            .tint(.orange)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .overlay {
                if project.activities.isEmpty {
                    ContentUnavailableView(
                        "No GPX Track",
                        systemImage: "map",
                        description: Text("Import a GPX file to preview the route.")
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if !project.activities.isEmpty {
                HStack {
                    Image(systemName: "play.fill")
                    Slider(value: $project.previewProgress, in: 0...1)
                    Text("\(Int(project.previewProgress * 100))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var photoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("GPX Routes").font(.headline)
                    Spacer()
                    Text("\(project.activities.count)").font(.caption).foregroundStyle(.secondary)
                }
                if project.activities.isEmpty {
                    Text("Import or drop multiple GPX files here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($project.activities) { $activity in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(activity.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        HStack {
                            Picker("Sport", selection: $activity.sport) {
                                ForEach(Sport.allCases) { sport in
                                    Text(sport.title).tag(sport)
                                }
                            }
                            .labelsHidden()
                            Text(String(format: "%.1f km", activity.distance / 1_000))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }

                Divider()
                HStack {
                    Text("Photos").font(.headline)
                    Spacer()
                    Text("\(matchedPhotos.count) matched").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Match radius")
                    Spacer()
                    Text("\(Int(project.matchingRadius)) m").monospacedDigit()
                }
                Slider(value: $project.matchingRadius, in: 10...1_000, step: 10)

                if project.photos.isEmpty {
                    ContentUnavailableView(
                        "Drop photos here",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Photos with GPS location are matched to the route.")
                    )
                    .frame(minHeight: 160)
                } else {
                    ForEach(project.photos) { photo in
                        HStack(spacing: 10) {
                            if let image = photo.image {
                                Image(nsImage: NSImage(cgImage: image, size: .zero))
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(photo.name).lineLimit(1)
                                if let distance = photo.matchDistance,
                                   photo.matchedActivityID != nil,
                                   distance <= project.matchingRadius {
                                    Text(String(format: "Matched · %.0f m away", distance))
                                        .font(.caption).foregroundStyle(.green)
                                } else if photo.coordinate == nil {
                                    Text("No GPS metadata").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Outside match radius").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                Text("Matched photos appear in the upper-right of the exported video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .padding(14)
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(alignment: .leading) {
            if isDropTargeted {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if project.isExporting {
                if project.exportProgress == 0 {
                    ProgressView().controlSize(.small)
                } else {
                    ProgressView(value: project.exportProgress).frame(width: 140)
                }
                Text(project.status).lineLimit(1)
            } else {
                Text(project.status).lineLimit(1)
            }
            Spacer()
            if !project.photos.isEmpty {
                Text("\(project.unmatchedCount) unmatched")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func cameraForProgress(_ progress: Double) -> MapCamera {
        guard !project.activities.isEmpty else {
            return MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), distance: 50_000, heading: 0, pitch: 55)
        }
        let totalDuration = project.activities.reduce(into: 0.0) { $0 += $1.videoDuration }
        var elapsedBeforeActivity = 0.0
        var selected = project.activities[0]
        var localProgress = 0.0
        for activity in project.activities {
            selected = activity
            let localElapsed = totalDuration * progress - elapsedBeforeActivity
            localProgress = min(1, max(0, localElapsed / activity.videoDuration))
            if localElapsed <= activity.videoDuration { break }
            elapsedBeforeActivity += activity.videoDuration
        }
        let localDistance = selected.distance * localProgress
        let index = selected.points.firstIndex { $0.distanceFromStart >= localDistance } ?? selected.points.count - 1
        return MapCamera(
            centerCoordinate: selected.points[index].coordinate,
            distance: max(2_000, min(80_000, project.routeDistance * 0.8)),
            heading: 0,
            pitch: 55
        )
    }

    private func updateCamera() {
        let coordinates = project.activities.flatMap { $0.points.map(\.coordinate) }
        guard !coordinates.isEmpty else { return }
        let rect = coordinates.reduce(MKMapRect.null) { partial, coordinate in
            let point = MKMapPoint(coordinate)
            return partial.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        cameraPosition = .region(MKCoordinateRegion(rect))
    }

    private func handleImport(_ result: Result<[URL], Error>, action: ([URL]) -> Void) {
        switch result {
        case .success(let urls):
            let accessStates = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer {
                for (url, accessed) in accessStates where accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            action(urls)
        case .failure(let error):
            project.errorMessage = error.localizedDescription
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    Task { @MainActor in project.errorMessage = error.localizedDescription }
                    return
                }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let fileURL = item as? URL {
                    url = fileURL
                } else {
                    url = nil
                }
                guard let url else { return }
                Task { @MainActor in
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if url.pathExtension.lowercased() == "gpx" {
                        project.importGPX([url])
                    } else {
                        project.importPhotos([url])
                    }
                }
            }
        }
        return true
    }
}

struct EmptyVideoDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mpeg4Movie] }
    init() {}
    init(configuration: ReadConfiguration) throws {}
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}
