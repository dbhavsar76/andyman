import CoreGraphics

/// Keeps keyboard focus visible: when Tab moves focus to a control that's scrolled out of
/// view, the panel scrolls to it. `PanelController` reports where focus went (in content
/// coordinates) and the scroll container works out the offset.
enum FocusScrolling {
    /// Space kept between a focused control and the edge of the visible area; more at the
    /// bottom, which fades out while there's more to scroll to.
    static let margin: CGFloat = 12
    static let bottomMargin: CGFloat = 40

    struct Viewport: Equatable {
        /// `contentOffset.y`, which starts at `-topInset` (content begins below the header).
        var offset: CGFloat = 0
        var topInset: CGFloat = 0
        /// Visible height below the header.
        var height: CGFloat = 0
        var contentHeight: CGFloat = 0

        /// The offset that brings `rect` (content coordinates) into view, or nil if it's
        /// already visible.
        func offsetRevealing(_ rect: CGRect) -> CGFloat? {
            guard height > 0 else { return nil }
            let top = offset + topInset
            let bottom = top + height
            var target: CGFloat
            if rect.minY < top + margin {
                target = rect.minY - margin - topInset
            } else if rect.maxY > bottom - bottomMargin {
                // Tall controls: show their top rather than their bottom.
                target = min(rect.maxY + bottomMargin - height, rect.minY - margin) - topInset
            } else {
                return nil
            }
            let maxOffset = contentHeight - height - topInset
            target = min(max(target, -topInset), max(maxOffset, -topInset))
            return abs(target - offset) < 1 ? nil : target
        }
    }
}
