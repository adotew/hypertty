import AppKit
import GhosttyKit

enum SplitAxis {
    /// Side by side, divider is vertical.
    case horizontal
    /// Stacked, divider is horizontal.
    case vertical
}

/// An immutable tree of terminals. Behavior (navigation, resizing,
/// equalizing) mirrors Ghostty's macOS SplitTree so the same keybinds do
/// the same thing.
indirect enum SplitNode {
    case leaf(TerminalView)
    /// `ratio` is the share of the first (left/top) child.
    case split(SplitAxis, ratio: CGFloat, SplitNode, SplitNode)

    var leaves: [TerminalView] {
        switch self {
        case .leaf(let terminal): [terminal]
        case .split(_, _, let first, let second): first.leaves + second.leaves
        }
    }

    func contains(_ terminal: TerminalView) -> Bool {
        leaves.contains { $0 === terminal }
    }

    /// Splits `target`, placing `terminal` on the given side of it.
    func inserting(_ terminal: TerminalView, at target: TerminalView,
                   direction: ghostty_action_split_direction_e) -> SplitNode {
        switch self {
        case .leaf(let existing) where existing === target:
            switch direction {
            case GHOSTTY_SPLIT_DIRECTION_LEFT: return .split(.horizontal, ratio: 0.5, .leaf(terminal), self)
            case GHOSTTY_SPLIT_DIRECTION_UP: return .split(.vertical, ratio: 0.5, .leaf(terminal), self)
            case GHOSTTY_SPLIT_DIRECTION_DOWN: return .split(.vertical, ratio: 0.5, self, .leaf(terminal))
            default: return .split(.horizontal, ratio: 0.5, self, .leaf(terminal))
            }
        case .leaf:
            return self
        case .split(let axis, let ratio, let first, let second):
            return .split(axis, ratio: ratio,
                          first.inserting(terminal, at: target, direction: direction),
                          second.inserting(terminal, at: target, direction: direction))
        }
    }

    /// Removes `terminal`; its sibling takes the parent's place. Nil if
    /// nothing is left.
    func removing(_ terminal: TerminalView) -> SplitNode? {
        switch self {
        case .leaf(let existing):
            return existing === terminal ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard let newFirst = first.removing(terminal) else { return second }
            guard let newSecond = second.removing(terminal) else { return first }
            return .split(axis, ratio: ratio, newFirst, newSecond)
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
    func resizing(_ terminal: TerminalView, direction: ghostty_action_resize_split_direction_e,
                  amount: CGFloat, in size: CGSize) -> SplitNode {
        let axis: SplitAxis
        let delta: CGFloat
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_LEFT: (axis, delta) = (.horizontal, -amount)
        case GHOSTTY_RESIZE_SPLIT_RIGHT: (axis, delta) = (.horizontal, amount)
        case GHOSTTY_RESIZE_SPLIT_UP: (axis, delta) = (.vertical, -amount)
        default: (axis, delta) = (.vertical, amount)
        }
        return resizing(terminal, axis: axis, delta: delta, in: size).node
    }

    private func resizing(_ terminal: TerminalView, axis: SplitAxis, delta: CGFloat,
                          in size: CGSize) -> (node: SplitNode, done: Bool) {
        guard case .split(let splitAxis, let ratio, let first, let second) = self else { return (self, false) }
        let (firstRect, secondRect) = Self.divide(CGRect(origin: .zero, size: size), splitAxis, ratio)

        // Deepest matching ancestor first.
        if first.contains(terminal) {
            let (node, done) = first.resizing(terminal, axis: axis, delta: delta, in: firstRect.size)
            if done { return (.split(splitAxis, ratio: ratio, node, second), true) }
        } else if second.contains(terminal) {
            let (node, done) = second.resizing(terminal, axis: axis, delta: delta, in: secondRect.size)
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
    func frames(in rect: CGRect) -> [(terminal: TerminalView, frame: CGRect)] {
        switch self {
        case .leaf(let terminal):
            return [(terminal, rect)]
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
    func target(from terminal: TerminalView, _ direction: ghostty_action_goto_split_e) -> TerminalView? {
        let leaves = self.leaves
        guard leaves.count > 1, let index = leaves.firstIndex(where: { $0 === terminal }) else { return nil }

        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS:
            return leaves[(index - 1 + leaves.count) % leaves.count]
        case GHOSTTY_GOTO_SPLIT_NEXT:
            return leaves[(index + 1) % leaves.count]
        default:
            break
        }

        let slots = frames(in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        guard let current = slots.first(where: { $0.terminal === terminal })?.frame else { return nil }
        let epsilon: CGFloat = 0.001
        let candidates = slots.filter { slot in
            guard slot.terminal !== terminal else { return false }
            switch direction {
            case GHOSTTY_GOTO_SPLIT_LEFT: return slot.frame.maxX <= current.minX + epsilon
            case GHOSTTY_GOTO_SPLIT_RIGHT: return slot.frame.minX >= current.maxX - epsilon
            case GHOSTTY_GOTO_SPLIT_UP: return slot.frame.maxY <= current.minY + epsilon
            default: return slot.frame.minY >= current.maxY - epsilon
            }
        }
        return candidates.min { a, b in
            hypot(a.frame.minX - current.minX, a.frame.minY - current.minY)
                < hypot(b.frame.minX - current.minX, b.frame.minY - current.minY)
        }?.terminal
    }
}
