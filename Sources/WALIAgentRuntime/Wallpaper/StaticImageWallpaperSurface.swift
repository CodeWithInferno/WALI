import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import QuartzCore
import WALIModel

/// The real desktop canvas and a deterministic, window-free test canvas.
/// One presentation adapter owns its layout callback at a time.
@MainActor
protocol StaticImageWallpaperCanvas: AnyObject {
    var onLayout: (@MainActor (CGRect, CGFloat) -> Void)? { get set }
    func addSurface(_ surfaceLayer: CALayer, visible: Bool)
    func removeSurface(_ surfaceLayer: CALayer)
}

extension WallpaperCanvasView: StaticImageWallpaperCanvas {}

enum StaticImageWallpaperError: Error, Equatable, LocalizedError {
    case invalidImage
    case canvasInUse
    case closed
    var errorDescription: String? {
        switch self {
        case .invalidImage: "The installed wallpaper image is not supported."
        case .canvasInUse: "The wallpaper display is already in use."
        case .closed: "The wallpaper display has stopped."
        }
    }
}

/// Displays an already verified raster on an agent-owned canvas. File decoding,
/// installation and assignment authority remain outside this presentation adapter.
/// This adapter has no player, timer, file access or system-wallpaper mutation.
@MainActor
final class StaticImageWallpaperSurface {
    nonisolated fileprivate static let maximumDimension = 7_680
    nonisolated fileprivate static let maximumPixels = 7_680 * 4_320
    nonisolated fileprivate static let maximumDecodedBytes = 128 * 1_024 * 1_024

    private let canvas: any StaticImageWallpaperCanvas
    private let containerLayer = CALayer()
    private let imageLayer = CALayer()
    private var image: CGImage?
    private var scaling: PresentationContentFit = .fill
    private var bounds = CGRect.zero
    private var backingScaleFactor: CGFloat = 1
    private var attached = false
    private var closed = false

    init(canvas: any StaticImageWallpaperCanvas) throws {
        guard canvas.onLayout == nil else { throw StaticImageWallpaperError.canvasInUse }
        self.canvas = canvas
        containerLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        containerLayer.masksToBounds = true
        containerLayer.addSublayer(imageLayer)
        canvas.onLayout = { [weak self] bounds, scale in
            self?.layout(in: bounds, backingScaleFactor: scale)
        }
    }

    func present(_ image: CGImage, scaling: PresentationContentFit) throws {
        guard !closed else { throw StaticImageWallpaperError.closed }
        try Self.validate(image)
        guard self.image !== image || self.scaling != scaling else { return }
        self.image = image
        self.scaling = scaling
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        switch scaling {
        case .fill: imageLayer.contentsGravity = .resizeAspectFill
        case .fit, .center: imageLayer.contentsGravity = .resizeAspect
        case .stretch: imageLayer.contentsGravity = .resize
        }
        CATransaction.commit()
        if !attached {
            attached = true
            canvas.addSurface(containerLayer, visible: true)
        }
        layout(in: bounds, backingScaleFactor: backingScaleFactor)
    }

    nonisolated static func validate(_ image: CGImage) throws {
        guard image.width > 0, image.height > 0,
              image.width <= Self.maximumDimension, image.height <= Self.maximumDimension,
              image.width * image.height <= Self.maximumPixels,
              image.bitsPerComponent == 8, (8...32).contains(image.bitsPerPixel),
              image.bytesPerRow > 0,
              image.bytesPerRow <= Self.maximumDecodedBytes / image.height
        else { throw StaticImageWallpaperError.invalidImage }
    }

    func setScaling(_ scaling: PresentationContentFit) {
        guard let image, !closed else { return }
        // The retained image already passed the same validation on presentation.
        try? present(image, scaling: scaling)
    }

    func tearDown() {
        guard !closed else { return }
        closed = true
        canvas.onLayout = nil
        imageLayer.contents = nil
        image = nil
        imageLayer.removeAllAnimations()
        if attached {
            canvas.removeSurface(containerLayer)
            attached = false
        }
    }

    private func layout(in bounds: CGRect, backingScaleFactor: CGFloat) {
        guard !closed,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 0, bounds.height >= 0,
              backingScaleFactor.isFinite, backingScaleFactor > 0
        else { return }
        self.bounds = bounds
        self.backingScaleFactor = backingScaleFactor
        guard let image else { return }
        let scale = max(backingScaleFactor, 1)
        let localBounds = CGRect(origin: .zero, size: bounds.size)
        let imageFrame: CGRect
        if scaling == .center {
            let nativeWidth = CGFloat(image.width) / scale
            let nativeHeight = CGFloat(image.height) / scale
            let shrink = min(1, localBounds.width / nativeWidth, localBounds.height / nativeHeight)
            let size = CGSize(width: nativeWidth * shrink, height: nativeHeight * shrink)
            imageFrame = CGRect(x: (localBounds.width - size.width) / 2,
                                y: (localBounds.height - size.height) / 2,
                                width: size.width, height: size.height)
        } else { imageFrame = localBounds }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = bounds
        imageLayer.frame = imageFrame
        imageLayer.contentsScale = scale
        CATransaction.commit()
    }
}

/// Serial, off-main verification of canonical PNG worker claims or installed
/// objects. The caller first verifies candidate containment or object authority;
/// this decoder grants no file authority and never receives original imports.
actor StaticWallpaperImageLoader {
    static let shared = StaticWallpaperImageLoader()

    func load(_ url: URL) throws -> CGImage {
        try Task.checkCancellation()
        guard url.isFileURL, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host == "localhost"
        else { throw StaticImageWallpaperError.invalidImage }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StaticImageWallpaperError.invalidImage }
        defer { close(descriptor) }
        var info = stat()
        let byteLimit = StaticImageWallpaperSurface.maximumDecodedBytes
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= byteLimit
        else { throw StaticImageWallpaperError.invalidImage }
        var bytes = Data()
        bytes.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw StaticImageWallpaperError.invalidImage }
            if count == 0 { break }
            guard bytes.count <= byteLimit - count else { throw StaticImageWallpaperError.invalidImage }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count == Int(info.st_size) else { throw StaticImageWallpaperError.invalidImage }
        try validatePNGChunks(bytes)
        guard let source = CGImageSourceCreateWithData(bytes as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source), type as String == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...7_680).contains(width), (1...7_680).contains(height),
              width * height <= 7_680 * 4_320,
              properties[kCGImagePropertyDepth] as? Int == 8,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        else { throw StaticImageWallpaperError.invalidImage }
        let forbiddenProperties: [CFString] = [kCGImagePropertyExifDictionary,
            kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
            kCGImagePropertyMakerAppleDictionary]
        guard forbiddenProperties.allSatisfy({ properties[$0] == nil }) else {
            throw StaticImageWallpaperError.invalidImage
        }
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height,
              image.colorSpace?.name == CGColorSpace.sRGB,
              [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        else { throw StaticImageWallpaperError.invalidImage }
        try StaticImageWallpaperSurface.validate(image)
        try Task.checkCancellation()
        return image
    }

    /// Screen the container before ImageIO, which can silently ignore ancillary
    /// metadata and trailing bytes. Only raster structure, SDR color profiles and
    /// pixel density survive canonicalization; animation and private text do not.
    private func validatePNGChunks(_ bytes: Data) throws {
        guard bytes.count >= 8, bytes.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10])
        else { throw StaticImageWallpaperError.invalidImage }
        let permitted: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "cHRM", "gAMA",
                                      "iCCP", "sRGB", "sBIT", "pHYs"]
        var offset = 8
        var chunkCount = 0
        var hasHeader = false
        var hasPixels = false
        while offset < bytes.count {
            try Task.checkCancellation()
            chunkCount += 1
            guard chunkCount <= 16_384, bytes.count - offset >= 12 else {
                throw StaticImageWallpaperError.invalidImage
            }
            let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            guard length <= bytes.count - offset - 12,
                  let kind = String(data: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii),
                  permitted.contains(kind), hasHeader || kind == "IHDR"
            else { throw StaticImageWallpaperError.invalidImage }
            switch kind {
            case "IHDR":
                guard !hasHeader, offset == 8, length == 13 else {
                    throw StaticImageWallpaperError.invalidImage
                }
                hasHeader = true
            case "IDAT":
                hasPixels = hasPixels || length > 0
            case "IEND":
                guard hasPixels, length == 0, offset + 12 == bytes.count else {
                    throw StaticImageWallpaperError.invalidImage
                }
                return
            case "iCCP":
                // Canonical sRGB ICC profiles are small; bound compressed profile
                // bytes before asking ImageIO to interpret them.
                guard length <= 1_048_576 else { throw StaticImageWallpaperError.invalidImage }
            default: break
            }
            offset += length + 12
        }
        throw StaticImageWallpaperError.invalidImage
    }

}
