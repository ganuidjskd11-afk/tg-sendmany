//  SendManyEngine.swift
//  Nicegram 群发引擎 —— 只管「解析目标 → 排队 → 限速发送 → 汇总结果」
//
//  这份代码不依赖任何 Telegram 内部类型，网络调用通过闭包注入，
//  这样你 fork 的 Nicegram-iOS 版本即使 API 名字变了，也只需要改桥接那一处。
//
//  接入方式见同目录 README.md。

import Foundation

// MARK: - 数据结构

/// 解析出来的目标
struct SendPeer: Equatable {
    enum Kind: Equatable {
        case user(userId: Int64)
        case chat(chatId: Int64)
        case channel(channelId: Int64)
    }

    var kind: Kind
    var title: String
    var username: String?

    /// 构造 MTProto 请求要用的 Peer 描述
    var peerDescription: String {
        switch kind {
        case .user(let id): return "user\(id)"
        case .chat(let id): return "chat\(id)"
        case .channel(let id): return "channel\(id)"
        }
    }
}

/// 单条结果
struct SendManyItemResult {
    enum Status: Equatable {
        case ok
        case failed(String)
        case skipped(String)
        case floodWait(seconds: Int)
    }

    var rawTarget: String
    var title: String
    var status: Status
}

/// 汇总
struct SendManySummary {
    var total: Int = 0
    var succeeded: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    var stoppedReason: String = ""
}

/// 运行中的事件（给 UI 用）
enum SendManyEvent {
    case resolved(raw: String, title: String)
    case sending(raw: String, index: Int, total: Int)
    case finished(SendManySummary)
}

// MARK: - 引擎

final class SendManyEngine {

    struct Config {
        /// 两条之间的最短间隔（秒）
        var minGap: TimeInterval = 45
        /// 两条之间的最长间隔（秒）
        var maxGap: TimeInterval = 120
        /// 单账号每天上限
        var dailyCap: Int = 25
        /// 每条失败后的重试次数
        var maxRetries: Int = 1
        /// 是否把 {name} 替换成对方昵称
        var useNameInText: Bool = true

        static let `default` = Config()
    }

    // MARK: 网络桥接（由 App 注入，闭包化以隔离版本差异）

    var resolveUsername: (String, @escaping (Result<SendPeer, Error>) -> Void) -> Void = { _, cb in
        cb(.failure(NSError(domain: "SendMany", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "未接入 resolveUsername"])))
    }

    var resolvePhone: (String, @escaping (Result<SendPeer, Error>) -> Void) -> Void = { _, cb in
        cb(.failure(NSError(domain: "SendMany", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "未接入 resolvePhone"])))
    }

    var sendMessage: (SendPeer, String, @escaping (Result<Void, Error>) -> Void) -> Void = { _, _, cb in
        cb(.failure(NSError(domain: "SendMany", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "未接入 sendMessage"])))
    }

    /// 当天已发条数
    var sentTodayProvider: () -> Int = { 0 }
    /// 记一次发送成功
    var sentTodayIncrementer: () -> Void = {}

    let config: Config

    private var running = false
    private var cancelRequested = false

    /// 逐条结果回调（UI 用）
    var itemHandler: ((SendManyItemResult) -> Void)?

    init(config: Config = .default) {
        self.config = config
    }

    func cancel() {
        cancelRequested = true
    }

    // MARK: 工具

    static func isPhone(_ raw: String) -> Bool {
        let digits = raw.filter { $0.isNumber }
        return digits.count >= 8 && raw.contains { $0.isNumber }
    }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://t.me/", "http://t.me/", "t.me/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        if s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    // MARK: 主流程

    func run(targets rawTargets: [String],
             text: String,
             onEvent: @escaping (SendManyEvent) -> Void,
             completion: @escaping (SendManySummary) -> Void) {

        guard !running else { return }
        running = true
        cancelRequested = false

        let targets = rawTargets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var summary = SendManySummary()
        summary.total = targets.count

        var budget = max(0, config.dailyCap - sentTodayProvider())
        if budget == 0 {
            summary.stoppedReason = "今天已发满 \(config.dailyCap) 条，明天再来"
            summary.skipped = targets.count
            finish(summary: summary, onEvent: onEvent, completion: completion)
            return
        }

        step(targets: targets, index: 0, text: text, budget: budget,
             summary: summary, onEvent: onEvent, completion: completion, first: true)
    }

    // MARK: 递归推进

    private func step(targets: [String],
                      index: Int,
                      text: String,
                      budget: Int,
                      summary: SendManySummary,
                      onEvent: @escaping (SendManyEvent) -> Void,
                      completion: @escaping (SendManySummary) -> Void,
                      first: Bool) {

        if cancelRequested {
            summary.stoppedReason = "已手动停止"
            summary.skipped += max(0, targets.count - index)
            finish(summary: summary, onEvent: onEvent, completion: completion)
            return
        }

        if index >= targets.count {
            finish(summary: summary, onEvent: onEvent, completion: completion)
            return
        }

        if budget <= 0 {
            summary.stoppedReason = "达到今日上限 \(config.dailyCap) 条"
            summary.skipped += (targets.count - index)
            finish(summary: summary, onEvent: onEvent, completion: completion)
            return
        }

        // 第一条立刻发，后面每条之间随机等待
        if !first {
            let gap = Double.random(in: config.minGap...config.maxGap)
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
                self.step(targets: targets, index: index, text: text, budget: budget,
                          summary: summary, onEvent: onEvent, completion: completion, first: false)
            }
            return
        }

        let raw = targets[index]
        let normalized = SendManyEngine.normalize(raw)
        let resolve: (String, @escaping (Result<SendPeer, Error>) -> Void) -> Void =
            SendManyEngine.isPhone(normalized) ? resolvePhone : resolveUsername

        resolve(normalized) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                summary.failed += 1
                self.itemHandler?(SendManyItemResult(rawTarget: raw, title: normalized,
                                                     status: .failed(error.localizedDescription)))
                self.step(targets: targets, index: index + 1, text: text, budget: budget,
                          summary: summary, onEvent: onEvent, completion: completion, first: false)

            case .success(let peer):
                onEvent(.resolved(raw: raw, title: peer.title))

                var body = text
                if self.config.useNameInText {
                    body = body.replacingOccurrences(of: "{name}", with: peer.title)
                }

                onEvent(.sending(raw: raw, index: index + 1, total: targets.count))

                self.sendWithRetry(peer: peer, body: body, attempt: 0) { status in
                    switch status {
                    case .ok:
                        self.sentTodayIncrementer()
                        summary.succeeded += 1
                        self.itemHandler?(SendManyItemResult(rawTarget: raw, title: peer.title,
                                                             status: .ok))
                    case .flood(let seconds):
                        summary.failed += 1
                        summary.stoppedReason = "触发限流（等 \(seconds) 秒），今天先停"
                        self.itemHandler?(SendManyItemResult(rawTarget: raw, title: peer.title,
                                                             status: .floodWait(seconds: seconds)))
                        summary.skipped += (targets.count - index - 1)
                        self.finish(summary: summary, onEvent: onEvent, completion: completion)
                        return
                    case .failed(let message):
                        summary.failed += 1
                        self.itemHandler?(SendManyItemResult(rawTarget: raw, title: peer.title,
                                                             status: .failed(message)))
                    }

                    self.step(targets: targets, index: index + 1, text: text, budget: budget - 1,
                              summary: summary, onEvent: onEvent, completion: completion, first: false)
                }
            }
        }
    }

    private func finish(summary: SendManySummary,
                        onEvent: @escaping (SendManyEvent) -> Void,
                        completion: @escaping (SendManySummary) -> Void) {
        running = false
        onEvent(.finished(summary))
        completion(summary)
    }

    private func sendWithRetry(peer: SendPeer,
                               body: String,
                               attempt: Int,
                               completion: @escaping (SendManyItemResult.Status) -> Void) {
        sendMessage(peer, body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                completion(.ok)

            case .failure(let error):
                let ns = error as NSError
                let isFlood = ns.domain.contains("FLOOD_WAIT") ||
                              ns.domain.contains("PEER_FLOOD") ||
                              ns.userInfo["flood_seconds"] != nil
                if isFlood {
                    var seconds = 60
                    if let value = ns.userInfo["flood_seconds"] as? Int { seconds = value }
                    completion(.flood(seconds: seconds))
                    return
                }
                if attempt < self.config.maxRetries {
                    let delay = Double.random(in: 5...15)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.sendWithRetry(peer: peer, body: body, attempt: attempt + 1,
                                           completion: completion)
                    }
                    return
                }
                completion(.failed(error.localizedDescription))
            }
        }
    }
}
