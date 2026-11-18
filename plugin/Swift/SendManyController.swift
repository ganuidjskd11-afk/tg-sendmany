//  SendManyController.swift
//  群发界面 —— 纯 UIKit，不依赖 Telegram 内部控件，方便跨版本复用。
//
//  放在：Nicegram/Features/SendMany/SendManyController.swift
//  目标：在 Nicegram 里加一个「群发」页面：
//        粘贴一批 @用户名 / 手机号 → 填文案 → 开始 → 实时看到每条结果。

import UIKit

final class SendManyController: UIViewController {

    // MARK: 状态

    private enum Mode {
        case idle
        case running
        case finished
    }

    private var mode: Mode = .idle
    private var rows: [SendManyItemResult] = []

    // MARK: 视图

    private let scrollView = UIScrollView()
    private let content = UIStackView()

    private let targetsView = UITextView()
    private let textView = UITextView()
    private let gapField = UITextField()
    private let capField = UITextField()
    private let statusLabel = UILabel()
    private let progressLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)

    private var engine: SendManyEngine!

    // MARK: 注入（App 启动时塞进来）

    /// 由 App 注入网络桥接
    static var bridgeFactory: ((UIViewController) -> SendManyBridge)?

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "群发"
        view.backgroundColor = .systemBackground

        engine = SendManyEngine(config: SendManyEngine.Config(
            minGap: 45,
            maxGap: 120,
            dailyCap: 25,
            maxRetries: 1,
            useNameInText: true
        ))

        if let factory = SendManyController.bridgeFactory {
            let bridge = factory(self)
            engine.resolveUsername = bridge.resolveUsername
            engine.resolvePhone = bridge.resolvePhone
            engine.sendMessage = bridge.sendMessage
        }

        setupViews()
        setupLayout()
    }

    // MARK: 搭界面

    private func setupViews() {
        content.axis = .vertical
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.addSubview(content)
        view.addSubview(scrollView)

        // 目标
        let targetsTitle = makeLabel("目标（每行一个 @用户名 或 手机号，# 开头是注释）")
        targetsView.font = .systemFont(ofSize: 15)
        targetsView.layer.borderWidth = 1
        targetsView.layer.borderColor = UIColor.separator.cgColor
        targetsView.layer.cornerRadius = 8
        targetsView.autocapitalizationType = .none
        targetsView.autocorrectionType = .no
        targetsView.text = "@durov\n"
        targetsView.heightAnchor.constraint(equalToConstant: 110).isActive = true

        // 文案
        let textTitle = makeLabel("文案（{name} 会替换成对方昵称）")
        textView.font = .systemFont(ofSize: 15)
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.cornerRadius = 8
        textView.text = "你好"
        textView.heightAnchor.constraint(equalToConstant: 90).isActive = true

        // 参数
        let params = UIStackView()
        params.axis = .horizontal
        params.spacing = 10
        params.addArrangedSubview(makeLabel("间隔"))
        gapField.text = "45"
        gapField.keyboardType = .numberPad
        gapField.borderStyle = .roundedRect
        gapField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        params.addArrangedSubview(gapField)
        params.addArrangedSubview(makeLabel("秒   每日上限"))
        capField.text = "25"
        capField.keyboardType = .numberPad
        capField.borderStyle = .roundedRect
        capField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        params.addArrangedSubview(capField)
        params.addArrangedSubview(makeLabel("条"))

        // 按钮
        startButton.setTitle("开始发送", for: .normal)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        startButton.backgroundColor = .systemBlue
        startButton.setTitleColor(.white, for: .normal)
        startButton.layer.cornerRadius = 8
        startButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        stopButton.setTitle("停止", for: .normal)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        stopButton.isHidden = true

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.text = "就绪。间隔越长越安全，建议 ≥45 秒。"

        progressLabel.font = .systemFont(ofSize: 15, weight: .medium)
        progressLabel.text = ""

        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.isScrollEnabled = false
        tableView.rowHeight = 30

        [targetsTitle, targetsView, textTitle, textView, params, startButton,
         stopButton, statusLabel, progressLabel, tableView].forEach {
            content.addArrangedSubview($0)
        }
    }

    private func setupLayout() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        ])
    }

    private func makeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        return label
    }

    // MARK: 动作

    @objc private func startTapped() {
        guard mode != .running else { return }

        let targets = targetsView.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !targets.isEmpty else {
            statusLabel.text = "先填目标。"
            return
        }

        var config = engine.config
        config.minGap = Double(gapField.text ?? "") ?? 45
        config.maxGap = max(config.minGap, Double(gapField.text ?? "") ?? 120) * 1.6
        config.dailyCap = Int(capField.text ?? "") ?? 25
        engine = SendManyEngine(config: config)
        if let factory = SendManyController.bridgeFactory {
            let bridge = factory(self)
            engine.resolveUsername = bridge.resolveUsername
            engine.resolvePhone = bridge.resolvePhone
            engine.sendMessage = bridge.sendMessage
        }

        rows = []
        tableView.reloadData()
        mode = .running
        startButton.isHidden = true
        stopButton.isHidden = false
        statusLabel.text = "发送中…"

        engine.itemHandler = { [weak self] item in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rows.append(item)
                self.tableView.reloadData()
                switch item.status {
                case .ok:
                    self.statusLabel.text = "已发送 \(item.rawTarget)"
                case .failed(let message):
                    self.statusLabel.text = "\(item.rawTarget) 失败：\(message)"
                case .skipped(let reason):
                    self.statusLabel.text = "\(item.rawTarget) 跳过：\(reason)"
                case .floodWait(let seconds):
                    self.statusLabel.text = "限流，等 \(seconds) 秒，已停止。"
                }
            }
        }

        engine.run(targets: targets, text: textView.text ?? "", onEvent: { [weak self] event in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch event {
                case .resolved(let raw, let title):
                    self.progressLabel.text = "解析成功：\(raw) → \(title)"
                case .sending(let raw, let index, let total):
                    self.progressLabel.text = "[\(index)/\(total)] \(raw)"
                case .finished(let summary):
                    self.mode = .finished
                    self.startButton.isHidden = false
                    self.stopButton.isHidden = true
                    var text = "完成：成功 \(summary.succeeded)，失败 \(summary.failed)，跳过 \(summary.skipped)"
                    if !summary.stoppedReason.isEmpty {
                        text += "\n\(summary.stoppedReason)"
                    }
                    self.statusLabel.text = text
                    self.progressLabel.text = ""
                }
            }
        }, completion: { _ in })
    }

    @objc private func stopTapped() {
        engine.cancel()
        statusLabel.text = "正在停止…"
    }
}

// MARK: - 结果表

extension SendManyController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = rows[indexPath.row]
        switch item.status {
        case .ok:
            cell.textLabel?.text = "✓ \(item.rawTarget)  \(item.title)"
            cell.textLabel?.textColor = .systemGreen
        case .failed(let message):
            cell.textLabel?.text = "× \(item.rawTarget)  \(message)"
            cell.textLabel?.textColor = .systemRed
        case .skipped(let reason):
            cell.textLabel?.text = "- \(item.rawTarget)  \(reason)"
            cell.textLabel?.textColor = .secondaryLabel
        case .floodWait(let seconds):
            cell.textLabel?.text = "! \(item.rawTarget)  限流 \(seconds)s"
            cell.textLabel?.textColor = .systemOrange
        }
        cell.textLabel?.font = .systemFont(ofSize: 13)
        return cell
    }
}
