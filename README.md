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

```sh
swift build
swift run
```

Open the folder in Xcode to run it as a regular macOS app. Map rendering and
video export require network access to MapKit map data. Map attribution remains
visible in exported frames.

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

This source is available under the custom RouteStudio Community and Revenue
Share License in [`LICENSE`](./LICENSE). Non-commercial use is permitted under
its terms. Commercial use requires reporting and payment of 10% of gross
revenue quarterly; see the license for definitions, conditions, and reporting
requirements. This is not an OSI-approved open-source license, and the license
text should receive legal review before commercial release.
