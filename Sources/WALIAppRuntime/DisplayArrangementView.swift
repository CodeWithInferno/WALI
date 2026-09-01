import SwiftUI
import WALIUI

/// A selection-only view of the physical display topology.
///
/// The engine remains authoritative for assignments. This view updates the
/// pending display selection and leaves mutation to the wallpaper detail
/// surface's Apply action.
struct DisplayArrangementView: View {
    let displays: [WALIDisplayPresentation]
    let wallpapers: [WALIWallpaperPresentation]
    @Binding var selection: Set<String>
    let onDone: () -> Void

    private var connectedDisplays: [WALIDisplayPresentation] {
        displays.filter(\.isConnected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose Displays")
                    .font(.headline)
                Text("Select where this wallpaper will appear. Display positions match System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            arrangement

            HStack(spacing: 8) {
                Button("All Displays") {
                    selection = Set(connectedDisplays.map(\.id))
                }
                .disabled(connectedDisplays.isEmpty || selection == Set(connectedDisplays.map(\.id)))
                .accessibilityIdentifier("WALI.DisplayArrangement.AllDisplays")

                Spacer(minLength: 0)

                Text(selectionSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("WALI.DisplayArrangement.Done")
            }
        }
        .padding(16)
        .frame(width: 560, height: 370)
        .onExitCommand(perform: onDone)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("WALI.DisplayArrangement")
    }

    @ViewBuilder
    private var arrangement: some View {
        if connectedDisplays.isEmpty {
            ContentUnavailableView {
                Label("No Displays Available", systemImage: "display.trianglebadge.exclamationmark")
            } description: {
                Text("Connect a display to choose where the wallpaper appears.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("WALI.DisplayArrangement.Empty")
        } else {
            GeometryReader { proxy in
                let layout = DisplayArrangementLayout.layout(
                    for: connectedDisplays,
                    in: proxy.size
                )

                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))

                        ForEach(layout.placements) { placement in
                            displayTile(
                                placement.display,
                                isMirrored: placement.isMirrored,
                                isCompact: placement.isCompact
                            )
                                .frame(
                                    width: placement.frame.width,
                                    height: placement.frame.height
                                )
                                .position(
                                    x: placement.frame.midX,
                                    y: placement.frame.midY
                                )
                        }
                    }
                    .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
                }
                .defaultScrollAnchor(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("WALI.DisplayArrangement.Canvas")
        }
    }

    private func displayTile(
        _ display: WALIDisplayPresentation,
        isMirrored: Bool,
        isCompact: Bool
    ) -> some View {
        let isSelected = selection.contains(display.id)
        let wallpaper = wallpapers.first { $0.id == display.assignedWallpaperID }

        return Button {
            if isSelected {
                selection.remove(display.id)
            } else {
                selection.insert(display.id)
            }
        } label: {
            ZStack {
                ArtworkThumbnail(
                    imageURL: wallpaper?.thumbnailURL,
                    title: wallpaper?.title ?? "No wallpaper assigned",
                    cornerRadius: 8
                )
                .accessibilityHidden(true)

                if isCompact {
                    compactTileChrome(
                        display,
                        isMirrored: isMirrored,
                        isSelected: isSelected
                    )
                } else {
                    fullTileChrome(
                        display,
                        isMirrored: isMirrored,
                        isSelected: isSelected
                    )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 3 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            accessibilityLabel(
                for: display,
                wallpaper: wallpaper,
                isMirrored: isMirrored
            )
        )
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Toggles this display in the pending wallpaper assignment.")
        .accessibilityIdentifier("WALI.DisplayArrangement.Display.\(display.id)")
    }

    private func fullTileChrome(
        _ display: WALIDisplayPresentation,
        isMirrored: Bool,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if display.isBuiltIn {
                    Image(systemName: "laptopcomputer")
                        .accessibilityHidden(true)
                }
                if display.isMain {
                    Label("Main", systemImage: "menubar.rectangle")
                        .labelStyle(.titleAndIcon)
                }
                if isMirrored {
                    Image(systemName: "rectangle.on.rectangle")
                        .help("Mirrored display")
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                selectionIndicator(isSelected)
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(display.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Label(
                    display.contentFit?.arrangementLabel ?? "Default scaling",
                    systemImage: "arrow.up.left.and.arrow.down.right"
                )
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(6)
    }

    private func compactTileChrome(
        _ display: WALIDisplayPresentation,
        isMirrored: Bool,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if display.isBuiltIn {
                    Image(systemName: "laptopcomputer")
                }
                if display.isMain {
                    Image(systemName: "menubar.rectangle")
                        .help("Main display")
                }
                if isMirrored {
                    Image(systemName: "rectangle.on.rectangle")
                        .help("Mirrored display")
                }
                Spacer(minLength: 0)
                selectionIndicator(isSelected)
            }

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                Text(display.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .help(display.contentFit?.arrangementLabel ?? "Default scaling")
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }

    private func selectionIndicator(_ isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
    }

    private var selectionSummary: String {
        let selectedCount = connectedDisplays.count { selection.contains($0.id) }
        return "\(selectedCount) of \(connectedDisplays.count) selected"
    }

    private func accessibilityLabel(
        for display: WALIDisplayPresentation,
        wallpaper: WALIWallpaperPresentation?,
        isMirrored: Bool
    ) -> String {
        var details = [display.name]
        if display.isBuiltIn { details.append("built-in display") }
        if display.isMain { details.append("main display") }
        if isMirrored { details.append("mirrored display") }
        details.append(display.contentFit?.arrangementLabel ?? "default scaling")
        if let wallpaper {
            details.append("assigned to \(wallpaper.title)")
        } else {
            details.append("no wallpaper assigned")
        }
        return details.joined(separator: ", ")
    }
}

private enum DisplayArrangementLayout {
    private static let minimumTileSize = CGSize(width: 92, height: 64)
    private static let fullChromeThreshold = CGSize(width: 150, height: 94)
    private static let maximumGap: CGFloat = 8

    struct Result {
        let canvasSize: CGSize
        let placements: [Placement]
    }

    struct Placement: Identifiable {
        let display: WALIDisplayPresentation
        let frame: CGRect
        let isMirrored: Bool

        var id: String { display.id }
        var isCompact: Bool {
            frame.width < fullChromeThreshold.width
                || frame.height < fullChromeThreshold.height
        }
    }

    static func layout(
        for displays: [WALIDisplayPresentation],
        in canvasSize: CGSize
    ) -> Result {
        let logicalFrames = displays.compactMap { display -> (WALIDisplayPresentation, CGRect)? in
            guard
                let x = display.frameX,
                let y = display.frameY,
                let width = display.frameWidth,
                let height = display.frameHeight,
                width > 0,
                height > 0
            else {
                return nil
            }
            return (display, CGRect(x: x, y: y, width: width, height: height))
        }

        if logicalFrames.count == displays.count {
            return scaledLayout(for: logicalFrames, in: canvasSize)
        }

        let fallbackFrames = displays.enumerated().map { index, display in
            (
                display,
                CGRect(x: CGFloat(index) * 172, y: 0, width: 160, height: 100)
            )
        }
        return scaledLayout(for: fallbackFrames, in: canvasSize)
    }

    private static func scaledLayout(
        for logicalFrames: [(WALIDisplayPresentation, CGRect)],
        in canvasSize: CGSize
    ) -> Result {
        guard var union = logicalFrames.first?.1 else {
            return Result(canvasSize: canvasSize, placements: [])
        }
        for (_, frame) in logicalFrames.dropFirst() {
            union = union.union(frame)
        }

        let inset: CGFloat = 22
        let availableWidth = max(canvasSize.width - inset * 2, 1)
        let availableHeight = max(canvasSize.height - inset * 2, 1)
        let fittedScale = min(availableWidth / union.width, availableHeight / union.height)
        let scale = max(fittedScale, minimumUsableScale(for: logicalFrames))
        let renderedSize = CGSize(width: union.width * scale, height: union.height * scale)
        let contentSize = CGSize(
            width: max(canvasSize.width, renderedSize.width + inset * 2),
            height: max(canvasSize.height, renderedSize.height + inset * 2)
        )
        let origin = CGPoint(
            x: (contentSize.width - renderedSize.width) / 2,
            y: (contentSize.height - renderedSize.height) / 2
        )

        let placements = logicalFrames.map { display, frame in
            Placement(
                display: display,
                frame: CGRect(
                    x: origin.x + (frame.minX - union.minX) * scale,
                    y: origin.y + (union.maxY - frame.maxY) * scale,
                    width: frame.width * scale,
                    height: frame.height * scale
                ),
                isMirrored: false
            )
        }
        return Result(
            canvasSize: contentSize,
            placements: separatingCoincidentDisplays(placements)
        )
    }

    private static func minimumUsableScale(
        for logicalFrames: [(WALIDisplayPresentation, CGRect)]
    ) -> CGFloat {
        var groups: [[CGRect]] = []
        for (_, frame) in logicalFrames {
            if let groupIndex = groups.firstIndex(where: { $0[0] == frame }) {
                groups[groupIndex].append(frame)
            } else {
                groups.append([frame])
            }
        }

        return groups.reduce(0) { requiredScale, group in
            let frame = group[0]
            let grid = gridDimensions(count: group.count, in: frame)
            let requiredWidth = minimumTileSize.width * CGFloat(grid.columns)
                + maximumGap * CGFloat(grid.columns - 1)
            let requiredHeight = minimumTileSize.height * CGFloat(grid.rows)
                + maximumGap * CGFloat(grid.rows - 1)
            return max(
                requiredScale,
                requiredWidth / frame.width,
                requiredHeight / frame.height
            )
        }
    }

    private static func separatingCoincidentDisplays(
        _ placements: [Placement]
    ) -> [Placement] {
        var groups: [[Placement]] = []
        for placement in placements {
            if let groupIndex = groups.firstIndex(where: { $0[0].frame == placement.frame }) {
                groups[groupIndex].append(placement)
            } else {
                groups.append([placement])
            }
        }

        var adjustedFrames: [String: CGRect] = [:]
        let mirroredIDs = Set(
            groups
                .filter { $0.count > 1 }
                .flatMap { $0.map(\.id) }
        )
        for group in groups where group.count > 1 {
            let frames = separatedFrames(count: group.count, in: group[0].frame)
            for (placement, frame) in zip(group, frames) {
                adjustedFrames[placement.id] = frame
            }
        }

        return placements.map { placement in
            Placement(
                display: placement.display,
                frame: adjustedFrames[placement.id] ?? placement.frame,
                isMirrored: mirroredIDs.contains(placement.id)
            )
        }
    }

    private static func separatedFrames(count: Int, in sharedFrame: CGRect) -> [CGRect] {
        let grid = gridDimensions(count: count, in: sharedFrame)

        let gap = min(maximumGap, min(sharedFrame.width, sharedFrame.height) * 0.05)
        let cellWidth = (sharedFrame.width - gap * CGFloat(grid.columns - 1))
            / CGFloat(grid.columns)
        let cellHeight = (sharedFrame.height - gap * CGFloat(grid.rows - 1))
            / CGFloat(grid.rows)

        return (0..<count).map { index in
            let column = index % grid.columns
            let row = index / grid.columns
            return CGRect(
                x: sharedFrame.minX + CGFloat(column) * (cellWidth + gap),
                y: sharedFrame.minY + CGFloat(row) * (cellHeight + gap),
                width: cellWidth,
                height: cellHeight
            )
        }
    }

    private static func gridDimensions(count: Int, in frame: CGRect) -> (columns: Int, rows: Int) {
        if count <= 3 {
            return frame.width >= frame.height ? (count, 1) : (1, count)
        }
        let columns = Int(ceil(sqrt(Double(count))))
        return (columns, Int(ceil(Double(count) / Double(columns))))
    }
}

private extension WALIContentFitPreference {
    var arrangementLabel: String {
        switch self {
        case .fill: "Fill Screen"
        case .fit: "Fit to Screen"
        case .stretch: "Stretch to Fill"
        case .center: "Center"
        }
    }
}
