package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type remoteHookInput struct {
	object      map[string]any
	rawFallback string
	sessionID   string
	cwd         string
}

type remoteAgentDef struct {
	displayName string
	statusKey   string
	stdoutOK    string
}

func runCodexHookRelay(socketPath string, args []string, refreshAddr func() string) int {
	return runGenericAgentHookRelay(
		socketPath,
		args,
		refreshAddr,
		remoteAgentDef{displayName: "Codex", statusKey: "codex", stdoutOK: "{}"},
	)
}

func runClaudeHookRelay(socketPath string, args []string, refreshAddr func() string) int {
	if len(args) == 0 || isHelpArg(args[0]) {
		fmt.Fprintln(os.Stdout, "cmux claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use> [--workspace <id>] [--surface <id>]")
		return 0
	}

	subcommand := strings.ToLower(args[0])
	parsed, err := parseFlags(args[1:], []string{"workspace", "surface"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux claude-hook: %v\n", err)
		return 2
	}

	input := readRemoteHookInput()
	workspaceID := hookWorkspaceID(parsed.flags)
	surfaceID := hookSurfaceID(parsed.flags)

	switch subcommand {
	case "session-start", "active":
		fmt.Fprintln(os.Stdout, "OK")
		return 0
	case "prompt-submit", "pre-tool-use":
		if workspaceID == "" {
			fmt.Fprintln(os.Stderr, "cmux claude-hook: --workspace or CMUX_WORKSPACE_ID is required")
			return 1
		}
		if err := clearHookNotifications(socketPath, workspaceID, refreshAddr); err != nil {
			return printHookError("claude-hook", err)
		}
		if err := setHookStatus(socketPath, "claude_code", "Running", "bolt.fill", "#4C8DFF", workspaceID, refreshAddr); err != nil {
			return printHookError("claude-hook", err)
		}
		fmt.Fprintln(os.Stdout, "OK")
		return 0
	case "stop", "idle":
		if workspaceID == "" {
			fmt.Fprintln(os.Stderr, "cmux claude-hook: --workspace or CMUX_WORKSPACE_ID is required")
			return 1
		}
		if surfaceID != "" {
			subtitle, body := completionSummary("Claude session completed", input)
			if err := notifyHookTarget(socketPath, workspaceID, surfaceID, "Claude Code", subtitle, body, refreshAddr); err != nil {
				return printHookError("claude-hook", err)
			}
		}
		if err := setHookStatus(socketPath, "claude_code", "Idle", "pause.circle.fill", "#8E8E93", workspaceID, refreshAddr); err != nil {
			return printHookError("claude-hook", err)
		}
		fmt.Fprintln(os.Stdout, "OK")
		return 0
	case "notification", "notify":
		if workspaceID == "" {
			fmt.Fprintln(os.Stderr, "cmux claude-hook: --workspace or CMUX_WORKSPACE_ID is required")
			return 1
		}
		subtitle, body := claudeNotificationSummary(input)
		if surfaceID != "" {
			if err := notifyHookTarget(socketPath, workspaceID, surfaceID, "Claude Code", subtitle, body, refreshAddr); err != nil {
				return printHookError("claude-hook", err)
			}
		} else if err := notifyHookWorkspace(socketPath, workspaceID, "Claude Code", body, refreshAddr); err != nil {
			return printHookError("claude-hook", err)
		}
		if err := setHookStatus(socketPath, "claude_code", "Needs input", "bell.fill", "#4C8DFF", workspaceID, refreshAddr); err != nil {
			return printHookError("claude-hook", err)
		}
		fmt.Fprintln(os.Stdout, "OK")
		return 0
	case "session-end":
		if workspaceID != "" {
			_ = clearHookStatus(socketPath, "claude_code", workspaceID, refreshAddr)
			_ = clearHookNotifications(socketPath, workspaceID, refreshAddr)
		}
		fmt.Fprintln(os.Stdout, "OK")
		return 0
	default:
		fmt.Fprintf(os.Stderr, "cmux claude-hook: unknown subcommand %q\n", subcommand)
		return 2
	}
}

func runGenericAgentHookRelay(socketPath string, args []string, refreshAddr func() string, def remoteAgentDef) int {
	if len(args) == 0 || isHelpArg(args[0]) {
		fmt.Fprintf(os.Stdout, "cmux %s-hook <session-start|prompt-submit|stop|session-end> [--workspace <id>] [--surface <id>]\n", strings.ToLower(def.displayName))
		return 0
	}

	subcommand := strings.ToLower(args[0])
	parsed, err := parseFlags(args[1:], []string{"workspace", "surface"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux %s-hook: %v\n", strings.ToLower(def.displayName), err)
		return 2
	}

	input := readRemoteHookInput()
	workspaceID := hookWorkspaceID(parsed.flags)
	surfaceID := hookSurfaceID(parsed.flags)

	switch subcommand {
	case "session-start", "shell-done":
		fmt.Fprintln(os.Stdout, def.stdoutOK)
		return 0
	case "prompt-submit", "shell-exec":
		if workspaceID == "" {
			fmt.Fprintf(os.Stderr, "cmux %s-hook: --workspace or CMUX_WORKSPACE_ID is required\n", strings.ToLower(def.displayName))
			return 1
		}
		if err := clearHookNotifications(socketPath, workspaceID, refreshAddr); err != nil {
			return printHookError(strings.ToLower(def.displayName)+"-hook", err)
		}
		if err := setHookStatus(socketPath, def.statusKey, "Running", "bolt.fill", "#4C8DFF", workspaceID, refreshAddr); err != nil {
			return printHookError(strings.ToLower(def.displayName)+"-hook", err)
		}
		fmt.Fprintln(os.Stdout, def.stdoutOK)
		return 0
	case "stop", "agent-response":
		if workspaceID == "" {
			fmt.Fprintf(os.Stderr, "cmux %s-hook: --workspace or CMUX_WORKSPACE_ID is required\n", strings.ToLower(def.displayName))
			return 1
		}
		if surfaceID != "" {
			subtitle, body := completionSummary(def.displayName+" session completed", input)
			if err := notifyHookTarget(socketPath, workspaceID, surfaceID, def.displayName, subtitle, body, refreshAddr); err != nil {
				return printHookError(strings.ToLower(def.displayName)+"-hook", err)
			}
		}
		if err := setHookStatus(socketPath, def.statusKey, "Idle", "pause.circle.fill", "#8E8E93", workspaceID, refreshAddr); err != nil {
			return printHookError(strings.ToLower(def.displayName)+"-hook", err)
		}
		fmt.Fprintln(os.Stdout, def.stdoutOK)
		return 0
	case "session-end":
		if workspaceID != "" {
			_ = clearHookStatus(socketPath, def.statusKey, workspaceID, refreshAddr)
		}
		fmt.Fprintln(os.Stdout, def.stdoutOK)
		return 0
	default:
		fmt.Fprintf(os.Stderr, "cmux %s-hook: unknown subcommand %q\n", strings.ToLower(def.displayName), subcommand)
		return 2
	}
}

func readRemoteHookInput() remoteHookInput {
	data, _ := io.ReadAll(os.Stdin)
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return remoteHookInput{}
	}

	var object map[string]any
	if err := json.Unmarshal([]byte(trimmed), &object); err != nil {
		return remoteHookInput{rawFallback: truncateRemoteHook(normalizedRemoteHookLine(trimmed), 180)}
	}

	return remoteHookInput{
		object:    object,
		sessionID: firstRemoteHookString(object, []string{"session_id", "sessionId"}),
		cwd:       firstRemoteHookString(object, []string{"cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"}),
	}
}

func hookWorkspaceID(flags map[string]string) string {
	if value := strings.TrimSpace(flags["workspace"]); value != "" {
		return value
	}
	return strings.TrimSpace(os.Getenv("CMUX_WORKSPACE_ID"))
}

func hookSurfaceID(flags map[string]string) string {
	if value := strings.TrimSpace(flags["surface"]); value != "" {
		return value
	}
	return strings.TrimSpace(os.Getenv("CMUX_SURFACE_ID"))
}

func clearHookNotifications(socketPath, workspaceID string, refreshAddr func() string) error {
	return sendHookV1(socketPath, "clear_notifications --tab="+workspaceID, refreshAddr)
}

func setHookStatus(socketPath, key, value, icon, color, workspaceID string, refreshAddr func() string) error {
	cmd := fmt.Sprintf("set_status %s %s --icon=%s --color=%s --tab=%s", key, value, icon, color, workspaceID)
	return sendHookV1(socketPath, cmd, refreshAddr)
}

func clearHookStatus(socketPath, key, workspaceID string, refreshAddr func() string) error {
	return sendHookV1(socketPath, fmt.Sprintf("clear_status %s --tab=%s", key, workspaceID), refreshAddr)
}

func notifyHookTarget(socketPath, workspaceID, surfaceID, title, subtitle, body string, refreshAddr func() string) error {
	payload := strings.Join([]string{
		sanitizeRemoteNotificationField(title),
		sanitizeRemoteNotificationField(subtitle),
		sanitizeRemoteNotificationField(body),
	}, "|")
	return sendHookV1(socketPath, fmt.Sprintf("notify_target %s %s %s", workspaceID, surfaceID, payload), refreshAddr)
}

func notifyHookWorkspace(socketPath, workspaceID, title, body string, refreshAddr func() string) error {
	params := map[string]any{
		"workspace_id": workspaceID,
		"title":        sanitizeRemoteNotificationField(title),
		"body":         sanitizeRemoteNotificationField(body),
	}
	_, err := socketRoundTripV2(socketPath, "notification.create", params, refreshAddr)
	return err
}

func sendHookV1(socketPath, cmd string, refreshAddr func() string) error {
	resp, err := socketRoundTrip(socketPath, cmd, refreshAddr)
	if err != nil {
		return err
	}
	if strings.HasPrefix(strings.TrimSpace(resp), "ERROR:") {
		return fmt.Errorf("%s", strings.TrimSpace(resp))
	}
	return nil
}

func printHookError(command string, err error) int {
	fmt.Fprintf(os.Stderr, "cmux %s: %v\n", command, err)
	return 1
}

func completionSummary(defaultBody string, input remoteHookInput) (string, string) {
	subtitle := "Completed"
	if project := projectNameFromCWD(input.cwd); project != "" {
		subtitle = "Completed in " + project
	}

	body := firstRemoteHookString(input.object, []string{"last_assistant_message", "lastAssistantMessage", "message", "body", "text"})
	if body == "" {
		body = input.rawFallback
	}
	if body == "" {
		body = defaultBody
	}
	return subtitle, truncateRemoteHook(normalizedRemoteHookLine(body), 200)
}

func claudeNotificationSummary(input remoteHookInput) (string, string) {
	message := firstRemoteHookString(input.object, []string{"message", "body", "text", "prompt", "error", "description"})
	if message == "" {
		message = input.rawFallback
	}
	if message == "" {
		message = "Claude is waiting for your input"
	}

	signal := strings.ToLower(strings.Join([]string{
		firstRemoteHookString(input.object, []string{"event", "event_name", "hook_event_name", "type", "kind"}),
		firstRemoteHookString(input.object, []string{"notification_type", "matcher", "reason"}),
		message,
	}, " "))

	subtitle := "Attention"
	switch {
	case strings.Contains(signal, "permission") || strings.Contains(signal, "approve") || strings.Contains(signal, "approval"):
		subtitle = "Permission"
	case strings.Contains(signal, "error") || strings.Contains(signal, "failed") || strings.Contains(signal, "exception"):
		subtitle = "Error"
	case strings.Contains(signal, "complet") || strings.Contains(signal, "finish") || strings.Contains(signal, "done") || strings.Contains(signal, "success"):
		subtitle = "Completed"
	case strings.Contains(signal, "idle") || strings.Contains(signal, "wait") || strings.Contains(signal, "input"):
		subtitle = "Waiting"
	}
	return subtitle, truncateRemoteHook(normalizedRemoteHookLine(message), 180)
}

func firstRemoteHookString(object map[string]any, keys []string) string {
	if object == nil {
		return ""
	}
	for _, key := range keys {
		if value, ok := object[key].(string); ok {
			if trimmed := strings.TrimSpace(value); trimmed != "" {
				return trimmed
			}
		}
	}
	for _, nestedKey := range []string{"notification", "data", "context"} {
		nested, ok := object[nestedKey].(map[string]any)
		if !ok {
			continue
		}
		for _, key := range keys {
			if value, ok := nested[key].(string); ok {
				if trimmed := strings.TrimSpace(value); trimmed != "" {
					return trimmed
				}
			}
		}
	}
	return ""
}

func projectNameFromCWD(cwd string) string {
	cwd = strings.TrimSpace(cwd)
	if cwd == "" {
		return ""
	}
	return filepath.Base(cwd)
}

func normalizedRemoteHookLine(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func sanitizeRemoteNotificationField(value string) string {
	return strings.ReplaceAll(normalizedRemoteHookLine(value), "|", "/")
}

func truncateRemoteHook(value string, maxLength int) string {
	if maxLength <= 0 || len(value) <= maxLength {
		return value
	}
	if maxLength <= 3 {
		return value[:maxLength]
	}
	return value[:maxLength-3] + "..."
}

func isHelpArg(arg string) bool {
	switch arg {
	case "help", "--help", "-h":
		return true
	default:
		return false
	}
}
