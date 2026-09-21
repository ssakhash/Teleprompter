import AppKit
import QuartzCore
import SwiftUI

/// Compositor-driven perimeter light. Text layout is never part of the animation.
struct PrompterAura: NSViewRepresentable {
    let active: Bool
    let visible: Bool
    let level: Double
    var suppressMotion = false
    var suppressTransparency = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> AuraView { AuraView() }
    func updateNSView(_ view: AuraView, context: Context) {
        view.update(active: active, visible: visible, level: level,
                    reduceMotion: reduceMotion || suppressMotion, reduceTransparency: reduceTransparency || suppressTransparency)
    }
}

final class AuraView: NSView {
    private let rim = CALayer()
    private let bloom = CALayer()
    private let shadowSource = CALayer()
    private let rimGradient = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let outsideMask = CAShapeLayer()
    private var moving = false
    private var lastTransparency: Bool?
    private var targetEnergy: Float = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Cyan → periwinkle → orchid → coral, with a quiet mint return.
        rimGradient.colors = [NSColor(red: 0.25, green: 0.91, blue: 0.96, alpha: 1),
                              NSColor(red: 0.32, green: 0.48, blue: 1, alpha: 1),
                              NSColor(red: 0.72, green: 0.39, blue: 1, alpha: 1),
                              NSColor(red: 1, green: 0.43, blue: 0.72, alpha: 1),
                              NSColor(red: 1, green: 0.69, blue: 0.45, alpha: 1),
                              NSColor(red: 0.35, green: 0.94, blue: 0.81, alpha: 1),
                              NSColor(red: 0.25, green: 0.91, blue: 0.96, alpha: 1)].map(\.cgColor)
        layer?.addSublayer(bloom)
        bloom.addSublayer(shadowSource)
        layer?.addSublayer(rim)
        rim.addSublayer(rimGradient)
        rimGradient.type = .conic
        rimGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        rimGradient.endPoint = CGPoint(x: 0.5, y: 0)
        rim.mask = rimMask
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.lineWidth = 1.5 * PrompterSizing.scale
        // A real soft shadow, masked outside the bubble, keeps all light off the text.
        shadowSource.backgroundColor = NSColor.black.cgColor
        shadowSource.cornerRadius = PrompterSizing.cornerRadius
        shadowSource.shadowColor = NSColor(red: 0.49, green: 0.47, blue: 1, alpha: 1).cgColor
        shadowSource.shadowOpacity = 1
        shadowSource.shadowRadius = 8 * PrompterSizing.scale
        shadowSource.shadowOffset = .zero
        bloom.mask = outsideMask
        outsideMask.fillRule = .evenOdd
        outsideMask.fillColor = NSColor.white.cgColor
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let inset = 12.75 * PrompterSizing.scale
        let outline = RoundedRectangle(cornerRadius: PrompterSizing.cornerRadius, style: .continuous)
            .path(in: bounds.insetBy(dx: inset, dy: inset)).cgPath
        let side = hypot(bounds.width, bounds.height)
        rim.frame = bounds; bloom.frame = bounds
        rimGradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        rimGradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        rimMask.frame = bounds; rimMask.path = outline
        rimMask.contentsScale = window?.backingScaleFactor ?? 2
        shadowSource.frame = bounds.insetBy(dx: inset, dy: inset)
        shadowSource.shadowPath = RoundedRectangle(cornerRadius: PrompterSizing.cornerRadius, style: .continuous).path(in: shadowSource.bounds).cgPath
        let outside = CGMutablePath()
        outside.addRect(bounds); outside.addPath(outline)
        outsideMask.frame = bounds; outsideMask.path = outside
        CATransaction.commit()
    }

    func update(active: Bool, visible: Bool, level: Double, reduceMotion: Bool, reduceTransparency: Bool) {
        let shouldMove = active && visible && !reduceMotion
        if shouldMove != moving {
            moving = shouldMove
            if shouldMove {
                let orbit = CABasicAnimation(keyPath: "transform.rotation.z")
                orbit.fromValue = 0; orbit.toValue = Double.pi * 2
                orbit.duration = 18; orbit.repeatCount = .infinity
                rimGradient.add(orbit, forKey: "orbit")
            } else { rimGradient.removeAnimation(forKey: "orbit") }
        }
        if shouldMove && !reduceTransparency {
            if shadowSource.animation(forKey: "breath") == nil {
                let breath = CABasicAnimation(keyPath: "shadowOpacity")
                breath.fromValue = 0.65; breath.toValue = 1
                breath.duration = 2.8; breath.autoreverses = true; breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                shadowSource.add(breath, forKey: "breath")
            }
        } else { shadowSource.removeAnimation(forKey: "breath") }
        // Actual microphone energy changes only the light, never the panel's geometry.
        let energy = active && !reduceMotion ? Float(min(1, max(0, level))) : 0
        let target: Float = active ? 0.30 + energy * 0.25 : 0.08
        if abs(targetEnergy - target) > 0.025 || lastTransparency != reduceTransparency {
            lastTransparency = reduceTransparency
            targetEnergy = target
            CATransaction.begin()
            CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.3)
            bloom.opacity = reduceTransparency ? 0 : target
            rim.opacity = active ? 0.82 : 0.36
            CATransaction.commit()
        }
    }

    /// Used only by the opt-in fixture renderer to verify compositor progress.
    var presentationAngle: Double? {
        guard rimGradient.animation(forKey: "orbit") != nil, let live = rimGradient.presentation() else { return nil }
        return atan2(Double(live.transform.m12), Double(live.transform.m11))
    }
}
