import Foundation

/// The nine shapes, each in figure units about its own centre with `y` down. A heavier model draws
/// more of its maker's shape; `tau` is zero and `sway` is zero when the figure holds still, which
/// leaves every shape in the one pose it is known by.
extension WallEmblemShapes.Pen {
    /// Rays around a hollow centre, long and short by turns and none quite the length of its
    /// neighbour: five for the lightest model, sixteen and a halo for the flagship.
    mutating func spark() {
        let rays = [5, 8, 12, 16][rank]
        let tilt = rnd(0, 5) * 2 * .pi / Double(rays)
        for i in 0..<rays {
            let angle =
                2 * .pi * Double(i) / Double(rays) + tilt + 0.16 * (rnd(i, 1) - 0.5)
                + tau * 0.07 * emblem.spin
            let long = i % 2 == 0
            let base = long ? 1.0 : 0.58 + 0.14 * rnd(i, 2)
            let reach = base * (1 - 0.14 * sway * (0.5 + 0.5 * sin(tau * 1.7 + rnd(i, 3) * 2 * .pi)))
            let steps = Int((long ? 7 : 4) * density)
            let start = long ? 0.24 : 0.34
            for j in 0..<steps {
                let f = Double(j) / Double(steps - 1)
                let r = start + (reach - start) * f
                dot(cos(angle) * r, sin(angle) * r, size: 0.092 - 0.03 * f * f, alpha: 1.55 - 0.55 * f)
            }
        }
        if rank == 3 { ring(1.04, width: 0.012, alpha: 0.5) }
    }

    /// Six lobes whose outer arcs overlap into a blossom, turning slowly while a light runs round it.
    mutating func knot() {
        let beads = [5, 6, 7, 8][rank]
        let turn = tau * 0.11 * emblem.spin
        for lobe in 0..<6 {
            let heading = Double(lobe) * .pi / 3 + turn
            let cx = cos(heading) * 0.48
            let cy = sin(heading) * 0.48
            for j in 0..<beads {
                let f = Double(j) / Double(beads - 1)
                let angle = heading + (f - 0.5) * 3.5
                let px = cx + cos(angle) * 0.5
                let py = cy + sin(angle) * 0.5
                let lit = 0.5 + 0.5 * cos(atan2(py, px) - tau * 0.9)
                dot(px, py, size: 0.105, alpha: 0.75 + 0.65 * (sway > 0 ? lit * lit : 0.5))
            }
        }
        if rank >= 2 { ring(0.2, width: 0.014, alpha: 0.55) }
    }

    /// A four-pointed star with its sides drawn in toward the centre, its two axes trading length as
    /// it twinkles, and a smaller companion or two for the heavier models.
    mutating func star() {
        starFigure(at: (0, 0), scale: 1, count: 32 + 8 * rank, phase: 0)
        if rank >= 2 { starFigure(at: (0.66, -0.66), scale: 0.3, count: 12, phase: 1.9) }
        if rank == 3 { starFigure(at: (-0.7, 0.6), scale: 0.2, count: 8, phase: 3.6) }
    }

    private mutating func starFigure(at centre: (Double, Double), scale: Double, count: Int, phase: Double) {
        let twinkle = 0.12 * sway * sin(tau * 1.15 + phase)
        for i in 0..<count {
            let angle = 2 * .pi * Double(i) / Double(count)
            let reach = pow(sqrt(abs(cos(angle))) + sqrt(abs(sin(angle))), -2)
            let tip = WallMath.clamp((reach - 0.25) / 0.75, 0, 1)
            dot(
                centre.0 + cos(angle) * reach * scale * (1 + twinkle),
                centre.1 + sin(angle) * reach * scale * (1 - twinkle),
                size: (0.06 + 0.12 * tip * tip) * max(scale, 0.55), alpha: 0.8 + 0.7 * tip)
        }
    }

    /// A ring broken where one stroke crosses it, a bead of light travelling the stroke.
    mutating func slash() {
        let around = 22 + 4 * rank
        for i in 0..<around {
            let angle = 2 * .pi * Double(i) / Double(around)
            let fromStroke = abs(sin(angle + .pi / 4))
            guard fromStroke > 0.24 else { continue }
            let lit = 0.5 + 0.5 * cos(angle - tau * 0.5 * emblem.spin)
            dot(cos(angle) * 0.74, sin(angle) * 0.74, size: 0.075, alpha: 0.7 + 0.5 * (sway > 0 ? lit : 0.5))
        }
        let along = 11 + 2 * rank
        for i in 0..<along {
            let s = (Double(i) / Double(along - 1) - 0.5) * 2.1
            dot(s * 0.707, -s * 0.707, size: 0.055 + 0.1 * (1 - abs(s) / 1.1), alpha: 1.35)
        }
        guard sway > 0 else { return }
        let travel = tau * 0.3
        let head = (travel - travel.rounded(.down)) * 2.3 - 1.15
        for k in 0..<4 {
            let s = head - Double(k) * 0.09
            guard abs(s) < 1.1 else { continue }
            dot(s * 0.707, -s * 0.707, size: 0.17 - 0.03 * Double(k), alpha: (1.9 - 0.45 * Double(k)) * sway)
        }
    }

    /// One line crossing itself, two lights chasing each other along it.
    mutating func loop() {
        let count = 30 + 6 * rank
        for i in 0..<count {
            let angle = 2 * .pi * Double(i) / Double(count)
            let fold = 1 + sin(angle) * sin(angle)
            let chase = pow(0.5 + 0.5 * cos(2 * (angle - tau * 0.6 * emblem.spin)), 3)
            let lit = sway > 0 ? chase : 0.35
            dot(
                cos(angle) / fold, 1.25 * sin(angle) * cos(angle) / fold, size: 0.07 + 0.075 * lit,
                alpha: 0.7 + 0.9 * lit)
        }
    }

    /// Five rows of blocks stepped like a flag, each row leaning with the gusts that cross it.
    mutating func wind() {
        let columns = 4 + rank
        let pitch = min(0.36, 1.7 / Double(columns))
        for row in 0..<5 {
            let lean = 0.13 * sway * sin(tau * 1.3 + Double(row) * 0.9)
            for column in 0..<columns {
                let ux = (Double(column) - Double(columns - 1) / 2) * pitch + lean
                let uy = (Double(row) - 2) * 0.36
                guard ux * ux + uy * uy < 1.12 else { continue }
                let gust = sway > 0 ? 0.7 + 0.3 * sin(tau * 2.1 - Double(column) * 0.8 + Double(row)) : 0.85
                dot(ux, uy, size: 0.19, alpha: (1.35 - 0.16 * Double(row)) * gust)
            }
        }
    }

    /// Three swells rolling the same way, each a little fainter than the one above it.
    mutating func wave() {
        let across = 11 + 2 * rank
        for row in 0..<3 {
            let base = (Double(row) - 1) * 0.46
            let half = sqrt(max(0, 1 - base * base)) * 0.98
            for i in 0..<across {
                let ux = (Double(i) / Double(across - 1) * 2 - 1) * half
                let swell = sin(ux * 4.2 + tau * 1.4 * emblem.spin + Double(row) * 1.1)
                dot(
                    ux, base + 0.15 * swell, size: 0.115 - 0.018 * Double(row),
                    alpha: 1.35 - 0.3 * Double(row))
            }
        }
    }

    /// Three arms wound about a centre, turning as one.
    mutating func swirl() {
        let beads = 8 + 2 * rank
        for arm in 0..<3 {
            for j in 0..<beads {
                let f = Double(j) / Double(beads - 1)
                let angle = (Double(arm) * 2 * .pi / 3 + 2.5 * f + tau * 0.24) * emblem.spin
                let r = 0.16 + 0.84 * f
                dot(cos(angle) * r, sin(angle) * r, size: 0.16 - 0.095 * f, alpha: 1.5 - 0.85 * f)
            }
        }
    }

    /// A nucleus, a track around it and a satellite for each of the maker's number, every one with a
    /// tail; the heavier models carry a second, outer track turning the other way.
    mutating func orbit() {
        dot(0, 0, size: 0.26, alpha: 1.4)
        track(radius: 0.62, bodies: emblem.satellites, size: 0.15, turn: tau * 0.5 * emblem.spin)
        if rank >= 2 {
            track(radius: 1, bodies: max(2, emblem.satellites - 1), size: 0.1, turn: -tau * 0.28 * emblem.spin + 0.6)
        }
    }

    private mutating func track(radius: Double, bodies: Int, size: Double, turn: Double) {
        ring(radius, width: 0.01, alpha: 0.45)
        for body in 0..<bodies {
            let angle = 2 * .pi * Double(body) / Double(bodies) + turn + rnd(0, 4) * 2 * .pi
            for k in 0..<4 {
                let behind = angle - Double(k) * 0.13 * emblem.spin
                dot(
                    cos(behind) * radius, sin(behind) * radius, size: size * (1 - 0.2 * Double(k)),
                    alpha: 1.6 - 0.42 * Double(k))
            }
        }
    }
}
