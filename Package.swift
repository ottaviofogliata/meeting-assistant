// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingAssistant",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MeetingAssistant", targets: ["MeetingAssistant"]),
        .executable(name: "meeting-assistant-qa", targets: ["MeetingAssistantQA"]),
        .library(name: "MeetingCore", targets: ["MeetingCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")
    ],
    targets: [
        .target(name: "MeetingCore"),
        .target(name: "MeetingRuntime", dependencies: [
            "MeetingCore",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "SpeakerKit", package: "argmax-oss-swift")
        ]),
        .executableTarget(name: "MeetingAssistant", dependencies: ["MeetingCore", "MeetingRuntime"]),
        .executableTarget(name: "MeetingAssistantQA", dependencies: ["MeetingCore", "MeetingRuntime"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingRuntimeTests", dependencies: ["MeetingRuntime", "MeetingCore"])
    ],
    swiftLanguageModes: [.v5]
)
