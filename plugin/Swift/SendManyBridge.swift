//  SendManyBridge.swift
//  把群发引擎接到 Nicegram / Telegram-iOS 的网络层
//
//  ⚠️ 这一份是「版本相关」的部分：Telegram-iOS 每年大改几次网络层 API。
//     下面按当前 master 的写法给（self.network.request(...)）。
//     如果你的 fork 里名字对不上，按对照表改一改就能跑：
//
//     | 你的版本里                        | 换成                              |
//     |-----------------------------------|-----------------------------------|
//     | self.network.request(_:queue:_:)  | EngineMsg(...).request { ... }    |
//     | self.accountManager.network       | self.engine / accountContext      |
//     | MessagesResolveUsernameRequest    | 名字一般不变                      |
//     | ContactsResolvePhoneRequest       | 名字一般不变                      |
//     | MessagesSendMessageRequest        | 名字一般不变                      |
//
//  原理只有三条：
//    1. 用用户名或手机号解析成 Peer
//    2. 用 Peer 发文本消息，randomId 每次必须唯一
//    3. FloodWait / PeerFlood 必须识别出来，交给引擎停手

import Foundation

#if canImport(TelegramCore)
import TelegramCore
#endif

/// 不含任何 Telegram 类型的桥接容器：UI 只跟它打交道
final class SendManyBridge {

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
}

/// 由 App 实现这个协议，把当前版本的 network 包装成三个闭包
protocol SendManyBridgeProviding: AnyObject {
    func makeSendManyBridge() -> SendManyBridge
}

// MARK: - Telegram 侧实现

#if canImport(TelegramCore)

/// 放在能看到 App 网络层的地方（比如 ActionController / AppDelegate）
/// 用法：SendManyController.bridgeFactory = { controller in
///     controller.makeSendManyBridge()   // 你的实现
/// }
enum TelegramSendManyBridge {

    static func make(network: Any, completion: @escaping (SendManyBridge) -> Void) {
        var bridge = SendManyBridge()

        bridge.resolveUsername = { username, cb in
            let request = MessagesResolveUsernameRequest(username: username, settings: [])
            // ↓↓↓ 这里换成你版本里的发送方式 ↓↓↓
            send(network: network, request: request) { (result: Result<MessagesResolvedPeer, EngineError>) in
                switch result {
                case .success(let resolved):
                    guard let peer = resolved.peer, let kind = kind(from: peer) else {
                        cb(.failure(NSError(domain: "SendMany", code: 10,
                                            userInfo: [NSLocalizedDescriptionKey: "解析不到这个用户"])))
                        return
                    }
                    var title = ""
                    var uname: String?
                    if let users = resolved.users, let user = users.first {
                        title = user.firstName
                        uname = user.usernames?.first?.username
                    }
                    cb(.success(SendPeer(kind: kind, title: title, username: uname)))
                case .failure(let error):
                    cb(.failure(mapError(error)))
                }
            }
        }

        bridge.resolvePhone = { phone, cb in
            let request = ContactsResolvePhoneRequest(phone: phone)
            send(network: network, request: request) { (result: Result<ContactsResolvedPeer, EngineError>) in
                switch result {
                case .success(let resolved):
                    guard let peer = resolved.peer, let kind = kind(from: peer) else {
                        cb(.failure(NSError(domain: "SendMany", code: 11,
                                            userInfo: [NSLocalizedDescriptionKey: "这个手机号没注册 Telegram"])))
                        return
                    }
                    var title = ""
                    var uname: String?
                    if let users = resolved.users, let user = users.first {
                        title = user.firstName
                        uname = user.usernames?.first?.username
                    }
                    cb(.success(SendPeer(kind: kind, title: title, username: uname)))
                case .failure(let error):
                    cb(.failure(mapError(error)))
                }
            }
        }

        bridge.sendMessage = { peer, text, cb in
            // randomId 必须每次不同，否则 Telegram 会当成重复消息丢掉
            let randomId = Int64.random(in: 1...Int64(Int32.max))
            let message = NSMutableString(string: text)
            let request = MessagesSendMessageRequest(
                peer: peer.peerDescription,
                message: message,
                randomId: randomId,
                scheduleDate: nil,
                scheduleFlags: nil,
                background: false,
                clearDraft: false,
                noUpdates: false,
                invertMedia: false
            )
            send(network: network, request: request) { (result: Result<MessagesSentMessage, EngineError>) in
                switch result {
                case .success:
                    cb(.success(()))
                case .failure(let error):
                    cb(.failure(mapError(error)))
                }
            }
        }

        completion(bridge)
    }

    // MARK: 工具

    private static func kind(from peer: Peer) -> SendPeer.Kind? {
        switch peer {
        case .user(let id, _): return .user(userId: id)
        case .chat(let id): return .chat(chatId: id)
        case .channel(let id, _): return .channel(channelId: id)
        }
    }

    /// 把 EngineError 转成 NSError，把限流秒数塞进 userInfo，引擎才能识别并停手
    static func mapError(_ error: EngineError) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: error.description]
        if case .floodWait(let seconds) = error {
            info["flood_seconds"] = seconds
        }
        return NSError(domain: "SendMany", code: 1, userInfo: info)
    }

    /// 统一发送入口 —— 版本差异只在这一个函数里
    private static func send<T>(network: Any,
                                request: T,
                                completion: @escaping (Result<T, EngineError>) -> Void) {
        // 当前 master 写法：
        //   (network as! Network).request(request, queue: .main) { result in completion(result) }
        // 老版本写法：
        //   EngineMsg(request).request { result in completion(result) }
        guard let performer = network as? SendManyRequestPerforming else {
            completion(.failure(.preconditionFailed("network 不是可用的请求发送器，请改 send() 里的写法")))
            return
        }
        performer.send(request, completion: completion)
    }
}

/// 在你的 App 里实现这个协议，把当前版本的 network 适配过来
protocol SendManyRequestPerforming: AnyObject {
    func send<T>(_ request: T, completion: @escaping (Result<T, EngineError>) -> Void)
}

#endif
