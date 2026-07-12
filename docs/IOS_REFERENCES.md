# iOS References for CourtVision

Curated from [vsouza/awesome-ios](https://github.com/vsouza/awesome-ios) and
[dkhamsing/open-source-ios-apps](https://github.com/dkhamsing/open-source-ios-apps),
filtered to what CourtVision actually touches. These are **reading material,
not dependencies** — the app is deliberately zero-dependency (Supabase SDK
excepted); read their source for patterns, don't `import` them.

---

## 1. On-device detection / CoreML (Rim · Ball · Player modules)

| Reference | Why it matters to us |
|---|---|
| [Ultralytics YOLO iOS App](https://github.com/ultralytics/yolo-ios-app) | **Official YOLO-on-iPhone app, full source.** Same stack as ours (YOLOv8 → CoreML → Vision). Read for: camera→model frame plumbing, thermal management, model-swap UX. The single most relevant repo in either list. |
| [ObjectDetection-CoreML (tucan9389)](https://github.com/tucan9389/ObjectDetection-CoreML) | Minimal real-time Vision+CoreML detection loop — clean reference for `VNCoreMLRequest` usage, overlay drawing, FPS measurement. Compare against our `ObjectDetector`. |
| [Awesome-CoreML-Models](https://github.com/likedan/Awesome-CoreML-Models) | Catalog of ready CoreML models — useful when scouting a pretrained pose/keypoint model for the court module. |
| [Clearcam](https://github.com/roryclear/clearcam) | IP camera app with on-device AI object detection (2026, active) — patterns for long-running detection sessions without overheating. |
| [Lumina](https://github.com/dokun1/Lumina) | Camera lib that **streams CoreML predictions per frame** — its pipeline design (single session, prediction stream) parallels our CameraService + finder loops. |

## 2. Camera / AVFoundation (CameraService)

| Reference | Why |
|---|---|
| [NextLevel](https://github.com/NextLevel/NextLevel) | The most complete AVFoundation capture reference: lens switching, frame-rate control, buffer handling. Read when we need 60fps capture tuning or multi-lens work. |
| [CameraManager](https://github.com/imaginary-cloud/CameraManager) | Compact single-class camera wrapper — sanity-check our `CameraService` decisions (session config, orientation, permissions). |
| [iOS-Depth-Sampler (shu223)](https://github.com/shu223/iOS-Depth-Sampler) | Depth API examples. Relevant to the known 2D ceiling of shot detection — LiDAR/depth could one day disambiguate "ball in front of rim" vs "ball at rim". |
| [SCRecorder](https://github.com/rFlex/SCRecorder) / [PryntTrimmerView](https://github.com/HHK1/PryntTrimmerView) | Video segment recording + trim UI — for the future "shot replay clips" feature (save the 4 s around each detected shot). |

## 3. Vision / OCR (Jersey numbers)

| Reference | Why |
|---|---|
| Apple `VNRecognizeTextRequest` (what we use) | Native, ROI-scoped — already in `NumberReader`. Native beats libraries here. |
| [SwiftOCR](https://github.com/garnele007/SwiftOCR) | Legacy custom OCR — only worth reading if Vision OCR proves too slow on tiny jersey crops (it trains tiny per-font networks). |

## 4. Algorithms (tracking, future shot pipeline)

| Reference | Why |
|---|---|
| [swift-algorithm-club](https://github.com/kodecocodes/swift-algorithm-club) | Explained Swift implementations — k-d trees (nearest-player-to-ball), priority queues, Kalman-adjacent smoothing. First stop before writing any nontrivial algorithm. |
| [SwiftPriorityQueue](https://github.com/davecom/SwiftPriorityQueue) | Binary heap — if multi-object player tracking (Hungarian assignment) ever lands. |
| [SwiftGraph](https://github.com/davecom/SwiftGraph) | Graph utilities — same future bucket. |
| [AIToolbox](https://github.com/KevinCoble/AIToolbox) | Classic ML in Swift (KMeans, regression) — KMeans on jersey colors is the cheap path to auto team-assignment (no jersey number needed). |

## 5. Stats UI (session summary screens)

Native **Swift Charts** (iOS 16+) first — no library needed for our bar/line
summaries. If we ever outgrow it:

| Reference | Why |
|---|---|
| [Charts (danielgindi)](https://github.com/danielgindi/Charts) | The heavyweight standard (MPAndroidChart port) — shot charts, heatmaps beyond what Swift Charts does. |
| [SwiftChart](https://github.com/gpbl/SwiftChart) | Tiny line/area charts — closer to our ponytail taste if native ever falls short. |

## 6. Whole apps worth reading (open-source-ios-apps)

| App | Why |
|---|---|
| [Ultralytics YOLO](https://github.com/ultralytics/yolo-ios-app) | (again — it's that relevant) |
| [ObjectDetection-CoreML](https://github.com/tucan9389/ObjectDetection-CoreML) | (again) |
| Apple's [Destination Video](https://developer.apple.com/documentation/visionos/destination-video) | Apple-blessed AVFoundation/SwiftUI media architecture. |
| [VLC for iOS](https://github.com/videolan/vlc-ios) | Battle-tested video handling at scale — reference for the replay/clips feature. |

## Not needed (checked and rejected)

- Camera picker/filter libs (Fusuma, YPImagePicker, SwiftyCam…) — we run a
  raw capture session, not a picker.
- Networking libs (Alamofire…) — Supabase SDK + URLSession cover us.
- Streaming (HaishinKit…) — dashboard is web via Supabase Realtime; the phone
  never streams video.
- TensorFlow/Bender/DL4S — CoreML is the only sane on-device runtime for us.
- Chart libs *today* — web dashboard owns analytics; iOS shows numbers.

---

*Rule of thumb (ponytail): these repos are for reading when a module hits a
wall — pattern first, dependency never, native API before either.*
