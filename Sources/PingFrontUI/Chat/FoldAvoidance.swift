#if canImport(UIKit)
    import SwiftUI

    /// Where the chat goes when a fold divides it (a foldable iPhone, partly folded).
    ///
    /// The chat is one column: the thread, its header and its composer belong together, so when a fold runs
    /// down the middle of the chat the whole column moves into one region instead of the composer and the
    /// bubbles sitting in the curve. A fold across the chat (the device propped like a laptop) leaves the
    /// column where it is: the thread scrolls across it and the composer is already in the lower region.
    ///
    /// Everything here is computed from the space the chat has and the folds the system reports, never
    /// from the device model, orientation or idiom. Without an active fold (closed, open flat, any other
    /// iPhone or iPad, or an app built with an SDK before iOS 27.1) the placement is `.none`.
    nonisolated struct FoldPlacement: Equatable, Sendable {
        /// Room kept clear at the column's leading and trailing edges, in points.
        var leading: CGFloat = 0
        var trailing: CGFloat = 0

        static let none = FoldPlacement()

        /// The placement for a chat `width` points wide with these active division regions (in the chat's
        /// own coordinates, mirrored for right-to-left).
        ///
        /// A fold that runs down the chat moves the column into the region beside it with more usable room
        /// (after the safe area, which on a foldable iPhone is often on one side only); on a tie, the
        /// leading region, the side the system moves its own sheets to. A fold that only clips one edge (a
        /// sheet the system moved beside the fold still overlaps the fold's margin) keeps the column off it.
        static func column(width: CGFloat, safeLeading: CGFloat, safeTrailing: CGFloat, folds: [CGRect]) -> FoldPlacement {
            let start = safeLeading
            let end = width - safeTrailing
            guard let fold = folds.first(where: { $0.height > $0.width && $0.maxX > start && $0.minX < end }) else { return .none }
            let leadingRoom = fold.minX - start
            let trailingRoom = end - fold.maxX
            guard max(leadingRoom, trailingRoom) > 0 else { return .none }
            if leadingRoom >= trailingRoom { return FoldPlacement(leading: 0, trailing: (width - fold.minX).rounded(.up)) }
            return FoldPlacement(leading: fold.maxX.rounded(.up), trailing: 0)
        }
    }

    /// Where the welcome screen breaks when a fold runs across it.
    ///
    /// Propped like a laptop, the upper region is for reading and the lower one is the stable surface for
    /// touch, so the welcome's words stay above the fold and its topic buttons move below it.
    nonisolated struct WelcomeFold: Equatable, Sendable {
        /// Where the upper region ends and the lower one starts, in the welcome's coordinates.
        var top: CGFloat
        var bottom: CGFloat

        /// The first fold that runs across a view `size` (wider than tall and inside the height).
        static func across(size: CGSize, folds: [CGRect]) -> WelcomeFold? {
            guard let fold = folds.first(where: { $0.width > $0.height && $0.minY > 0 && $0.maxY < size.height }) else { return nil }
            return WelcomeFold(top: fold.minY, bottom: fold.maxY)
        }
    }

    nonisolated enum Folds {
        /// The active division regions (folds) that cross the view `proxy` measures, in its coordinates.
        ///
        /// Built with the iOS 27.1 SDK or later and running on iOS 27.1 or later, this asks the system;
        /// otherwise there are none. The SDK check is on SwiftUI's module version because Xcode 27.0 and 27.1
        /// ship the same Swift compiler, and the SDK is built by the app with whichever Xcode it uses.
        static func active(in proxy: GeometryProxy) -> [CGRect] {
            #if canImport(SwiftUI, _version: 8.0.85)
                if #available(iOS 27.1, *) {
                    return proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
                }
            #endif
            return []
        }
    }

    extension View {
        /// Reports the chat column's placement whenever the chat's size or its folds change.
        ///
        /// SwiftUI tracks the reserved regions read here, so folding and unfolding without a size change
        /// still updates the placement.
        func onFoldPlacementChange(_ action: @escaping (FoldPlacement) -> Void) -> some View {
            onGeometryChange(for: FoldPlacement.self) { proxy in
                FoldPlacement.column(
                    width: proxy.size.width, safeLeading: proxy.safeAreaInsets.leading, safeTrailing: proxy.safeAreaInsets.trailing,
                    folds: Folds.active(in: proxy))
            } action: { placement in
                action(placement)
            }
        }

        /// Keeps the chat column clear of a fold that runs down the middle of the chat.
        func foldPlacement(_ placement: FoldPlacement) -> some View {
            padding(.leading, placement.leading).padding(.trailing, placement.trailing)
        }
    }
#endif
