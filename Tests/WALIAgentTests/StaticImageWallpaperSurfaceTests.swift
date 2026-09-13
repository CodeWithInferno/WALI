import CoreGraphics
import QuartzCore
import WALIModel
import XCTest
@testable import WALIAgentRuntime

@MainActor
final class StaticImageWallpaperSurfaceTests: XCTestCase {
    func testReplacementKeepsOneSurfaceAndRetainsOnlyCurrentImage() throws {
        let canvas = FakeStaticImageCanvas()
        let surface = try StaticImageWallpaperSurface(canvas: canvas)
        let first = try image(width: 8, height: 4)
        let second = try image(width: 4, height: 8)
        try surface.present(first, scaling: .fill)
        let container = try XCTUnwrap(canvas.layers.first)
        let raster = try XCTUnwrap(container.sublayers?.first)
        XCTAssertTrue((raster.contents as AnyObject?) === first)
        try surface.present(second, scaling: .fit)
        XCTAssertEqual(canvas.additions, 1)
        XCTAssertEqual(canvas.layers.count, 1)
        XCTAssertTrue(canvas.layers.first === container)
        XCTAssertTrue((raster.contents as AnyObject?) === second)
        XCTAssertEqual(raster.contentsGravity, .resizeAspect)
        XCTAssertNil(raster.animationKeys())
        surface.tearDown()
    }

    func testCenterUsesNativePixelsOnRetinaWithoutUpscaling() throws {
        let canvas = FakeStaticImageCanvas()
        let surface = try StaticImageWallpaperSurface(canvas: canvas)
        try surface.present(image(width: 8, height: 4), scaling: .center)
        canvas.resize(CGRect(x: 0, y: 0, width: 20, height: 12), scale: 2)
        let raster = try XCTUnwrap(canvas.layers.first?.sublayers?.first)
        XCTAssertEqual(raster.frame, CGRect(x: 8, y: 5, width: 4, height: 2))
        XCTAssertEqual(raster.contentsScale, 2)
        canvas.resize(CGRect(x: 0, y: 0, width: 2, height: 2), scale: 2)
        XCTAssertEqual(raster.frame, CGRect(x: 0, y: 0.5, width: 2, height: 1))
        surface.tearDown()
    }

    func testFitFillStretchUseExistingContentFitSemantics() throws {
        let canvas = FakeStaticImageCanvas()
        let surface = try StaticImageWallpaperSurface(canvas: canvas)
        let value = try image(width: 8, height: 4)
        for (fit, gravity): (PresentationContentFit, CALayerContentsGravity) in [
            (.fill, .resizeAspectFill), (.fit, .resizeAspect), (.stretch, .resize)
        ] {
            try surface.present(value, scaling: fit)
            canvas.resize(CGRect(x: 0, y: 0, width: 20, height: 12), scale: 2)
            let raster = try XCTUnwrap(canvas.layers.first?.sublayers?.first)
            XCTAssertEqual(raster.frame, CGRect(x: 0, y: 0, width: 20, height: 12))
            XCTAssertEqual(raster.contentsGravity, gravity)
        }
        XCTAssertEqual(canvas.additions, 1)
        surface.tearDown()
    }

    func testInvalidImageAndLayoutLeaveCurrentPresentationIntact() throws {
        let canvas = FakeStaticImageCanvas()
        let surface = try StaticImageWallpaperSurface(canvas: canvas)
        let valid = try image(width: 8, height: 4)
        try surface.present(valid, scaling: .fit)
        canvas.resize(CGRect(x: 0, y: 0, width: 20, height: 12), scale: 2)
        let raster = try XCTUnwrap(canvas.layers.first?.sublayers?.first)
        let frame = raster.frame
        XCTAssertThrowsError(try surface.present(image(width: 7_681, height: 1), scaling: .fill)) {
            XCTAssertEqual($0 as? StaticImageWallpaperError, .invalidImage)
        }
        canvas.resize(CGRect(x: 0, y: 0, width: CGFloat.nan, height: 12), scale: 2)
        canvas.resize(CGRect(x: 0, y: 0, width: 20, height: 12), scale: .infinity)
        XCTAssertEqual(raster.frame, frame)
        XCTAssertTrue((raster.contents as AnyObject?) === valid)
        XCTAssertEqual(canvas.additions, 1)
        surface.tearDown()
    }

    func testTeardownReleasesImageOnceAndRejectsLatePresentation() throws {
        let canvas = FakeStaticImageCanvas()
        let surface = try StaticImageWallpaperSurface(canvas: canvas)
        let value = try image(width: 8, height: 4)
        try surface.present(value, scaling: .fill)
        let raster = try XCTUnwrap(canvas.layers.first?.sublayers?.first)
        surface.tearDown()
        surface.tearDown()
        XCTAssertTrue(canvas.layers.isEmpty)
        XCTAssertEqual(canvas.removals, 1)
        XCTAssertNil(canvas.onLayout)
        XCTAssertNil(raster.contents)
        XCTAssertThrowsError(try surface.present(value, scaling: .fill)) {
            XCTAssertEqual($0 as? StaticImageWallpaperError, .closed)
        }
        XCTAssertEqual(canvas.additions, 1)
    }

    func testEachDisplayHasIndependentOwnershipAndRejectsCompetingCanvasOwner() throws {
        let first = FakeStaticImageCanvas()
        let second = FakeStaticImageCanvas()
        let a = try StaticImageWallpaperSurface(canvas: first)
        let b = try StaticImageWallpaperSurface(canvas: second)
        XCTAssertThrowsError(try StaticImageWallpaperSurface(canvas: first)) {
            XCTAssertEqual($0 as? StaticImageWallpaperError, .canvasInUse)
        }
        let value = try image(width: 8, height: 4)
        try a.present(value, scaling: .fit)
        try b.present(value, scaling: .stretch)
        a.tearDown()
        XCTAssertEqual(second.layers.count, 1)
        XCTAssertNotNil(second.onLayout)
        b.tearDown()
    }

    func testCoreAnimationRendersCenteredPixelsWithBlackSurroundingArea() throws {
        let canvas = FakeStaticImageCanvas()
        let surface = try StaticImageWallpaperSurface(canvas: canvas)
        let source = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4,
            bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        source.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        source.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        try surface.present(try XCTUnwrap(source.makeImage()), scaling: .center)
        canvas.resize(CGRect(x: 0, y: 0, width: 20, height: 12), scale: 1)
        let target = try XCTUnwrap(CGContext(data: nil, width: 20, height: 12,
            bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        try XCTUnwrap(canvas.layers.first).render(in: target)
        let pixels = try XCTUnwrap(target.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixels[(6 * 20 + 10) * 4], 240)
        XCTAssertLessThan(pixels[(6 * 20 + 10) * 4 + 1], 10)
        XCTAssertLessThan(pixels[(1 * 20 + 1) * 4], 10)
        XCTAssertLessThan(pixels[(1 * 20 + 1) * 4 + 1], 10)
        surface.tearDown()
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
private final class FakeStaticImageCanvas: StaticImageWallpaperCanvas {
    var onLayout: (@MainActor (CGRect, CGFloat) -> Void)?
    private(set) var layers: [CALayer] = []
    private(set) var additions = 0
    private(set) var removals = 0

    func addSurface(_ layer: CALayer, visible: Bool) {
        additions += 1
        layers.append(layer)
        layer.opacity = visible ? 1 : 0
        onLayout?(CGRect(x: 0, y: 0, width: 20, height: 12), 1)
    }

    func removeSurface(_ layer: CALayer) {
        removals += 1
        layers.removeAll { $0 === layer }
    }

    func resize(_ bounds: CGRect, scale: CGFloat) { onLayout?(bounds, scale) }
}
