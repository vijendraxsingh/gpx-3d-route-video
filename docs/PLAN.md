# RouteStudio Product and Engineering Plan

## Goal

Create a native macOS app that imports multiple GPX routes, assigns a sport to
each route, and exports one immersive video that follows each activity through
3D terrain. Let users choose forward-follow, first-person, and chase cameras.
Geotagged photos appear in a picture-in-picture overlay at the upper-right as
the camera reaches their matched route location.

## Main workflow

1. Import one or more GPX files by picker or drag and drop.
2. Select a sport for each route: Cycling, Hiking, Running, Trail Running, or
   Swimming.
3. Choose a camera perspective, then inspect and scrub through the ordered
   route sequence on a 3D terrain map.
4. Drop a batch of geotagged photos and review nearest-route matches.
5. Adjust the matching radius, then export one MP4 containing all routes and
   matched photo overlays.

## MVP scope

- Parse GPX route and track points, timestamps, and elevations.
- Import multiple GPX files and retain an independent sport choice for each.
- Display each route in its sport color; show the route name and sport in the
  exported video.
- Extract GPS coordinates from JPEG, HEIC, PNG, and TIFF image metadata.
- Match photos to the nearest point across all imported routes, with a
  configurable distance threshold.
- Display matched images in a top-right overlay during the relevant route
  segment.
- Export a 1280x720 H.264 MP4 with a route-following pitched flyover camera
  and activities sequenced in import order.

## Implementation outline

- **Interface:** SwiftUI, with MapKit realistic elevation for the interactive
  preview and per-frame export snapshots.
- **GPX:** Foundation XML parsing with Core Location distance calculations.
- **Photo metadata:** ImageIO GPS metadata extraction and image decoding.
- **Preview:** MapKit realistic elevation, route polylines, photo markers,
  camera selection, and a route progress slider.
- **Export:** Repeated MapKit satellite-flyover snapshots with a sport-aware
  moving camera, route and photo overlays, and AVFoundation encoding.

## Known limitations and follow-up

- The current matcher chooses the nearest sampled GPX point rather than the
  closest point on a route segment.
- Routes from one GPX file are treated as one continuous sequence; separate
  track/segment selection is not exposed yet.
- Export duration is initially estimated from route distance, then adjustable
  per route from 10 seconds to 10 minutes. Total export length is the sum of
  route durations; longer videos take longer to render.
- Export now captures pitched terrain/flyover views several times per second
  and composes video at 12 fps. Capture speed and 3D imagery coverage depend on
  MapKit, network access, and location; validate quality, attribution, and
  provider usage terms before public release.
- Export retries an unavailable flyover capture with satellite imagery, and
  reports a visible failure status if MapKit cannot provide either map view.
- The camera simulates an athlete's route perspective, but does not render a
  person, bicycle, or other sports equipment.
- Project persistence, offline map handling, photo repositioning, export
  cancellation, and comprehensive handling of missing media are future work.

## Milestones

1. Validate all three camera perspectives across terrain and urban routes.
2. Improve GPX parsing and route-segment distance matching.
3. Add manual photo match adjustment, timeline controls, and overlay timing.
4. Add project persistence, export cancellation, and quality settings.
5. Test long routes, multiple activities, photo batches, and missing inputs.

## MVP acceptance criteria

- Users can import multiple GPX files and set each to Cycling, Hiking,
  Running, Trail Running, or Swimming.
- The preview displays all routes, and the scrubber follows the routes in
  order.
- Users can select forward-follow, first-person, or chase camera perspectives;
  forward-follow is the default.
- One MP4 export includes every imported route in order and identifies each
  activity by its chosen sport.
- Geotagged photos within the match radius appear in the video's upper-right
  overlay near their matched point; unmatched photos are clearly identified.
- Invalid GPX, unsupported images, and export failures surface a useful error.
