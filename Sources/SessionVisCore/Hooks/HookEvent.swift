import Foundation

/// One hook invocation captured by the spool.
public struct HookEvent: Equatable, Sendable {
    public var name: String
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?
    public var receivedAt: Date
    public var toolName: String?
    public var message: String?
    public var notificationType: String?
    public var lastAssistantMessage: String?
    public var agentId: String?
    public var agentType: String?

    public init(name: String, sessionId: String, cwd: String? = nil, transcriptPath: String? = nil, receivedAt: Date,
                toolName: String? = nil, message: String? = nil, notificationType: String? = nil,
                lastAssistantMessage: String? = nil, agentId: String? = nil, agentType: String? = nil) {
        self.name = name; self.sessionId = sessionId; self.cwd = cwd; self.transcriptPath = transcriptPath
        self.receivedAt = receivedAt; self.toolName = toolName; self.message = message
        self.notificationType = notificationType; self.lastAssistantMessage = lastAssistantMessage
        self.agentId = agentId; self.agentType = agentType
    }
}
extension HookEvent {
    /// Decodes a Claude Code hook payload. Returns nil without `hook_event_name` and `session_id`.
    public init?(json data: Data, receivedAt: Date) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["hook_event_name"] as? String,
              let sid = obj["session_id"] as? String else { return nil }
        self.init(name: name, sessionId: sid,
                  cwd: obj["cwd"] as? String,
                  transcriptPath: obj["transcript_path"] as? String,
                  receivedAt: receivedAt,
                  toolName: obj["tool_name"] as? String,
                  message: obj["message"] as? String,
                  notificationType: obj["notification_type"] as? String,
                  lastAssistantMessage: obj["last_assistant_message"] as? String,
                  agentId: obj["agent_id"] as? String,
                  agentType: obj["agent_type"] as? String)
    }

    /// Notification types that mean the session is blocked on the user.
    public static let waitingNotificationTypes: Set<String> = [
        "permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog",
    ]
}
