import CoreGraphics
import Foundation
import QuartzCore
import WALIModel
import XCTest
@testable import WALIAgentRuntime

@MainActor
final class WallpaperContentPresenterTests: XCTestCase {
    func testStillUsesNoPlayerAndRemainsDisplayedWhenMotionIsPaused() async throws {
        let canvas = PresenterCanvas()
        let factory = VideoFactory(canvas: canvas)
        let raster = try makeImage()
        let presenter = WallpaperContentPresenter(canvas: canvas, makeVideo: factory.make,
            loadImage: { _ in raster })
        presenter.setContent(.still(imageURL: imageURL), scaling: .fit)
        await waitUntil { presenter.status == .displaying }
        presenter.setPaused(userPaused: true, automaticReasons: [.lowPower, .windowOccluded])
        XCTAssertEqual(presenter.status, .displaying)
        XCTAssertEqual(factory.players.count, 0)
        XCTAssertEqual(canvas.layers.count, 1)
        presenter.tearDown()
        XCTAssertTrue(canvas.layers.isEmpty)
        XCTAssertNil(canvas.onLayout)
    }

    func testKindSwitchReleasesThePriorCanvasOwnerAndIgnoresOldPlayerEvents() async throws {
        let canvas = PresenterCanvas()
        let factory = VideoFactory(canvas: canvas)
        let raster = try makeImage()
        let presenter = WallpaperContentPresenter(canvas: canvas, makeVideo: factory.make,
            loadImage: { _ in raster })
        presenter.setContent(.still(imageURL: imageURL), scaling: .fill)
        await waitUntil { presenter.status == .displaying }
        presenter.setContent(videoContent, scaling: .fit)
        await waitUntil { presenter.status == .playing }
        XCTAssertTrue(canvas.layers.isEmpty)
        let player = try XCTUnwrap(factory.players.first)
        XCTAssertEqual(player.replacements, 1)
        presenter.setContent(.still(imageURL: imageURL), scaling: .center)
        await waitUntil { presenter.status == .displaying }
        XCTAssertEqual(player.stops, 1)
        player.emit(.failed("stale video failure"))
        XCTAssertEqual(presenter.status, .displaying)
        XCTAssertEqual(canvas.layers.count, 1)
        presenter.tearDown()
        presenter.tearDown()
        XCTAssertEqual(player.stops, 1)
    }

    func testAReplacedImageLoadCannotOverwriteTheNewerVideo() async throws {
        let canvas = PresenterCanvas()
        let factory = VideoFactory(canvas: canvas)
        let gate = ImageGate()
        let presenter = WallpaperContentPresenter(canvas: canvas, makeVideo: factory.make,
            loadImage: { try await gate.load($0) })
        presenter.setContent(.still(imageURL: imageURL), scaling: .fill)
        await waitUntil { gate.pending != nil }
        presenter.setContent(videoContent, scaling: .fill)
        await waitUntil { presenter.status == .playing }
        gate.finish(try makeImage())
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(presenter.status, .playing)
        XCTAssertTrue(canvas.layers.isEmpty)
        XCTAssertEqual(factory.players.count, 1)
        presenter.tearDown()
    }

    func testStoppedImageLoadCannotReattachAndRepeatedTeardownIsSafe() async throws {
        let canvas = PresenterCanvas()
        let factory = VideoFactory(canvas: canvas)
        let gate = ImageGate()
        let presenter = WallpaperContentPresenter(canvas: canvas, makeVideo: factory.make,
            loadImage: { try await gate.load($0) })
        presenter.setContent(.still(imageURL: imageURL), scaling: .fill)
        await waitUntil { gate.pending != nil }
        presenter.tearDown()
        presenter.tearDown()
        gate.finish(try makeImage())
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(canvas.layers.isEmpty)
        XCTAssertNil(canvas.onLayout)
        XCTAssertEqual(factory.players.count, 0)
        presenter.setContent(videoContent, scaling: .fill)
        XCTAssertEqual(factory.players.count, 0)
    }

    func testScalingAndMotionPreferenceChangesDoNotDecodeTheImageAgain() async throws {
        let canvas = PresenterCanvas()
        let factory = VideoFactory(canvas: canvas)
        var loads = 0
        let raster = try makeImage()
        let presenter = WallpaperContentPresenter(canvas: canvas, makeVideo: factory.make,
            loadImage: { _ in loads += 1; return raster })
        presenter.setContent(.still(imageURL: imageURL), scaling: .fill)
        await waitUntil { presenter.status == .displaying }
        presenter.setContent(.still(imageURL: imageURL), scaling: .stretch)
        presenter.setPaused(userPaused: true, automaticReasons: [.lowPower])
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(canvas.layers.first?.sublayers?.first?.contentsGravity, .resize)
        XCTAssertEqual(presenter.status, .displaying)
        presenter.tearDown()
    }

    func testFailedReplacementKeepsThePreviousStillAndCanBeRetried() async throws {
        let canvas = PresenterCanvas()
        let factory = VideoFactory(canvas: canvas)
        let raster = try makeImage()
        var reject = false
        let presenter = WallpaperContentPresenter(canvas: canvas, makeVideo: factory.make,
            loadImage: { _ in
                if reject { throw StaticImageWallpaperError.invalidImage }
                return raster
            })
        presenter.setContent(.still(imageURL: imageURL), scaling: .fit)
        await waitUntil { presenter.status == .displaying }
        reject = true
        let replacement = WallpaperRenderingContent.still(imageURL: URL(fileURLWithPath: "/verified/second.png"))
        presenter.setContent(replacement, scaling: .fill)
        await waitUntil { if case .failed = presenter.status { true } else { false } }
        XCTAssertEqual(canvas.layers.count, 1)
        XCTAssertTrue((canvas.layers.first?.sublayers?.first?.contents as AnyObject?) === raster)
        reject = false
        presenter.setContent(replacement, scaling: .fill)
        await waitUntil { presenter.status == .displaying }
        XCTAssertEqual(canvas.layers.count, 1)
        presenter.tearDown()
    }

    func testVideoReadinessFailureRemainsAnErrorWhenPausePreferencesChange() async throws {
        let canvas = PresenterCanvas()
        let factory = VideoFactory(canvas: canvas)
        let raster = try makeImage()
        let presenter = WallpaperContentPresenter(canvas: canvas, makeVideo: factory.make,
            loadImage: { _ in raster })
        presenter.setContent(videoContent, scaling: .fill)
        await waitUntil { presenter.status == .playing }
        let player = try XCTUnwrap(factory.players.first)
        player.emit(.failed("Video could not be decoded."))
        XCTAssertEqual(presenter.status, .failed("Video could not be decoded."))
        presenter.setPaused(userPaused: true, automaticReasons: [.lowPower])
        XCTAssertEqual(presenter.status, .failed("Video could not be decoded."))
        presenter.tearDown()
    }

    private var imageURL: URL { URL(fileURLWithPath: "/verified/master.png") }
    private var videoContent: WallpaperRenderingContent {
        .video(videoURL: URL(fileURLWithPath: "/verified/master.mov"),
               efficientVideoURL: nil, posterURL: nil, lowPowerResponse: .pause)
    }
    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4,
            bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Expected presentation event was not delivered", file: file, line: line)
    }
}

@MainActor
private final class ImageGate {
    var pending: CheckedContinuation<CGImage, any Error>?
    func load(_ url: URL) async throws -> CGImage {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ image: CGImage) { pending?.resume(returning: image); pending = nil }
}

@MainActor
private final class PresenterCanvas: StaticImageWallpaperCanvas {
    var onLayout: (@MainActor (CGRect, CGFloat) -> Void)?
    var layers: [CALayer] = []
    func addSurface(_ layer: CALayer, visible: Bool) {
        layers.append(layer)
        onLayout?(CGRect(x: 0, y: 0, width: 20, height: 12), 2)
    }
    func removeSurface(_ layer: CALayer) { layers.removeAll { $0 === layer } }
}

@MainActor
private final class VideoFactory {
    let canvas: PresenterCanvas
    var players: [PresenterVideo] = []
    init(canvas: PresenterCanvas) { self.canvas = canvas }
    func make() -> any WallpaperVideoPresenting {
        XCTAssertNil(canvas.onLayout, "The previous adapter must release the canvas first")
        canvas.onLayout = { _, _ in }
        let player = PresenterVideo()
        players.append(player)
        return player
    }
}

@MainActor
private final class PresenterVideo: WallpaperVideoPresenting {
    var onStateChange: (@MainActor (LoopingVideoPlaybackState) -> Void)?
    var state: LoopingVideoPlaybackState = .empty
    var replacements = 0
    var stops = 0
    var isPaused = false
    func replace(videoURL: URL, posterURL: URL?, scaling: PresentationContentFit) async throws {
        replacements += 1
        emit(isPaused ? .paused : .playing)
    }
    func setScaling(_ scaling: PresentationContentFit) {}
    func setPaused(_ paused: Bool) { isPaused = paused }
    func stop() { stops += 1; emit(.empty) }
    func emit(_ state: LoopingVideoPlaybackState) { self.state = state; onStateChange?(state) }
}
