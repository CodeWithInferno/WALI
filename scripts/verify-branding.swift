#!/usr/bin/env swift
import AppKit
import Foundation

// Inspect compiled resources without launching WALI or its background services.
enum BrandingVerificationError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BrandingVerificationError.invalid(message) }
}

do {
    try require(CommandLine.arguments.count == 2, "Usage: xcrun swift scripts/verify-branding.swift /path/to/WALI.app")
    let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let bundleURLs = [
        appURL,
        appURL.appendingPathComponent("Contents/Library/LoginItems/WALIAgent.app"),
        appURL.appendingPathComponent("Contents/Library/LoginItems/WALILockScreenHelper.app"),
    ]

    for url in bundleURLs {
        guard let bundle = Bundle(url: url), let resources = bundle.resourceURL else {
            throw BrandingVerificationError.invalid("Missing bundle: \(url.path)")
        }
        let name = url.lastPathComponent
        try require(bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon", "\(name): missing AppIcon metadata")
        guard let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else {
            throw BrandingVerificationError.invalid("\(name): missing icon filename")
        }
        let iconURL = resources.appendingPathComponent(iconFile.hasSuffix(".icns") ? iconFile : iconFile + ".icns")
        try require(NSImage(contentsOf: iconURL)?.isValid == true, "\(name): unreadable compiled app icon")

        guard let mark = bundle.image(forResource: NSImage.Name("WALIMark")),
              let menu = bundle.image(forResource: NSImage.Name("WALIMenuBar")) else {
            throw BrandingVerificationError.invalid("\(name): brand images missing from its own asset catalog")
        }
        try require(mark.isValid && !mark.isTemplate, "\(name): brand mark must use its original color")
        try require(menu.isValid && menu.isTemplate, "\(name): menu-bar mark must be a template image")
        try require(menu.size == NSSize(width: 24, height: 14), "\(name): unexpected menu-bar image size \(menu.size)")
        print("Branding verified: \(name), app icon + color mark + 24×14pt menu template")
    }
} catch {
    FileHandle.standardError.write(Data("Branding verification failed: \(error)\n".utf8))
    exit(1)
}
