struct WujiTaskState: Equatable {
    let statusText: String

    static let empty = WujiTaskState(statusText: "尚未开始任务")
}

