import SwiftUI
import UIKit

struct CoreAnimationSpinnerBorder: UIViewRepresentable {
    let color: UIColor
    let isSpinning: Bool

    func makeUIView(context _: Context) -> UICapsuleSpinnerView {
        let view = UICapsuleSpinnerView()
        view.updateColor(color)
        return view
    }

    func updateUIView(_ uiView: UICapsuleSpinnerView, context _: Context) {
        uiView.updateColor(color)
        uiView.setSpinning(isSpinning)
    }
}

final class UICapsuleSpinnerView: UIView {
    private let shapeLayer = CAShapeLayer()
    private var isSpinning: Bool = false
    private let lineWidth: CGFloat = 2.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        shapeLayer.lineWidth = lineWidth
        shapeLayer.lineCap = .round
        shapeLayer.fillColor = UIColor.clear.cgColor
        layer.addSublayer(shapeLayer)
    }

    func updateColor(_ color: UIColor) {
        shapeLayer.strokeColor = color.withAlphaComponent(0.4).cgColor
    }

    func setSpinning(_ spinning: Bool) {
        guard isSpinning != spinning else { return }
        isSpinning = spinning

        if spinning {
            startSpinning()
        } else {
            stopSpinning()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds

        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = min(rect.width, rect.height) / 2
        shapeLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath

        // Perimeter calculation for a capsule shape
        let perimeter = 2 * (rect.width - 2 * radius) + 2 * (rect.height - 2 * radius) + 2 * .pi * radius
        shapeLayer.lineDashPattern = [(perimeter * 0.7) as NSNumber, (perimeter * 0.3) as NSNumber]

        // If it was already spinning, refresh the animation to match new dimensions
        if isSpinning {
            startSpinning()
        }
    }

    private func startSpinning() {
        shapeLayer.removeAnimation(forKey: "spin")

        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = min(rect.width, rect.height) / 2
        let perimeter = 2 * (rect.width - 2 * radius) + 2 * (rect.height - 2 * radius) + 2 * .pi * radius

        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = perimeter
        animation.duration = 1.333
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)

        shapeLayer.add(animation, forKey: "spin")
    }

    private func stopSpinning() {
        shapeLayer.removeAnimation(forKey: "spin")
    }
}
