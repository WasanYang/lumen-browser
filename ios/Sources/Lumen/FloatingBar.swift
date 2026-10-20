import UIKit

/// Safari-style bottom bar: one rounded capsule with back, the site name and a ⋯ menu button (which
/// carries the green "new uBO" dot). Scrolling the page down shrinks it to the site name alone;
/// scrolling up, reaching the top or tapping it brings it back.
final class FloatingBar: UIView {
    let backButton = UIButton(type: .system)
    let titleLabel = UILabel()
    let moreButton = UIButton(type: .system)
    let dot = UIView()
    private(set) var isCollapsed = false

    private let capsule: UIVisualEffectView
    private var heightConstraint: NSLayoutConstraint!
    private var expandedWidth: [NSLayoutConstraint] = []
    private var collapsedWidth: NSLayoutConstraint!

    init() {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect()
        } else {
            effect = UIBlurEffect(style: .systemThickMaterialDark)
        }
        capsule = UIVisualEffectView(effect: effect)
        super.init(frame: .zero)
        backgroundColor = .black

        capsule.clipsToBounds = true
        capsule.layer.cornerCurve = .continuous
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addSubview(capsule)

        backButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
        moreButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.preferredMenuElementOrder = .fixed
        for button in [backButton, moreButton] {
            button.tintColor = .label
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        }
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingMiddle

        dot.backgroundColor = .systemGreen
        dot.layer.cornerRadius = 4
        dot.isUserInteractionEnabled = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        moreButton.addSubview(dot)

        let row = UIStackView(arrangedSubviews: [backButton, titleLabel, moreButton])
        row.alignment = .center
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(row)

        heightConstraint = capsule.heightAnchor.constraint(equalToConstant: 48)
        // Expanded: the width of the screen less a margin, but not wider than 560 pt (iPad).
        let preferred = capsule.widthAnchor.constraint(equalToConstant: 560)
        preferred.priority = .defaultHigh
        expandedWidth = [capsule.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24), preferred]
        collapsedWidth = capsule.widthAnchor.constraint(equalToConstant: 170)
        NSLayoutConstraint.activate(expandedWidth + [
            heightConstraint,
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            capsule.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.topAnchor.constraint(equalTo: moreButton.topAnchor, constant: 8),
            dot.trailingAnchor.constraint(equalTo: moreButton.trailingAnchor, constant: -4),
        ])
        apply(collapsed: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.apply(collapsed: collapsed)
            self.superview?.layoutIfNeeded()
        }
    }

    private func apply(collapsed: Bool) {
        backButton.isHidden = collapsed
        moreButton.isHidden = collapsed
        heightConstraint.constant = collapsed ? 30 : 48
        capsule.layer.cornerRadius = collapsed ? 15 : 24
        titleLabel.font = .systemFont(ofSize: collapsed ? 13 : 16, weight: collapsed ? .regular : .medium)
        NSLayoutConstraint.deactivate(collapsed ? expandedWidth : [collapsedWidth])
        NSLayoutConstraint.activate(collapsed ? [collapsedWidth] : expandedWidth)
    }

    @objc private func tapped() {
        if isCollapsed { setCollapsed(false) }
    }
}
