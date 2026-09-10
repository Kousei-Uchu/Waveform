// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WaveformBackendKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "WaveformBackendKit", targets: ["WaveformBackendKit"])
    ],
    dependencies: [
        // v3: the .cmf/zip format is gone (spec §2), so ZIPFoundation is no
        // longer a dependency of this package.
        // YouTubeKit (stream resolution) lands now that Acquire/Resolve.swift
        // exists (§9). YouTubeSDK is gone: search moved server-side to
        // waveform-search-backend (youtubei.js on Vercel) — see
        // Acquire/Search.swift and Acquire/BackendConfig.swift. YouTubeKit
        // stays, unrelated to that change — it only ever resolves an
        // already-picked video ID's stream URL, entirely on-device.
        .package(url: "https://github.com/alexeichhorn/YouTubeKit.git", from: "0.4.0")
        // kingslay/FFmpegKit (Shrink's libsvtav1+libopus encode, §9) —
        // Acquire/Shrink.swift exists now and its FFmpegRunning protocol
        // is ready to consume this, but the package still isn't added as
        // an actual target dependency below (see Shrink.swift's commented
        // -out FFmpegKitRunner for why): unlike YouTubeKit, adding this
        // line alone isn't enough to build — `swift package
        // --disable-sandbox BuildFFmpeg` has to be run once, locally in
        // Xcode, to compile the native FFmpeg libraries the target would
        // link against, and that can't be verified from outside an Xcode
        // environment. Uncomment once that build step has been run and
        // FFmpegKitRunner is uncommented alongside it:
        //.package(url: "https://github.com/kingslay/FFmpegKit.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "WaveformBackendKit",
            dependencies: [
                .product(name: "YouTubeKit", package: "YouTubeKit")
            ]
        ),
        .testTarget(
            name: "WaveformBackendKitTests",
            dependencies: [
                "WaveformBackendKit"
            ]
        )
    ]
)
