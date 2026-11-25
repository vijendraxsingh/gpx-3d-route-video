# RouteStudio Product and Engineering Plan

## Goal

Create a native macOS app that imports multiple GPX routes, assigns a sport to
each route, and exports one video that follows each route in sequence over a
3D map. Geotagged photos appear in a picture-in-picture overlay at the
upper-right as the camera reaches their matched route location.

## Main workflow

1. Import one or more GPX files by picker or drag and drop.
2. Select a sport for each route: Cycling, Hiking, Running, Trail Running, or
   Swimming.
3. Inspect and scrub through the ordered route sequence on a 3D map.
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
- Export a 1280x720 H.264 MP4 with activities sequenced in import order.

## Implementation outline

- **Interface:** SwiftUI, with MapKit realistic elevation for the interactive
  preview and per-frame export snapshots.
- **GPX:** Foundation XML parsing with Core Location distance calculations.
- **Photo metadata:** ImageIO GPS metadata extraction and image decoding.
- **Preview:** MapKit route polylines, photo markers, and a route progress
  slider.
- **Export:** MapKit snapshots composed with route paths and photo overlays,
  then encoded through AVFoundation.

## Known limitations and follow-up

- The current matcher chooses the nearest sampled GPX point rather than the
  closest point on a route segment.
- Routes from one GPX file are treated as one continuous sequence; separate
  track/segment selection is not exposed yet.
- Export duration uses a sport-based estimated speed and an activity minimum;
  users cannot adjust duration or codec settings yet.
- Map snapshots require access to MapKit map data. Verify provider
  attribution and usage terms for redistribution before a public release.
- Project persistence, offline map handling, photo repositioning, export
  cancellation, and comprehensive handling of missing media are future work.

## Milestones

1. Validate MapKit 3D snapshot quality and attribution for exported video.
2. Improve GPX parsing and route-segment distance matching.
3. Add manual photo match adjustment, timeline controls, and overlay timing.
4. Add project persistence, export cancellation, and quality settings.
5. Test long routes, multiple activities, photo batches, and missing inputs.

## MVP acceptance criteria

- Users can import multiple GPX files and set each to Cycling, Hiking,
  Running, Trail Running, or Swimming.
- The preview displays all routes, and the scrubber follows the routes in
  order.
- One MP4 export includes every imported route in order and identifies each
  activity by its chosen sport.
- Geotagged photos within the match radius appear in the video's upper-right
  overlay near their matched point; unmatched photos are clearly identified.
- Invalid GPX, unsupported images, and export failures surface a useful error.
