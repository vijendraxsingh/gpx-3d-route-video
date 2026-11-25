# RouteStudio

RouteStudio is a native macOS app prototype for turning a GPX track into an
animated route video, with geotagged photos shown as upper-right overlays.

## Features

- Import multiple GPX tracks from the toolbar or by dropping them into the app.
- Choose Cycling, Hiking, Running, Trail Running, or Swimming for each track.
- Preview routes over realistic 3D MapKit terrain and scrub through the
  combined route sequence.
- Drop or import JPEG, HEIC, PNG, and TIFF photos as a batch.
- Match photos with embedded GPS coordinates to the nearest GPX point.
- Adjust the matching radius and review matched/unmatched photos.
- Export one H.264 MP4 with each route in sequence and photo picture-in-picture.

## Build and run

Requires macOS 14 or newer and Xcode command line tools.

### Run in Xcode

Open `RouteStudio.xcodeproj`, choose the **RouteStudio** scheme and **My Mac**
as the run destination, then click **Run**.

### Run with Swift Package Manager

```sh
swift build
swift run
```

Map rendering and video export require network access to MapKit map data. Map
attribution remains visible in exported frames.

## Current MVP limitations

- GPX tracks are rendered in import order; multiple segment boundaries are not
  yet exposed for selection.
- Photo matching is nearest-point based, and the 3D camera preview/export use
  MapKit's available map snapshots.
- Video duration is estimated from route distance; there are no output quality
  controls yet.
- Projects are not persisted between launches.

See the [product and engineering plan](./docs/PLAN.md) for the broader roadmap.

## License

The RouteStudio software is distributed under the
[RouteStudio Non-Commercial License 1.0](./LICENSE). Commercial use of the
software requires a separate written agreement signed by the Licensor that
authorizes the use and establishes revenue-sharing terms. This is a custom,
source-available license, not an OSI-approved open-source license.

The license applies to the software, its source code, and its documentation.
It does not claim rights over GPX files, photographs, or videos created using
the app, or over third-party components and map data, which remain subject to
their own terms.
