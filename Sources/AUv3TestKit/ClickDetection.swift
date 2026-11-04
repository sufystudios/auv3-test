/// Measures how sharp a signal's edges are: the second difference between samples,
/// |x[n] - 2x[n-1] + x[n-2]|. A steady tone keeps it low and steady; a value jump
/// (a gain applied in one sample, say) spikes it. One per channel, carried across blocks.
struct EdgeMeter {
    private var older: Float = 0
    private var old: Float = 0

    mutating func measure(_ x: Float) -> Float {
        let edge = abs(x - 2 * old + older)
        older = old
        old = x
        return edge
    }
}

enum ClickDetection {
    /// Given each block's sharpest edge over three equal holds - steady at one value,
    /// jumped to another, jumped back - how much sharper the jumps were than anything
    /// the steady sound did at either value, if enough to call a click; else nil.
    ///
    /// Comparing maxima with maxima is deliberate: a sawtooth's own discontinuities,
    /// or a brighter sound after the jump, raise the steady parts as much as the jump,
    /// so neither counts. Only an edge well beyond the sound's own does.
    static func clickRatio(edges: [Float], holdBlocks: Int, transitionBlocks: Int,
                           threshold: Float = 4, audible: Float = 0.01) -> Float? {
        guard holdBlocks > transitionBlocks, edges.count >= 3 * holdBlocks else { return nil }
        func steady(_ hold: Int) -> Float {
            edges[(hold * holdBlocks + transitionBlocks)..<((hold + 1) * holdBlocks)].max() ?? 0
        }
        func transition(_ hold: Int) -> Float {
            edges[(hold * holdBlocks)..<(hold * holdBlocks + transitionBlocks)].max() ?? 0
        }
        let steadyEdge = max(steady(0), steady(1), steady(2), 1e-4)
        let jumpEdge = max(transition(1), transition(2))
        guard jumpEdge > audible, jumpEdge > threshold * steadyEdge else { return nil }
        return jumpEdge / steadyEdge
    }
}
