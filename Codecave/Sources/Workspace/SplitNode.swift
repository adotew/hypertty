import AppKit
import GhosttyKit

enum SplitAxis {
    /// Side by side, divider is vertical.
    case horizontal
    /// Stacked, divider is horizontal.
    case vertical
}

/// An immutable tree of panes. Behavior (navigation, resizing,
/// equalizing) mirrors Ghostty's macOS SplitTree so the same keybinds do
/// the same thing.
indirect enum SplitNode {
    case leaf(any Pane)
    /// `ratio` is the share of the first (left/top) child.
    case split(SplitAxis, ratio: CGFloat, SplitNode, SplitNode)

    var leaves: [any Pane] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(_, _, let first, let second): first.leaves + second.leaves
        }
    }

    func contains(_ pane: any Pane) -> Bool {
        leaves.contains { $0 === pane }
    }

    /// Splits `target`, placing `pane` on the given side of it.
    func inserting(_ pane: any Pane, at target: any Pane,
                   direction: ghostty_action_split_direction_e) -> SplitNode {
        switch self {
        case .leaf(let existing) where existing === target:
            switch direction {
            case GHOSTTY_SPLIT_DIRECTION_LEFT: return .split(.horizontal, ratio: 0.5, .leaf(pane), self)
            case GHOSTTY_SPLIT_DIRECTION_UP: return .split(.vertical, ratio: 0.5, .leaf(pane), self)
            case GHOSTTY_SPLIT_DIRECTION_DOWN: return .split(.vertical, ratio: 0.5, self, .leaf(pane))
            default: return .split(.horizontal, ratio: 0.5, self, .leaf(pane))
            }
        case .leaf:
            return self
        case .split(let axis, let ratio, let first, let second):
            return .split(axis, ratio: ratio,
                          first.inserting(pane, at: target, direction: direction),
                          second.inserting(pane, at: target, direction: direction))
        }
    }

    /// Removes `pane`; its sibling takes the parent's place. Nil if
    /// nothing is left.
    func removing(_ pane: any Pane) -> SplitNode? {
        switch self {
        case .leaf(let existing):
            return existing === pane ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard let newFirst = first.removing(pane) else { return second }
            guard let newSecond = second.removing(pane) else { return first }
            return .split(axis, ratio: ratio, newFirst, newSecond)
        }
    }

    func replacing(_ old: any Pane, with pane: any Pane) -> SplitNode {
        switch self {
        case .leaf(let existing):
            existing === old ? .leaf(pane) : self
        case .split(let axis, let ratio, let first, let second):
            .split(axis, ratio: ratio, first.replacing(old, with: pane), second.replacing(old, with: pane))
        }
    }

    /// Sets the ratio of the split at `path` (false = first child, true = second).
    func setting(ratio newRatio: CGFloat, at path: ArraySlice<Bool>) -> SplitNode {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        guard let step = path.first else { return .split(axis, ratio: newRatio, first, second) }
        let rest = path.dropFirst()
        return step
            ? .split(axis, ratio: ratio, first, second.setting(ratio: newRatio, at: rest))
            : .split(axis, ratio: ratio, first.setting(ratio: newRatio, at: rest), second)
    }

    // MARK: Equalize

    /// Ratios proportional to the number of panes along each split's axis.
    func equalized() -> SplitNode {
        guard case .split(let axis, _, let first, let second) = self else { return self }
        let firstWeight = first.weight(along: axis)
        let secondWeight = second.weight(along: axis)
        return .split(axis, ratio: CGFloat(firstWeight) / CGFloat(firstWeight + secondWeight),
                      first.equalized(), second.equalized())
    }

    private func weight(along axis: SplitAxis) -> Int {
        guard case .split(let splitAxis, _, let first, let second) = self, splitAxis == axis else { return 1 }
        return first.weight(along: axis) + second.weight(along: axis)
    }

    // MARK: Resize

    /// Moves the divider of the nearest enclosing split along the resize
    /// direction by `amount` points.
    func resizing(_ pane: any Pane, direction: ghostty_action_resize_split_direction_e,
                  amount: CGFloat, in size: CGSize) -> SplitNode {
        let axis: SplitAxis
        let delta: CGFloat
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_LEFT: (axis, delta) = (.horizontal, -amount)
        case GHOSTTY_RESIZE_SPLIT_RIGHT: (axis, delta) = (.horizontal, amount)
        case GHOSTTY_RESIZE_SPLIT_UP: (axis, delta) = (.vertical, -amount)
        default: (axis, delta) = (.vertical, amount)
        }
        return resizing(pane, axis: axis, delta: delta, in: size).node
    }

    private func resizing(_ pane: any Pane, axis: SplitAxis, delta: CGFloat,
                          in size: CGSize) -> (node: SplitNode, done: Bool) {
        guard case .split(let splitAxis, let ratio, let first, let second) = self else { return (self, false) }
        let (firstRect, secondRect) = Self.divide(CGRect(origin: .zero, size: size), splitAxis, ratio)

        // Deepest matching ancestor first.
        if first.contains(pane) {
            let (node, done) = first.resizing(pane, axis: axis, delta: delta, in: firstRect.size)
            if done { return (.split(splitAxis, ratio: ratio, node, second), true) }
        } else if second.contains(pane) {
            let (node, done) = second.resizing(pane, axis: axis, delta: delta, in: secondRect.size)
            if done { return (.split(splitAxis, ratio: ratio, first, node), true) }
        } else {
            return (self, false)
        }

        guard splitAxis == axis else { return (self, false) }
        let length = axis == .horizontal ? size.width : size.height
        guard length > 0 else { return (self, false) }
        let newRatio = min(0.9, max(0.1, ratio + delta / length))
        return (.split(splitAxis, ratio: newRatio, first, second), true)
    }

    // MARK: Geometry and navigation

    /// Pane frames in a top-left-origin coordinate space.
    func frames(in rect: CGRect) -> [(pane: any Pane, frame: CGRect)] {
        switch self {
        case .leaf(let pane):
            return [(pane, rect)]
        case .split(let axis, let ratio, let first, let second):
            let (firstRect, secondRect) = Self.divide(rect, axis, ratio)
            return first.frames(in: firstRect) + second.frames(in: secondRect)
        }
    }

    static func divide(_ rect: CGRect, _ axis: SplitAxis, _ ratio: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let width = rect.width * ratio
            return (CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
        case .vertical:
            let height = rect.height * ratio
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
                    CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
        }
    }

    /// The pane `goto_split` moves to: previous/next wrap in tree order;
    /// directions pick the closest pane (by top-left corner) on that side.
    func target(from pane: any Pane, _ direction: ghostty_action_goto_split_e) -> (any Pane)? {
        let leaves = self.leaves
        guard leaves.count > 1, let index = leaves.firstIndex(where: { $0 === pane }) else { return nil }

        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS:
            return leaves[(index - 1 + leaves.count) % leaves.count]
        case GHOSTTY_GOTO_SPLIT_NEXT:
            return leaves[(index + 1) % leaves.count]
        default:
            break
        }

        let slots = frames(in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        guard let current = slots.first(where: { $0.pane === pane })?.frame else { return nil }
        let epsilon: CGFloat = 0.001
        let candidates = slots.filter { slot in
            guard slot.pane !== pane else { return false }
            switch direction {
            case GHOSTTY_GOTO_SPLIT_LEFT: return slot.frame.maxX <= current.minX + epsilon
            case GHOSTTY_GOTO_SPLIT_RIGHT: return slot.frame.minX >= current.maxX - epsilon
            case GHOSTTY_GOTO_SPLIT_UP: return slot.frame.maxY <= current.minY + epsilon
            default: return slot.frame.minY >= current.maxY - epsilon
            }
        }
        func distance(_ slot: (pane: any Pane, frame: CGRect)) -> CGFloat {
            hypot(slot.frame.minX - current.minX, slot.frame.minY - current.minY)
        }
        return candidates.min { distance($0) < distance($1) }?.pane
    }
}
