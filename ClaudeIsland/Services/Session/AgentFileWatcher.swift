//
//  AgentFileWatcher.swift
//  ClaudeIsland
//
//  Watches agent JSONL files for real-time subagent tool updates.
//  Each Task tool gets its own watcher for its agent file.
//

import Foundation
import os.log

/// Logger for agent file watcher
private let logger = Logger(subsystem: "com.claudeisland", category: "AgentFileWatcher")

/// Protocol for receiving agent file update notifications
protocol AgentFileWatcherDelegate: AnyObject {
    func didUpdateAgentTools(sessionId: String, taskToolId: String, tools: [SubagentToolInfo])
}

/// Watches a single agent JSONL file for tool updates
class AgentFileWatcher {
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lastOffset: UInt64 = 0
    private let sessionId: String
    private let taskToolId: String
    private let agentId: String
    private let cwd: String
    private let storedTranscriptPath: String?
    private let filePath: String
    private let queue = DispatchQueue(label: "com.claudeisland.agentfilewatcher", qos: .userInitiated)

    /// Incrementally accumulated tool state
    private var knownTools: [SubagentToolInfo] = []
    private var completedToolIds: Set<String> = []
    private var seenToolIds: Set<String> = []

    weak var delegate: AgentFileWatcherDelegate?

    init(sessionId: String, taskToolId: String, agentId: String, cwd: String, transcriptPath: String? = nil) {
        self.sessionId = sessionId
        self.taskToolId = taskToolId
        self.agentId = agentId
        self.cwd = cwd
        self.storedTranscriptPath = transcriptPath

        self.filePath = ConversationParser.agentFilePath(
            agentId: agentId,
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            cwd: cwd
        )
    }

    /// Start watching the agent file
    func start() {
        queue.async { [weak self] in
            self?.startWatching()
        }
    }

    private func startWatching() {
        stopInternal()

        guard FileManager.default.fileExists(atPath: filePath),
              let handle = FileHandle(forReadingAtPath: filePath) else {
            logger.warning("Failed to open agent file: \(self.filePath, privacy: .public)")
            return
        }

        fileHandle = handle
        lastOffset = 0
        // Initial full parse from offset 0; parseTools() updates lastOffset
        parseTools()

        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            self?.parseTools()
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }

        source = newSource
        newSource.resume()

        logger.debug("Started watching agent file: \(self.agentId.prefix(8), privacy: .public) for task: \(self.taskToolId.prefix(12), privacy: .public)")
    }

    /// Parse tools incrementally from lastOffset, only reading new bytes
    private func parseTools() {
        guard let handle = fileHandle else { return }

        let currentOffset: UInt64
        do {
            currentOffset = try handle.seekToEnd()
        } catch {
            return
        }

        guard currentOffset > lastOffset else { return }

        do {
            try handle.seek(toOffset: lastOffset)
        } catch {
            return
        }

        let newData = handle.readData(ofLength: Int(currentOffset - lastOffset))
        lastOffset = currentOffset

        guard let newContent = String(data: newData, encoding: .utf8), !newContent.isEmpty else { return }

        var changed = false

        for line in newContent.components(separatedBy: "\n") where !line.isEmpty {
            // Check for tool_result lines
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String,
                       !completedToolIds.contains(toolUseId) {
                        completedToolIds.insert(toolUseId)
                        // Update existing tool's completion status
                        if let idx = knownTools.firstIndex(where: { $0.id == toolUseId }) {
                            knownTools[idx] = SubagentToolInfo(
                                id: knownTools[idx].id,
                                name: knownTools[idx].name,
                                input: knownTools[idx].input,
                                isCompleted: true,
                                timestamp: knownTools[idx].timestamp
                            )
                            changed = true
                        }
                    }
                }
            }

            // Check for tool_use lines
            if line.contains("\"tool_use\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    guard block["type"] as? String == "tool_use",
                          let toolId = block["id"] as? String,
                          let toolName = block["name"] as? String,
                          !seenToolIds.contains(toolId) else {
                        continue
                    }

                    seenToolIds.insert(toolId)

                    var input: [String: String] = [:]
                    if let inputDict = block["input"] as? [String: Any] {
                        for (key, value) in inputDict {
                            if let strValue = value as? String {
                                input[key] = strValue
                            } else if let intValue = value as? Int {
                                input[key] = String(intValue)
                            } else if let boolValue = value as? Bool {
                                input[key] = boolValue ? "true" : "false"
                            }
                        }
                    }

                    let isCompleted = completedToolIds.contains(toolId)
                    let timestamp = json["timestamp"] as? String

                    knownTools.append(SubagentToolInfo(
                        id: toolId,
                        name: toolName,
                        input: input,
                        isCompleted: isCompleted,
                        timestamp: timestamp
                    ))
                    changed = true
                }
            }
        }

        guard changed else { return }

        logger.debug("Agent \(self.agentId.prefix(8), privacy: .public) has \(self.knownTools.count) tools")

        let tools = knownTools
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.didUpdateAgentTools(
                sessionId: self.sessionId,
                taskToolId: self.taskToolId,
                tools: tools
            )
        }
    }

    /// Stop watching
    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        if source != nil {
            logger.debug("Stopped watching agent file: \(self.agentId.prefix(8), privacy: .public)")
        }
        source?.cancel()
        source = nil
    }

    deinit {
        source?.cancel()
    }
}

// MARK: - Agent File Watcher Manager

/// Manages agent file watchers for active Task tools
@MainActor
class AgentFileWatcherManager {
    static let shared = AgentFileWatcherManager()

    /// Active watchers keyed by "sessionId-taskToolId"
    private var watchers: [String: AgentFileWatcher] = [:]

    weak var delegate: AgentFileWatcherDelegate?

    private init() {}

    func startWatching(sessionId: String, taskToolId: String, agentId: String, cwd: String, transcriptPath: String? = nil) {
        let key = "\(sessionId)-\(taskToolId)"
        guard watchers[key] == nil else { return }

        let watcher = AgentFileWatcher(
            sessionId: sessionId,
            taskToolId: taskToolId,
            agentId: agentId,
            cwd: cwd,
            transcriptPath: transcriptPath
        )
        watcher.delegate = delegate
        watcher.start()
        watchers[key] = watcher

        logger.info("Started agent watcher for task \(taskToolId.prefix(12), privacy: .public)")
    }

    /// Stop watching a specific Task's agent file
    func stopWatching(sessionId: String, taskToolId: String) {
        let key = "\(sessionId)-\(taskToolId)"
        watchers[key]?.stop()
        watchers.removeValue(forKey: key)
    }

    /// Stop all watchers for a session
    func stopWatchingSession(sessionId: String) {
        let keysToRemove = watchers.keys.filter { $0.hasPrefix(sessionId) }
        for key in keysToRemove {
            watchers[key]?.stop()
            watchers.removeValue(forKey: key)
        }
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
    }

    /// Check if we're watching a Task's agent file
    func isWatching(sessionId: String, taskToolId: String) -> Bool {
        let key = "\(sessionId)-\(taskToolId)"
        return watchers[key] != nil
    }
}

// MARK: - Agent File Watcher Bridge

/// Bridge between AgentFileWatcherManager and SessionStore
/// Converts delegate callbacks into SessionEvent processing
@MainActor
class AgentFileWatcherBridge: AgentFileWatcherDelegate {
    static let shared = AgentFileWatcherBridge()

    private init() {}

    func didUpdateAgentTools(sessionId: String, taskToolId: String, tools: [SubagentToolInfo]) {
        Task {
            await SessionStore.shared.process(
                .agentFileUpdated(sessionId: sessionId, taskToolId: taskToolId, tools: tools)
            )
        }
    }
}
