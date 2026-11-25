//
//  LCAppBannerView.swift
//  LiveContainerSwiftUI
//

import Foundation
import UIKit

final class LCAppBannerRootView: UIView {
    static let bannerHeight: CGFloat = 88

    let runControl = LCAppBannerRunControl()

    // 面板同款次级按钮（主列表卡片加“最小化”“小窗口”）：
    // 只在 iOS 16+ 建——多任务窗口是 16+ 的东西，16 以下
    // 卡片与原来一字不差；控制器里同样只认 16+。
    var minimizeControl: UIButton?
    var smallWindowControl: UIButton?

    private let visualBackgroundView = UIView()
    private let iconImageView = UIImageView()
    private let nameLabel = UILabel()
    private let versionLabel = UILabel()
    // F1（3.8.635）：签名剩余天数角标——版本行旁的第二段文字。
    private let expiryLabel = UILabel()
    // A3（3.8.637）：上次启动相对时间——版本行旁的小字；
    // lastLaunched 已持久化（LCAppInfo.m 写 _info + save），
    // “最近启动”排序已在用，行上从不显示。RelativeDateTimeFormatter
    // 是 iOS 13+ API，部署目标 iOS 15，不用 #available。
    private let lastLaunchedLabel = UILabel()
    // F3（3.8.635）：运行中绿点——runControl 右上角。
    private let runningDot = UIView()
    private let remarkLabel = UILabel()
    private let containerLabel = UILabel()
    private let sharedBadge = LCAppBannerBadgeView(symbolName: "arrowshape.turn.up.left.fill")
    private let jitBadge = LCAppBannerBadgeView(symbolName: "bolt.fill")
    private let lockBadge = LCAppBannerBadgeView(symbolName: "lock.fill")
    private let bit32Badge = LCAppBannerBadgeView(text: "32")
    private let nameSpacer = UIView()
    private let nameStack = UIStackView()
    // F1（3.8.635）：版本行——版本 + 剩余天数并排。
    private let versionStack = UIStackView()
    private let detailStack = UIStackView()

    // O-13：最近一次 update 的图标归属键（bundlePath+明暗）；
    // 后台生成回来时对不上就不刷新（视图复用到别的 App 时）。
    private var czfIconKey: String?

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.bannerHeight)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        isOpaque = false
        backgroundColor = .clear
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        clipsToBounds = true

        visualBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        visualBackgroundView.isOpaque = false
        visualBackgroundView.isUserInteractionEnabled = false

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.layer.cornerRadius = 16
        iconImageView.layer.cornerCurve = .continuous
        iconImageView.clipsToBounds = true
        iconImageView.isAccessibilityElement = false

        configureLabel(nameLabel, font: .systemFont(ofSize: 16, weight: .bold))
        configureLabel(versionLabel, font: .systemFont(ofSize: 12))
        configureLabel(expiryLabel, font: .systemFont(ofSize: 12))
        configureLabel(lastLaunchedLabel, font: .systemFont(ofSize: 12))
        configureLabel(remarkLabel, font: .systemFont(ofSize: 10))
        configureLabel(containerLabel, font: .systemFont(ofSize: 8))

        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameStack.translatesAutoresizingMaskIntoConstraints = false
        nameStack.axis = .horizontal
        nameStack.alignment = .center
        nameStack.spacing = 8
        nameStack.addArrangedSubview(nameLabel)
        nameStack.addArrangedSubview(sharedBadge)
        nameStack.addArrangedSubview(jitBadge)
        nameStack.addArrangedSubview(bit32Badge)
        nameStack.addArrangedSubview(lockBadge)
        nameStack.addArrangedSubview(nameSpacer)

        // F1（3.8.635）：版本行——版本 + 剩余天数并排；版本先截断，
        // 角标不被挤掉（expiryLabel 横向抗压 required）。
        versionStack.translatesAutoresizingMaskIntoConstraints = false
        versionStack.axis = .horizontal
        versionStack.alignment = .center
        versionStack.spacing = 6
        versionStack.addArrangedSubview(versionLabel)
        versionStack.addArrangedSubview(expiryLabel)
        versionStack.addArrangedSubview(lastLaunchedLabel)
        versionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        versionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        expiryLabel.setContentHuggingPriority(.required, for: .horizontal)
        expiryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        lastLaunchedLabel.setContentHuggingPriority(.required, for: .horizontal)
        lastLaunchedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.axis = .vertical
        detailStack.alignment = .fill
        detailStack.distribution = .fill
        detailStack.spacing = 1
        detailStack.addArrangedSubview(nameStack)
        detailStack.addArrangedSubview(versionStack)
        detailStack.addArrangedSubview(remarkLabel)
        detailStack.addArrangedSubview(containerLabel)
        detailStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailStack.isAccessibilityElement = true

        // F3（3.8.635）：运行中绿点——runControl 右上角 12pt；
        // 不接手势，点按落在下面的 runControl 上（本来就先带回
        // 已有窗口）。白圈描边在 update 里按当前 trait 取色。
        runningDot.translatesAutoresizingMaskIntoConstraints = false
        runningDot.backgroundColor = .systemGreen
        runningDot.layer.cornerRadius = 6
        runningDot.layer.borderWidth = 2
        runningDot.isHidden = true
        runningDot.isUserInteractionEnabled = false

        runControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualBackgroundView)
        addSubview(iconImageView)
        addSubview(detailStack)
        addSubview(runControl)
        addSubview(runningDot)

        // 面板胶囊同款次级按钮：只在 16+ 建，16 以下不进层级、
        // 不占布局，卡片与原来完全一致。
        if #available(iOS 16.0, *) {
            let minimizeButton = makeAuxButton(title: "最小化")
            let smallWindowButton = makeAuxButton(title: "小窗口")
            minimizeControl = minimizeButton
            smallWindowControl = smallWindowButton
            addSubview(minimizeButton)
            addSubview(smallWindowButton)
        }

        NSLayoutConstraint.activate([
            visualBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            visualBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 60),
            iconImageView.heightAnchor.constraint(equalToConstant: 60),

            detailStack.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 10),
            detailStack.trailingAnchor.constraint(lessThanOrEqualTo: runControl.leadingAnchor, constant: -10),
            detailStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            runControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            runControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            runControl.widthAnchor.constraint(equalToConstant: 70),
            runControl.heightAnchor.constraint(equalToConstant: 32)
        ])

        NSLayoutConstraint.activate([
            runningDot.widthAnchor.constraint(equalToConstant: 12),
            runningDot.heightAnchor.constraint(equalToConstant: 12),
            runningDot.trailingAnchor.constraint(equalTo: runControl.trailingAnchor, constant: 2),
            runningDot.topAnchor.constraint(equalTo: runControl.topAnchor, constant: -2),
        ])

        // 次级按钮链：名字列先让（detailStack 横向抗压本来就是
        // defaultLow），名字过长时先截名字，不断按钮；原来
        // detailStack 直连 runControl 的 ≤ 约束留着，与这条链
        // 不冲突（链更紧，先生效）。
        if #available(iOS 16.0, *),
           let minimizeButton = minimizeControl,
           let smallWindowButton = smallWindowControl {
            NSLayoutConstraint.activate([
                minimizeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                smallWindowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                minimizeButton.heightAnchor.constraint(equalToConstant: 32),
                smallWindowButton.heightAnchor.constraint(equalToConstant: 32),
                detailStack.trailingAnchor.constraint(lessThanOrEqualTo: minimizeButton.leadingAnchor, constant: -8),
                minimizeButton.trailingAnchor.constraint(equalTo: smallWindowButton.leadingAnchor, constant: -8),
                smallWindowButton.trailingAnchor.constraint(equalTo: runControl.leadingAnchor, constant: -8),
            ])
        }
    }

    // 面板灰胶囊同款：中性灰底、footnote 字、32 高胶囊，
    // 宽度按文字自适应（Configuration，不用已废弃的 contentEdgeInsets）。
    private func makeAuxButton(title: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .systemGray5
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13)
            return outgoing
        }
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func configureLabel(_ label: UILabel, font: UIFont) {
        label.font = font
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = false
    }

    // F3（3.8.635）：坞表真值。MultitaskDockManager 是 16+ 类型，
    // 见 LCAppModel.czfIsRunningInDock 注释；16 以下无多任务、无角标。
    private func czfIsRunning(model: LCAppModel) -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        return LCAppModel.czfIsRunningInDock(app: model)
    }

    func update(
        model: LCAppModel,
        appInfo: LCAppInfo,
        dynamicColors: Bool,
        darkModeIcon: Bool,
        traitCollection: UITraitCollection,
        // F1（3.8.635）：签名剩余天数（nil = 没读到，不显示）。
        expiryDaysLeft: Int? = nil
    ) {
        // O-13：update 只同步读内存/磁盘缓存（快路径）；未命中
        // 才后台生成，生成完重跑一次 update（此时内存缓存已
        // 就绪，走快路径、不再触发后台，不循环）。动态取色用
        // 占位空图时会先算出 .clear，图标回来重跑即修正。
        let iconKey = appInfo.bundlePath() + (darkModeIcon ? "|dark" : "|light")
        czfIconKey = iconKey
        let cachedIcon = CZFAppIconLoader.cachedIconOnly(for: appInfo, darkModeIcon: darkModeIcon)
        let icon = cachedIcon ?? UIImage()
        if cachedIcon == nil {
            CZFAppIconLoader.loadIconAsync(for: appInfo, darkModeIcon: darkModeIcon) { [weak self] _ in
                guard let self, self.czfIconKey == iconKey else { return }
                // 3.8.645（B2）：图标异步回填的重跑必须带上天数——
                // 原来没传 expiryDaysLeft（参数默认 nil），重跑后
                // 走 expiryLabel.isHidden = true，列表模式里图标
                // 一加载完“剩 X 天”角标就消失，直到下拉刷新才回来。
                self.update(model: model, appInfo: appInfo, dynamicColors: dynamicColors, darkModeIcon: darkModeIcon, traitCollection: traitCollection, expiryDaysLeft: expiryDaysLeft)
            }
        }
        // 无用计算：动态取色关着时 mainColor 根本不用（下面两处都走
        // 非动态分支），还白算一次；关着就不算
        let mainColor = dynamicColors ? Self.extractMainHueColor(appInfo: appInfo, icon: icon, darkModeIcon: darkModeIcon) : .clear
        let accentColor = dynamicColors ? mainColor : (UIColor(named: "FontColor") ?? .systemBlue)
        let textColor = Self.readableTextColor(for: accentColor, traitCollection: traitCollection)

        iconImageView.image = icon
        nameLabel.text = model.displayName
        nameLabel.textColor = .label
        // 简约：版本行只留版本（包名收进详情），容器行隐藏
        // （容器在 App 设置里看和改）；备注是用户自己写的内容，保留
        versionLabel.text = "\(model.version)"
        versionLabel.textColor = textColor
        // F1（3.8.635）：签名剩余天数角标——版本行旁；读不到
        // （无 mobileprovision / 未读到）不显示；≤7 天或已过期变红。
        // 文案走 CZFSignatureExpiry.label 同一份。
        if let daysLeft = expiryDaysLeft {
            expiryLabel.text = CZFSignatureExpiry.label(forDaysLeft: daysLeft)
            expiryLabel.textColor = daysLeft <= 7 ? .systemRed : textColor.withAlphaComponent(0.8)
            expiryLabel.isHidden = false
        } else {
            expiryLabel.isHidden = true
        }
        // A3（3.8.637）：上次启动相对时间——没启动过（lastLaunched
        // 为 nil）不显示；RelativeDateTimeFormatter 按系统语言出
        // “2小时前”这类相对文案，0 新 key。update 每次刷新都重算，
        // 文案随时间变旧不会一直停在首次算的值。
        if let lastLaunched = appInfo.lastLaunched {
            lastLaunchedLabel.text = Self.czfRelativeFormatter.localizedString(for: lastLaunched, relativeTo: Date())
            lastLaunchedLabel.textColor = textColor.withAlphaComponent(0.8)
            lastLaunchedLabel.isHidden = false
        } else {
            lastLaunchedLabel.isHidden = true
        }
        // F3（3.8.635）：运行中绿点——runControl 右上角；
        // VC 已订阅坞表 $apps，窗口开关即 refreshView，点 ▶
        // 本来就先带回已有窗口（见下面 runControl.update 注释）。
        // 白圈描边按当前深浅取色（CGColor 是快照，深浅切换时重取）。
        runningDot.layer.borderColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
        runningDot.isHidden = !czfIsRunning(model: model)
        remarkLabel.text = model.uiRemark
        remarkLabel.textColor = textColor.withAlphaComponent(0.8)
        remarkLabel.isHidden = model.uiRemark.isEmpty
        containerLabel.text = model.uiSelectedContainer?.name ?? "lc.appBanner.noDataFolder".loc
        containerLabel.textColor = textColor
        containerLabel.isHidden = true

        // 角标统一中性灰（原来橙/紫/蓝糖果色太花，跟面板胶囊同一思路，
        // 只留文字区分）；是否显示的逻辑不动
        sharedBadge.isHidden = !model.uiIsShared
        sharedBadge.backgroundColor = .systemGray
        jitBadge.isHidden = !model.uiIsJITNeeded || model.uiIs32bit
        jitBadge.backgroundColor = .systemGray
        lockBadge.isHidden = !model.uiIsLocked || model.uiIsHidden
        lockBadge.backgroundColor = .systemGray
        bit32Badge.isHidden = !model.uiIs32bit
        bit32Badge.backgroundColor = .systemGray

        visualBackgroundView.backgroundColor = dynamicColors
            ? mainColor.withAlphaComponent(0.5)
            : (UIColor(named: "AppBannerBG") ?? .secondarySystemBackground)
        runControl.update(
            color: accentColor,
            isSigning: model.isSigningInProgress,
            progress: model.signProgress,
            // 运行中也不禁用：点 ▶ 走控制器 runButtonTapped 先带回
            // 已有窗口（最小化会经带回路径恢复），带回失败才走
            // runApp，而 runApp 在运行中直接 return，不会多起窗口。
            isEnabled: true
        )

        var accessibilityParts = [model.displayName, "\(model.version) - \(model.bundleIdentifier)"]
        if !model.uiRemark.isEmpty {
            accessibilityParts.append(model.uiRemark)
        }
        if let lastLaunched = appInfo.lastLaunched {
            accessibilityParts.append(Self.czfRelativeFormatter.localizedString(for: lastLaunched, relativeTo: Date()))
        }
        accessibilityParts.append(model.uiSelectedContainer?.name ?? "lc.appBanner.noDataFolder".loc)
        detailStack.accessibilityLabel = accessibilityParts.joined(separator: ", ")
    }

    // A3（3.8.637）：相对时间 formatter——静态复用，
    // RelativeDateTimeFormatter 创建不便宜；abbreviated 样式
    // 在中文下出“2小时前”这类短文案。
    private static let czfRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func extractMainHueColor(appInfo: LCAppInfo, icon: UIImage, darkModeIcon: Bool) -> UIColor {
        if darkModeIcon, let cachedColor = appInfo.cachedColorDark {
            return cachedColor
        }
        if !darkModeIcon, let cachedColor = appInfo.cachedColor {
            return cachedColor
        }

        guard let cgImage = icon.cgImage else {
            return .clear
        }

        var pixelData = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixelData,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .clear
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let averageColor = UIColor(
            red: CGFloat(pixelData[0]) / 255,
            green: CGFloat(pixelData[1]) / 255,
            blue: CGFloat(pixelData[2]) / 255,
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        averageColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let color: UIColor
        if brightness < 0.1 && saturation < 0.1 {
            color = .systemRed
        } else {
            color = UIColor(hue: hue, saturation: saturation, brightness: max(brightness, 0.3), alpha: 1)
        }

        if darkModeIcon {
            appInfo.cachedColorDark = color
        } else {
            appInfo.cachedColor = color
        }
        return color
    }

    private static func readableTextColor(for color: UIColor, traitCollection: UITraitCollection) -> UIColor {
        let resolvedColor = color.resolvedColor(with: traitCollection)
        let systemBackground = UIColor.systemBackground.resolvedColor(with: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var backgroundRed: CGFloat = 0
        var backgroundGreen: CGFloat = 0
        var backgroundBlue: CGFloat = 0
        var backgroundAlpha: CGFloat = 0
        resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        systemBackground.getRed(
            &backgroundRed,
            green: &backgroundGreen,
            blue: &backgroundBlue,
            alpha: &backgroundAlpha
        )

        red = 0.5 * red + 0.5 * backgroundRed
        green = 0.5 * green + 0.5 * backgroundGreen
        blue = 0.5 * blue + 0.5 * backgroundBlue
        let brightness = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let offset: CGFloat = brightness < 0.5 ? 0.4 : -0.4
        return UIColor(
            red: min(max(red + offset, 0), 1),
            green: min(max(green + offset, 0), 1),
            blue: min(max(blue + offset, 0), 1),
            alpha: 1
        )
    }
}

private final class LCAppBannerBadgeView: UIView {
    private let contentView: UIView

    convenience init(symbolName: String) {
        let imageView = UIImageView(image: UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 8)
        ))
        imageView.tintColor = .white
        imageView.contentMode = .center
        self.init(contentView: imageView)
    }

    convenience init(text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 8)
        label.textAlignment = .center
        self.init(contentView: label)
    }

    private init(contentView: UIView) {
        self.contentView = contentView
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 8
        clipsToBounds = true
        isAccessibilityElement = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 16),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

final class LCAppBannerRunControl: UIControl {
    private let baseLayer = CALayer()
    private let progressCircleLayer = CALayer()
    private let titleLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var progress = 0.0

    override var intrinsicContentSize: CGSize {
        CGSize(width: 70, height: 32)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        clipsToBounds = true
        layer.addSublayer(baseLayer)
        layer.addSublayer(progressCircleLayer)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "lc.appBanner.run".loc
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.1
        titleLabel.isUserInteractionEnabled = false

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = .white
        activityIndicator.hidesWhenStopped = true
        activityIndicator.isUserInteractionEnabled = false

        addSubview(titleLabel)
        addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "lc.appBanner.run".loc
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        baseLayer.frame = bounds

        let width = bounds.width
        progressCircleLayer.frame = CGRect(
            x: (CGFloat(progress) - 2) * width,
            y: bounds.height / 2 - width,
            width: width * 2,
            height: width * 2
        )
        progressCircleLayer.cornerRadius = width
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -4, dy: -6).contains(point)
    }

    func update(color: UIColor, isSigning: Bool, progress: Double, isEnabled: Bool) {
        self.progress = min(max(progress, 0), 1)
        self.isEnabled = isEnabled

        baseLayer.backgroundColor = color.withAlphaComponent(isSigning ? 0.2 : 1).cgColor
        progressCircleLayer.backgroundColor = color.cgColor
        progressCircleLayer.isHidden = !isSigning
        titleLabel.isHidden = isSigning
        if isSigning {
            activityIndicator.startAnimating()
            accessibilityValue = NumberFormatter.localizedString(from: NSNumber(value: self.progress), number: .percent)
        } else {
            activityIndicator.stopAnimating()
            accessibilityValue = nil
        }
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        setNeedsLayout()
    }
}

