# SSH Project Source Of Truth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a UI path for persistent SSH projects where the remote host maintains project and group registry state keyed by `ssh://<host>/<absolute-remote-path>`.

**Architecture:** Add durable project registry RPCs to `cmuxd-remote`, then add Swift identity/client types that upsert the remote project before creating the workspace. The UI replaces the direct `Open Folder...` local-only path with a two-mode opener: existing local folder selection and new SSH project selection.

**Tech Stack:** Go remote daemon (`daemon/remote/cmd/cmuxd-remote`), Swift/AppKit/SwiftUI macOS app (`Sources`), XCTest (`cmuxTests`), Python socket regression tests (`tests_v2`). Repository policy: do not run tests locally; use CI/VM verification commands.

---

## File Structure

- Create `daemon/remote/cmd/cmuxd-remote/project_registry.go`
  Remote registry value types, normalization, atomic JSON persistence, and project/group CRUD helpers.
- Modify `daemon/remote/cmd/cmuxd-remote/main.go`
  Add registry storage to `rpcServer`, advertise `project.registry.v1`, and dispatch `project.*` RPC methods.
- Create `daemon/remote/cmd/cmuxd-remote/project_registry_test.go`
  Runtime tests for normalization, path validation, atomic files, and RPC behavior.
- Create `Sources/SSHProjectIdentity.swift`
  Swift value types for project identity, URI parsing, RPC records, workspace metadata, and validation errors.
- Create `cmuxTests/SSHProjectIdentityTests.swift`
  XCTest coverage for `ssh://host/path`, `host:/path`, host alias checks, path validation, and Codable round-trips.
- Modify `GhosttyTabs.xcodeproj/project.pbxproj`
  Add new Swift source and test files to the app and unit-test targets.
- Modify `Sources/Workspace.swift`
  Extend `WorkspaceRemoteConfiguration`, project remote bootstrap, remote daemon RPC one-shot calls, startup `cd`, remote status payload, and session metadata.
- Modify `Sources/SessionPersistence.swift`
  Persist remote project metadata for restorable workspaces without persisting ephemeral relay ports.
- Modify `Sources/TabManager.swift`
  Add workspace creation entry point for an already-upserted SSH project and keep existing `cmux.json` project remote behavior intact.
- Modify `Sources/TerminalController.swift`
  Add socket-testable workspace creation support for pre-upserted SSH project metadata.
- Modify `Sources/AppDelegate.swift`
  Route menu/palette open-folder actions through the new opener and coordinate SSH project upsert before workspace creation.
- Create `Sources/SSHProjectOpenView.swift`
  SwiftUI/AppKit-hosted opener UI with Local Folder and SSH Project modes.
- Modify `Sources/ContentView.swift`
  Route command palette `Open Folder...` to `AppDelegate.showProjectOpenPanel`.
- Modify `Sources/cmuxApp.swift`
  Keep File menu entry pointing at the new opener and add localized menu strings if labels change.
- Modify `Resources/Localizable.xcstrings`
  Add every user-visible string for the SSH Project opener and errors.
- Create `tests_v2/test_ssh_project_workspace_metadata.py`
  Socket-level regression for workspace metadata and ad hoc `cmux ssh` non-regression.
- Modify `daemon/remote/README.md`
  Document `project.*` remote daemon RPCs and registry files.

## Verification Policy

Do not run tests locally in this repository. Every task lists CI/VM verification commands so the implementer knows what to trigger or ask the VM to run. If a future worker is in a VM explicitly designated for tests, the commands are safe there.

---

### Task 1: Remote Project Registry Core

**Files:**
- Create: `daemon/remote/cmd/cmuxd-remote/project_registry.go`
- Create: `daemon/remote/cmd/cmuxd-remote/project_registry_test.go`

- [ ] **Step 1: Write failing registry tests**

Add this test file:

```go
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func fixedProjectRegistryNow() time.Time {
	return time.Date(2026, 5, 5, 0, 0, 0, 0, time.UTC)
}

func TestProjectRegistryUpsertCreatesProjectAndDefaultGroup(t *testing.T) {
	root := t.TempDir()
	remoteDir := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(remoteDir, 0o755); err != nil {
		t.Fatal(err)
	}

	registry := projectRegistry{root: root, now: fixedProjectRegistryNow}
	project, groups, err := registry.upsert(projectUpsertRequest{
		Host:       "DevBox",
		RemotePath: remoteDir,
	})
	if err != nil {
		t.Fatalf("upsert failed: %v", err)
	}

	if project.Transport != "ssh" {
		t.Fatalf("transport = %q, want ssh", project.Transport)
	}
	if project.Host != "devbox" {
		t.Fatalf("host = %q, want devbox", project.Host)
	}
	if project.RemotePath != remoteDir {
		t.Fatalf("remotePath = %q, want %q", project.RemotePath, remoteDir)
	}
	if project.DisplayName != filepath.Base(remoteDir) {
		t.Fatalf("displayName = %q, want %q", project.DisplayName, filepath.Base(remoteDir))
	}
	if len(groups) != 1 || groups[0].ID != "default" || groups[0].Name != "Default" {
		t.Fatalf("default groups mismatch: %+v", groups)
	}

	if _, err := os.Stat(filepath.Join(root, "index.json")); err != nil {
		t.Fatalf("index.json missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, project.ID, "project.json")); err != nil {
		t.Fatalf("project.json missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, project.ID, "groups.json")); err != nil {
		t.Fatalf("groups.json missing: %v", err)
	}
}

func TestProjectRegistryUpsertRejectsRelativeAndMissingPaths(t *testing.T) {
	registry := projectRegistry{root: t.TempDir(), now: fixedProjectRegistryNow}

	_, _, relativeErr := registry.upsert(projectUpsertRequest{
		Host:       "devbox",
		RemotePath: "repo",
	})
	if relativeErr == nil || !isProjectRegistryErrorCode(relativeErr, "invalid_params") {
		t.Fatalf("relative path error = %v, want invalid_params", relativeErr)
	}

	_, _, missingErr := registry.upsert(projectUpsertRequest{
		Host:       "devbox",
		RemotePath: filepath.Join(t.TempDir(), "missing"),
	})
	if missingErr == nil || !isProjectRegistryErrorCode(missingErr, "not_found") {
		t.Fatalf("missing path error = %v, want not_found", missingErr)
	}
}

func TestProjectRegistryGetAndListUseRemoteSourceOfTruth(t *testing.T) {
	root := t.TempDir()
	remoteDir := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(remoteDir, 0o755); err != nil {
		t.Fatal(err)
	}

	registry := projectRegistry{root: root, now: fixedProjectRegistryNow}
	created, _, err := registry.upsert(projectUpsertRequest{Host: "devbox", RemotePath: remoteDir})
	if err != nil {
		t.Fatalf("upsert failed: %v", err)
	}

	loaded, groups, err := registry.get(projectGetRequest{ProjectID: created.ID})
	if err != nil {
		t.Fatalf("get failed: %v", err)
	}
	if loaded.ID != created.ID || len(groups) != 1 {
		t.Fatalf("loaded mismatch: project=%+v groups=%+v", loaded, groups)
	}

	listed, err := registry.list()
	if err != nil {
		t.Fatalf("list failed: %v", err)
	}
	if len(listed) != 1 || listed[0].ID != created.ID {
		t.Fatalf("listed mismatch: %+v", listed)
	}
}

func TestProjectRegistryProjectJSONSchema(t *testing.T) {
	root := t.TempDir()
	remoteDir := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(remoteDir, 0o755); err != nil {
		t.Fatal(err)
	}

	registry := projectRegistry{root: root, now: fixedProjectRegistryNow}
	project, _, err := registry.upsert(projectUpsertRequest{Host: "devbox", RemotePath: remoteDir})
	if err != nil {
		t.Fatalf("upsert failed: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(root, project.ID, "project.json"))
	if err != nil {
		t.Fatal(err)
	}
	var decoded projectRecord
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("project.json invalid JSON: %v", err)
	}
	if decoded.SchemaVersion != 1 || decoded.ID != project.ID {
		t.Fatalf("decoded project mismatch: %+v", decoded)
	}
}
```

- [ ] **Step 2: Verify tests fail in CI/VM**

CI/VM command:

```bash
cd daemon/remote && go test ./cmd/cmuxd-remote -run 'TestProjectRegistry' -count=1
```

Expected: compile failure because `projectRegistry`, request/record types, and error helpers do not exist.

- [ ] **Step 3: Implement registry types and persistence**

Create `project_registry.go` with this structure:

```go
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const projectRegistrySchemaVersion = 1

type projectRegistry struct {
	root string
	now  func() time.Time
}

type projectUpsertRequest struct {
	Host        string
	RemotePath  string
	DisplayName string
}

type projectGetRequest struct {
	ProjectID  string
	Host       string
	RemotePath string
}

type projectRecord struct {
	SchemaVersion int    `json:"schemaVersion"`
	ID            string `json:"id"`
	Transport     string `json:"transport"`
	Host          string `json:"host"`
	RemotePath    string `json:"remotePath"`
	DisplayName   string `json:"displayName"`
	CreatedAt     string `json:"createdAt"`
	UpdatedAt     string `json:"updatedAt"`
}

type projectGroupRecord struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

type projectGroupsFile struct {
	SchemaVersion int                  `json:"schemaVersion"`
	Groups        []projectGroupRecord `json:"groups"`
}

type projectIndexFile struct {
	SchemaVersion int             `json:"schemaVersion"`
	Projects      []projectRecord `json:"projects"`
}

type projectRegistryError struct {
	code    string
	message string
}

func (e projectRegistryError) Error() string { return e.message }

func isProjectRegistryErrorCode(err error, code string) bool {
	var registryErr projectRegistryError
	return errors.As(err, &registryErr) && registryErr.code == code
}

func defaultProjectRegistry() projectRegistry {
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		home = "."
	}
	return projectRegistry{
		root: filepath.Join(home, ".cmux", "projects"),
		now:  time.Now,
	}
}

func (r projectRegistry) upsert(req projectUpsertRequest) (projectRecord, []projectGroupRecord, error) {
	host, err := normalizeProjectHost(req.Host)
	if err != nil {
		return projectRecord{}, nil, err
	}
	remotePath, err := normalizeProjectRemotePath(req.RemotePath)
	if err != nil {
		return projectRecord{}, nil, err
	}
	if err := requireExistingDirectory(remotePath); err != nil {
		return projectRecord{}, nil, err
	}

	now := r.timestamp()
	id := stableProjectID("ssh", host, remotePath)
	displayName := strings.TrimSpace(req.DisplayName)
	if displayName == "" {
		displayName = filepath.Base(remotePath)
	}
	if displayName == "" || displayName == "." || displayName == string(filepath.Separator) {
		displayName = host
	}

	existing, _, existingErr := r.get(projectGetRequest{ProjectID: id})
	createdAt := now
	if existingErr == nil && existing.CreatedAt != "" {
		createdAt = existing.CreatedAt
	}

	project := projectRecord{
		SchemaVersion: projectRegistrySchemaVersion,
		ID:            id,
		Transport:     "ssh",
		Host:          host,
		RemotePath:    remotePath,
		DisplayName:   displayName,
		CreatedAt:     createdAt,
		UpdatedAt:     now,
	}
	groups := []projectGroupRecord{{
		ID:        "default",
		Name:      "Default",
		CreatedAt: createdAt,
		UpdatedAt: now,
	}}

	if err := r.writeProject(project, groups); err != nil {
		return projectRecord{}, nil, err
	}
	return project, groups, nil
}

func (r projectRegistry) get(req projectGetRequest) (projectRecord, []projectGroupRecord, error) {
	id := strings.TrimSpace(req.ProjectID)
	if id == "" {
		host, err := normalizeProjectHost(req.Host)
		if err != nil {
			return projectRecord{}, nil, err
		}
		remotePath, err := normalizeProjectRemotePath(req.RemotePath)
		if err != nil {
			return projectRecord{}, nil, err
		}
		id = stableProjectID("ssh", host, remotePath)
	}
	projectPath := filepath.Join(r.root, id, "project.json")
	data, err := os.ReadFile(projectPath)
	if err != nil {
		if os.IsNotExist(err) {
			return projectRecord{}, nil, projectRegistryError{code: "not_found", message: "project not found"}
		}
		return projectRecord{}, nil, projectRegistryError{code: "io_error", message: err.Error()}
	}
	var project projectRecord
	if err := json.Unmarshal(data, &project); err != nil {
		return projectRecord{}, nil, projectRegistryError{code: "invalid_registry", message: err.Error()}
	}
	groups, err := r.readGroups(id)
	if err != nil {
		return projectRecord{}, nil, err
	}
	return project, groups, nil
}

func (r projectRegistry) list() ([]projectRecord, error) {
	data, err := os.ReadFile(filepath.Join(r.root, "index.json"))
	if err != nil {
		if os.IsNotExist(err) {
			return []projectRecord{}, nil
		}
		return nil, projectRegistryError{code: "io_error", message: err.Error()}
	}
	var index projectIndexFile
	if err := json.Unmarshal(data, &index); err != nil {
		return nil, projectRegistryError{code: "invalid_registry", message: err.Error()}
	}
	sort.Slice(index.Projects, func(i, j int) bool {
		return index.Projects[i].DisplayName < index.Projects[j].DisplayName
	})
	return index.Projects, nil
}
```

Add the helper methods in the same file:

```go
func (r projectRegistry) timestamp() string {
	now := time.Now
	if r.now != nil {
		now = r.now
	}
	return now().UTC().Format(time.RFC3339)
}

func normalizeProjectHost(host string) (string, error) {
	trimmed := strings.TrimSpace(host)
	if trimmed == "" {
		return "", projectRegistryError{code: "invalid_params", message: "host is required"}
	}
	return strings.ToLower(trimmed), nil
}

func normalizeProjectRemotePath(path string) (string, error) {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return "", projectRegistryError{code: "invalid_params", message: "remote_path is required"}
	}
	if !filepath.IsAbs(trimmed) {
		return "", projectRegistryError{code: "invalid_params", message: "remote_path must be absolute"}
	}
	return filepath.Clean(trimmed), nil
}

func requireExistingDirectory(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return projectRegistryError{code: "not_found", message: fmt.Sprintf("remote path not found: %s", path)}
		}
		if os.IsPermission(err) {
			return projectRegistryError{code: "permission_denied", message: fmt.Sprintf("remote path not accessible: %s", path)}
		}
		return projectRegistryError{code: "io_error", message: err.Error()}
	}
	if !info.IsDir() {
		return projectRegistryError{code: "invalid_params", message: fmt.Sprintf("remote_path is not a directory: %s", path)}
	}
	return nil
}

func stableProjectID(transport, host, remotePath string) string {
	sum := sha256.Sum256([]byte(transport + "\x1f" + host + "\x1f" + remotePath))
	return transport + "-" + hex.EncodeToString(sum[:])[:24]
}

func (r projectRegistry) projectDir(projectID string) string {
	return filepath.Join(r.root, projectID)
}

func (r projectRegistry) writeProject(project projectRecord, groups []projectGroupRecord) error {
	projectDir := r.projectDir(project.ID)
	if err := os.MkdirAll(projectDir, 0o700); err != nil {
		return projectRegistryError{code: "io_error", message: err.Error()}
	}
	if err := writeJSONAtomic(filepath.Join(projectDir, "project.json"), project); err != nil {
		return err
	}
	if err := writeJSONAtomic(filepath.Join(projectDir, "groups.json"), projectGroupsFile{
		SchemaVersion: projectRegistrySchemaVersion,
		Groups:        groups,
	}); err != nil {
		return err
	}
	projects, err := r.list()
	if err != nil {
		return err
	}
	replaced := false
	for index := range projects {
		if projects[index].ID == project.ID {
			projects[index] = project
			replaced = true
			break
		}
	}
	if !replaced {
		projects = append(projects, project)
	}
	sort.Slice(projects, func(i, j int) bool {
		return projects[i].ID < projects[j].ID
	})
	return writeJSONAtomic(filepath.Join(r.root, "index.json"), projectIndexFile{
		SchemaVersion: projectRegistrySchemaVersion,
		Projects:      projects,
	})
}

func (r projectRegistry) readGroups(projectID string) ([]projectGroupRecord, error) {
	data, err := os.ReadFile(filepath.Join(r.projectDir(projectID), "groups.json"))
	if err != nil {
		return nil, projectRegistryError{code: "io_error", message: err.Error()}
	}
	var groups projectGroupsFile
	if err := json.Unmarshal(data, &groups); err != nil {
		return nil, projectRegistryError{code: "invalid_registry", message: err.Error()}
	}
	return groups.Groups, nil
}

func writeJSONAtomic(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return projectRegistryError{code: "io_error", message: err.Error()}
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return projectRegistryError{code: "invalid_params", message: err.Error()}
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp-")
	if err != nil {
		return projectRegistryError{code: "io_error", message: err.Error()}
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return projectRegistryError{code: "io_error", message: err.Error()}
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return projectRegistryError{code: "io_error", message: err.Error()}
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return projectRegistryError{code: "io_error", message: err.Error()}
	}
	if err := os.Rename(tmpPath, path); err != nil {
		_ = os.Remove(tmpPath)
		return projectRegistryError{code: "io_error", message: err.Error()}
	}
	return nil
}
```

- [ ] **Step 4: Verify registry tests pass in CI/VM**

CI/VM command:

```bash
cd daemon/remote && go test ./cmd/cmuxd-remote -run 'TestProjectRegistry' -count=1
```

Expected: PASS.

- [ ] **Step 5: Commit registry core**

```bash
git add daemon/remote/cmd/cmuxd-remote/project_registry.go daemon/remote/cmd/cmuxd-remote/project_registry_test.go
git commit -m "Add remote SSH project registry"
```

---

### Task 2: Remote Daemon Project RPC

**Files:**
- Modify: `daemon/remote/cmd/cmuxd-remote/main.go`
- Modify: `daemon/remote/cmd/cmuxd-remote/main_test.go`
- Modify: `daemon/remote/README.md`

- [ ] **Step 1: Add failing RPC tests**

Append these tests to `daemon/remote/cmd/cmuxd-remote/main_test.go`:

```go
func TestProjectRPCUpsertGetAndList(t *testing.T) {
	root := t.TempDir()
	remoteDir := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(remoteDir, 0o755); err != nil {
		t.Fatal(err)
	}
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		projects:      projectRegistry{root: root, now: fixedProjectRegistryNow},
	}
	defer server.closeAll()

	upsert := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "project.upsert",
		Params: map[string]any{
			"host":        "devbox",
			"remote_path": remoteDir,
		},
	})
	if !upsert.OK {
		t.Fatalf("project.upsert failed: %+v", upsert)
	}
	result := upsert.Result.(map[string]any)
	project := result["project"].(projectRecord)
	if project.Host != "devbox" || project.RemotePath != remoteDir {
		t.Fatalf("project mismatch: %+v", project)
	}

	get := server.handleRequest(rpcRequest{
		ID:     2,
		Method: "project.get",
		Params: map[string]any{"project_id": project.ID},
	})
	if !get.OK {
		t.Fatalf("project.get failed: %+v", get)
	}

	list := server.handleRequest(rpcRequest{
		ID:     3,
		Method: "project.list",
		Params: map[string]any{},
	})
	if !list.OK {
		t.Fatalf("project.list failed: %+v", list)
	}
}

func TestHelloAdvertisesProjectRegistryCapability(t *testing.T) {
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		projects:      projectRegistry{root: t.TempDir(), now: fixedProjectRegistryNow},
	}
	defer server.closeAll()

	resp := server.handleRequest(rpcRequest{ID: 1, Method: "hello", Params: map[string]any{}})
	if !resp.OK {
		t.Fatalf("hello failed: %+v", resp)
	}
	result := resp.Result.(map[string]any)
	capabilities := result["capabilities"].([]string)
	for _, capability := range capabilities {
		if capability == "project.registry.v1" {
			return
		}
	}
	t.Fatalf("hello capabilities missing project.registry.v1: %+v", capabilities)
}
```

- [ ] **Step 2: Verify RPC tests fail in CI/VM**

CI/VM command:

```bash
cd daemon/remote && go test ./cmd/cmuxd-remote -run 'TestProjectRPC|TestHelloAdvertisesProjectRegistryCapability' -count=1
```

Expected: compile failure because `rpcServer.projects` and RPC dispatch cases do not exist.

- [ ] **Step 3: Add `projects` to `rpcServer` initialization**

Modify `daemon/remote/cmd/cmuxd-remote/main.go`:

```go
type rpcServer struct {
	mu            sync.Mutex
	nextStreamID  uint64
	nextSessionID uint64
	streams       map[string]*streamState
	sessions      map[string]*sessionState
	projects      projectRegistry
	frameWriter   *stdioFrameWriter
}
```

In `runStdioServer`, initialize it:

```go
server := &rpcServer{
	nextStreamID:  1,
	nextSessionID: 1,
	streams:       map[string]*streamState{},
	sessions:      map[string]*sessionState{},
	projects:      defaultProjectRegistry(),
	frameWriter:   writer,
}
```

- [ ] **Step 4: Advertise and dispatch project RPCs**

In the `hello` capabilities array, add:

```go
"project.registry.v1",
```

In `handleRequest`, add cases:

```go
case "project.list":
	return s.handleProjectList(req)
case "project.get":
	return s.handleProjectGet(req)
case "project.upsert":
	return s.handleProjectUpsert(req)
case "project.groups.list":
	return s.handleProjectGroupsList(req)
```

- [ ] **Step 5: Implement RPC handlers**

Add handlers near the session handlers in `main.go`:

```go
func (s *rpcServer) handleProjectList(req rpcRequest) rpcResponse {
	projects, err := s.projects.list()
	if err != nil {
		return projectRPCError(req.ID, err)
	}
	return rpcResponse{ID: req.ID, OK: true, Result: map[string]any{"projects": projects}}
}

func (s *rpcServer) handleProjectGet(req rpcRequest) rpcResponse {
	projectID, _ := getStringParam(req.Params, "project_id")
	host, _ := getStringParam(req.Params, "host")
	remotePath, _ := getStringParam(req.Params, "remote_path")
	project, groups, err := s.projects.get(projectGetRequest{
		ProjectID:  projectID,
		Host:       host,
		RemotePath: remotePath,
	})
	if err != nil {
		return projectRPCError(req.ID, err)
	}
	return rpcResponse{ID: req.ID, OK: true, Result: map[string]any{
		"project": project,
		"groups":  groups,
	}}
}

func (s *rpcServer) handleProjectUpsert(req rpcRequest) rpcResponse {
	host, _ := getStringParam(req.Params, "host")
	remotePath, _ := getStringParam(req.Params, "remote_path")
	displayName, _ := getStringParam(req.Params, "display_name")
	project, groups, err := s.projects.upsert(projectUpsertRequest{
		Host:        host,
		RemotePath:  remotePath,
		DisplayName: displayName,
	})
	if err != nil {
		return projectRPCError(req.ID, err)
	}
	return rpcResponse{ID: req.ID, OK: true, Result: map[string]any{
		"project": project,
		"groups":  groups,
	}}
}

func (s *rpcServer) handleProjectGroupsList(req rpcRequest) rpcResponse {
	projectID, _ := getStringParam(req.Params, "project_id")
	if strings.TrimSpace(projectID) == "" {
		return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{
			Code:    "invalid_params",
			Message: "project.groups.list requires project_id",
		}}
	}
	_, groups, err := s.projects.get(projectGetRequest{ProjectID: projectID})
	if err != nil {
		return projectRPCError(req.ID, err)
	}
	return rpcResponse{ID: req.ID, OK: true, Result: map[string]any{"groups": groups}}
}

func projectRPCError(id any, err error) rpcResponse {
	var registryErr projectRegistryError
	if errors.As(err, &registryErr) {
		return rpcResponse{ID: id, OK: false, Error: &rpcError{
			Code:    registryErr.code,
			Message: registryErr.message,
		}}
	}
	return rpcResponse{ID: id, OK: false, Error: &rpcError{
		Code:    "internal_error",
		Message: err.Error(),
	}}
}
```

Add `errors` and `strings` imports only if not already present. `main.go` already imports both, so do not duplicate imports.

- [ ] **Step 6: Update daemon README**

In `daemon/remote/README.md`, add `project.list`, `project.get`, `project.upsert`, and `project.groups.list` to the RPC list, and add:

```markdown
## SSH project registry

`cmuxd-remote` stores SSH project registry data under `~/.cmux/projects`.
Projects are keyed by `transport=ssh`, SSH host alias, and absolute remote path.
The app may cache recent projects locally, but the remote registry is the source of truth.
```

- [ ] **Step 7: Verify RPC tests pass in CI/VM**

CI/VM command:

```bash
cd daemon/remote && go test ./cmd/cmuxd-remote -run 'TestProjectRegistry|TestProjectRPC|TestHelloAdvertisesProjectRegistryCapability' -count=1
```

Expected: PASS.

- [ ] **Step 8: Commit remote RPCs**

```bash
git add daemon/remote/cmd/cmuxd-remote/main.go daemon/remote/cmd/cmuxd-remote/main_test.go daemon/remote/README.md
git commit -m "Expose remote SSH project registry RPCs"
```

---

### Task 3: Swift SSH Project Identity

**Files:**
- Create: `Sources/SSHProjectIdentity.swift`
- Create: `cmuxTests/SSHProjectIdentityTests.swift`
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing Swift identity tests**

Create `cmuxTests/SSHProjectIdentityTests.swift`:

```swift
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SSHProjectIdentityTests: XCTestCase {
    func testParsesCanonicalSSHURI() throws {
        let identity = try SSHProjectIdentity.parse("ssh://devbox/home/dev/myrepo")
        XCTAssertEqual(identity.transport, "ssh")
        XCTAssertEqual(identity.host, "devbox")
        XCTAssertEqual(identity.remotePath, "/home/dev/myrepo")
        XCTAssertEqual(identity.displayURI, "ssh://devbox/home/dev/myrepo")
    }

    func testParsesHostColonAbsolutePathShortcut() throws {
        let identity = try SSHProjectIdentity.parse("DevBox:/home/dev/myrepo")
        XCTAssertEqual(identity.host, "devbox")
        XCTAssertEqual(identity.remotePath, "/home/dev/myrepo")
        XCTAssertEqual(identity.displayURI, "ssh://devbox/home/dev/myrepo")
    }

    func testRejectsRelativeRemotePath() {
        XCTAssertThrowsError(try SSHProjectIdentity(host: "devbox", remotePath: "repo")) { error in
            XCTAssertTrue(String(describing: error).contains("absolute"))
        }
    }

    func testRejectsBlankHost() {
        XCTAssertThrowsError(try SSHProjectIdentity(host: "   ", remotePath: "/repo"))
    }

    func testCodableRoundTrip() throws {
        let identity = try SSHProjectIdentity(host: "devbox", remotePath: "/home/dev/myrepo")
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(SSHProjectIdentity.self, from: data)
        XCTAssertEqual(decoded, identity)
    }
}
```

- [ ] **Step 2: Verify tests fail in CI/VM**

CI/VM command:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -only-testing:cmuxTests/SSHProjectIdentityTests test
```

Expected: compile failure because `SSHProjectIdentity` does not exist.

- [ ] **Step 3: Add Swift identity and RPC record types**

Create `Sources/SSHProjectIdentity.swift`:

```swift
import Foundation

enum SSHProjectIdentityError: LocalizedError, Equatable {
    case invalidHost
    case invalidRemotePath(String)
    case unsupportedURI(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "SSH project host must not be blank."
        case .invalidRemotePath(let path):
            return "SSH project remote path must be absolute: \(path)"
        case .unsupportedURI(let value):
            return "Unsupported SSH project location: \(value)"
        }
    }
}

struct SSHProjectIdentity: Codable, Sendable, Equatable, Hashable {
    let transport: String
    let host: String
    let remotePath: String

    init(host: String, remotePath: String) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else {
            throw SSHProjectIdentityError.invalidHost
        }
        let normalizedPath = (remotePath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .standardizingPath
        guard normalizedPath.hasPrefix("/") else {
            throw SSHProjectIdentityError.invalidRemotePath(remotePath)
        }
        self.transport = "ssh"
        self.host = normalizedHost
        self.remotePath = normalizedPath
    }

    var displayURI: String {
        "ssh://\(host)\(remotePath)"
    }

    static func parse(_ rawValue: String) throws -> SSHProjectIdentity {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("ssh://") {
            guard let components = URLComponents(string: value),
                  let host = components.host,
                  !components.path.isEmpty else {
                throw SSHProjectIdentityError.unsupportedURI(rawValue)
            }
            return try SSHProjectIdentity(host: host, remotePath: components.path)
        }

        if let colonIndex = value.firstIndex(of: ":") {
            let host = String(value[..<colonIndex])
            let pathStart = value.index(after: colonIndex)
            let path = String(value[pathStart...])
            return try SSHProjectIdentity(host: host, remotePath: path)
        }

        throw SSHProjectIdentityError.unsupportedURI(rawValue)
    }
}

struct SSHProjectGroupRecord: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let createdAt: String?
    let updatedAt: String?
}

struct SSHProjectRecord: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let id: String
    let transport: String
    let host: String
    let remotePath: String
    let displayName: String
    let createdAt: String?
    let updatedAt: String?

    var identity: SSHProjectIdentity? {
        try? SSHProjectIdentity(host: host, remotePath: remotePath)
    }
}

struct SSHProjectWorkspaceMetadata: Codable, Sendable, Equatable {
    let projectID: String
    let groupID: String
    let identity: SSHProjectIdentity
    let displayName: String
}
```

- [ ] **Step 4: Add files to Xcode project**

Update `GhosttyTabs.xcodeproj/project.pbxproj` so:

1. `Sources/SSHProjectIdentity.swift` is in the app target source build phase.
2. `cmuxTests/SSHProjectIdentityTests.swift` is in the unit-test target source build phase.

Use nearby source/test file entries as the pattern. Do not change unrelated project settings.

- [ ] **Step 5: Verify identity tests pass in CI/VM**

CI/VM command:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -only-testing:cmuxTests/SSHProjectIdentityTests test
```

Expected: PASS.

- [ ] **Step 6: Commit Swift identity**

```bash
git add Sources/SSHProjectIdentity.swift cmuxTests/SSHProjectIdentityTests.swift GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "Add SSH project identity model"
```

---

### Task 4: Pre-Workspace Remote Project Upsert Client

**Files:**
- Modify: `Sources/Workspace.swift`
- Create: `cmuxTests/SSHProjectRegistryClientTests.swift`
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing client tests**

Create `cmuxTests/SSHProjectRegistryClientTests.swift`:

```swift
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SSHProjectRegistryClientTests: XCTestCase {
    func testDecodesProjectUpsertResponse() throws {
        let payload: [String: Any] = [
            "project": [
                "schemaVersion": 1,
                "id": "ssh-abc123",
                "transport": "ssh",
                "host": "devbox",
                "remotePath": "/home/dev/myrepo",
                "displayName": "myrepo",
                "createdAt": "2026-05-05T00:00:00Z",
                "updatedAt": "2026-05-05T00:00:00Z",
            ],
            "groups": [
                [
                    "id": "default",
                    "name": "Default",
                    "createdAt": "2026-05-05T00:00:00Z",
                    "updatedAt": "2026-05-05T00:00:00Z",
                ]
            ],
        ]

        let result = try SSHProjectRegistryClient.decodeProjectResponse(payload)
        XCTAssertEqual(result.project.id, "ssh-abc123")
        XCTAssertEqual(result.project.remotePath, "/home/dev/myrepo")
        XCTAssertEqual(result.groups.map(\.id), ["default"])
    }

    func testBuildsWorkspaceMetadataFromUpsertResult() throws {
        let identity = try SSHProjectIdentity(host: "devbox", remotePath: "/home/dev/myrepo")
        let result = SSHProjectRegistryClient.ProjectResult(
            project: SSHProjectRecord(
                schemaVersion: 1,
                id: "ssh-abc123",
                transport: "ssh",
                host: "devbox",
                remotePath: "/home/dev/myrepo",
                displayName: "myrepo",
                createdAt: nil,
                updatedAt: nil
            ),
            groups: [SSHProjectGroupRecord(id: "default", name: "Default", createdAt: nil, updatedAt: nil)]
        )

        let metadata = try SSHProjectRegistryClient.workspaceMetadata(identity: identity, result: result)
        XCTAssertEqual(metadata.projectID, "ssh-abc123")
        XCTAssertEqual(metadata.groupID, "default")
        XCTAssertEqual(metadata.displayName, "myrepo")
    }
}
```

- [ ] **Step 2: Verify client tests fail in CI/VM**

CI/VM command:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -only-testing:cmuxTests/SSHProjectRegistryClientTests test
```

Expected: compile failure because `SSHProjectRegistryClient` does not exist.

- [ ] **Step 3: Add one-shot project RPC client**

In `Sources/Workspace.swift`, add a focused helper near `WorkspaceRemoteDaemonRPCClient`:

```swift
final class SSHProjectRegistryClient {
    struct ProjectResult: Equatable {
        let project: SSHProjectRecord
        let groups: [SSHProjectGroupRecord]
    }

    #if DEBUG
    static var upsertOverrideForTesting: ((SSHProjectIdentity) throws -> ProjectResult)?
    #endif

    static func decodeProjectResponse(_ payload: [String: Any]) throws -> ProjectResult {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        struct Response: Decodable {
            let project: SSHProjectRecord
            let groups: [SSHProjectGroupRecord]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return ProjectResult(project: response.project, groups: response.groups)
    }

    static func workspaceMetadata(
        identity: SSHProjectIdentity,
        result: ProjectResult
    ) throws -> SSHProjectWorkspaceMetadata {
        guard result.project.transport == identity.transport,
              result.project.host.caseInsensitiveCompare(identity.host) == .orderedSame,
              result.project.remotePath == identity.remotePath else {
            throw NSError(domain: "cmux.sshProject", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Remote project response did not match requested SSH project."
            ])
        }
        let groupID = result.groups.first?.id ?? "default"
        return SSHProjectWorkspaceMetadata(
            projectID: result.project.id,
            groupID: groupID,
            identity: identity,
            displayName: result.project.displayName
        )
    }

    static func upsert(
        identity: SSHProjectIdentity,
        completion: @escaping (Result<ProjectResult, Error>) -> Void
    ) {
        #if DEBUG
        if let upsertOverrideForTesting {
            do {
                completion(.success(try upsertOverrideForTesting(identity)))
            } catch {
                completion(.failure(error))
            }
            return
        }
        #endif

        WorkspaceRemoteSessionController.upsertSSHProject(identity: identity, completion: completion)
    }
}
```

In `WorkspaceRemoteSessionController`, add:

```swift
static func upsertSSHProject(
    identity: SSHProjectIdentity,
    completion: @escaping (Result<SSHProjectRegistryClient.ProjectResult, Error>) -> Void
) {
    let configuration = WorkspaceRemoteConfiguration(
        destination: identity.host,
        port: nil,
        identityFile: nil,
        sshOptions: [],
        localProxyPort: nil,
        relayPort: nil,
        relayID: nil,
        relayToken: nil,
        localSocketPath: nil,
        terminalStartupCommand: nil
    )
    let controller = WorkspaceRemoteSessionController(
        workspace: nil,
        configuration: configuration,
        controllerID: UUID(),
        mode: .prewarm(host: identity.host)
    )
    controller.queue.async {
        do {
            let hello = try controller.bootstrapDaemonLocked()
            let payload = try controller.callRemoteDaemonOnceLocked(
                remotePath: hello.remotePath,
                method: "project.upsert",
                params: [
                    "host": identity.host,
                    "remote_path": identity.remotePath,
                ]
            )
            let result = try SSHProjectRegistryClient.decodeProjectResponse(payload)
            DispatchQueue.main.async { completion(.success(result)) }
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }
}
```

Add the one-shot RPC helper in `WorkspaceRemoteSessionController`:

```swift
private func callRemoteDaemonOnceLocked(
    remotePath: String,
    method: String,
    params: [String: Any]
) throws -> [String: Any] {
    let requestObject: [String: Any] = [
        "id": 1,
        "method": method,
        "params": params,
    ]
    let requestData = try JSONSerialization.data(withJSONObject: requestObject)
    let request = String(decoding: requestData, as: UTF8.self) + "\n"
    let command = "sh -c \(Self.shellSingleQuoted("exec \(Self.shellSingleQuoted(remotePath)) serve --stdio"))"
    let result = try sshExec(
        arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
        stdin: Data(request.utf8),
        timeout: 12
    )
    guard result.status == 0 else {
        let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
        throw NSError(domain: "cmux.remote.project", code: 2, userInfo: [
            NSLocalizedDescriptionKey: detail,
        ])
    }
    guard let line = result.stdout.split(whereSeparator: \.isNewline).first,
          let data = String(line).data(using: .utf8),
          let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "cmux.remote.project", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Remote project RPC returned invalid JSON.",
        ])
    }
    if let ok = response["ok"] as? Bool, ok == true,
       let payload = response["result"] as? [String: Any] {
        return payload
    }
    let errorObject = response["error"] as? [String: Any]
    let message = errorObject?["message"] as? String ?? "Remote project RPC failed."
    throw NSError(domain: "cmux.remote.project", code: 4, userInfo: [
        NSLocalizedDescriptionKey: message,
    ])
}
```

If `sshExec` does not currently accept `stdin`, extend its signature with `stdin: Data? = nil` and keep all existing call sites source-compatible.

- [ ] **Step 4: Add new test file to Xcode project**

Add `cmuxTests/SSHProjectRegistryClientTests.swift` to `GhosttyTabs.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Verify client tests pass in CI/VM**

CI/VM command:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -only-testing:cmuxTests/SSHProjectRegistryClientTests test
```

Expected: PASS.

- [ ] **Step 6: Commit project RPC client**

```bash
git add Sources/Workspace.swift cmuxTests/SSHProjectRegistryClientTests.swift GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "Add SSH project registry client"
```

---

### Task 5: Workspace Metadata And Remote Path Startup

**Files:**
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/SessionPersistence.swift`
- Modify: `Sources/TabManager.swift`
- Modify: `cmuxTests/TabManagerUnitTests.swift`
- Modify: `cmuxTests/SessionPersistenceTests.swift`

- [ ] **Step 1: Write failing workspace tests**

Append to `cmuxTests/TabManagerUnitTests.swift`:

```swift
final class TabManagerSSHProjectWorkspaceTests: XCTestCase {
    func testSSHProjectWorkspaceUsesRemoteProjectStartupAndMetadata() throws {
        let manager = TabManager()
        let identity = try SSHProjectIdentity(host: "devbox", remotePath: "/home/dev/myrepo")
        let metadata = SSHProjectWorkspaceMetadata(
            projectID: "ssh-abc123",
            groupID: "default",
            identity: identity,
            displayName: "myrepo"
        )

        let previousWriter = ProjectRemoteWorkspaceBootstrap.startupScriptWriterOverrideForTesting
        ProjectRemoteWorkspaceBootstrap.startupScriptWriterOverrideForTesting = { script, _ in
            XCTAssertTrue(script.contains("cd '/home/dev/myrepo'"))
            return "/tmp/cmux-ssh-project-test.sh"
        }
        defer {
            ProjectRemoteWorkspaceBootstrap.startupScriptWriterOverrideForTesting = previousWriter
        }

        let workspace = manager.addWorkspace(
            title: metadata.displayName,
            sshProject: metadata,
            select: true
        )

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConfiguration?.sshProject?.projectID, "ssh-abc123")
        XCTAssertEqual(workspace.remoteConfiguration?.sshProject?.groupID, "default")
        XCTAssertEqual(workspace.remoteConfiguration?.sshProject?.identity.remotePath, "/home/dev/myrepo")
        XCTAssertEqual(workspace.focusedTerminalPanel?.surface.debugInitialCommand(), "/tmp/cmux-ssh-project-test.sh")
    }
}
```

Add a persistence test to `cmuxTests/SessionPersistenceTests.swift` near existing remote configuration tests:

```swift
func testWorkspaceRemoteConfigurationSnapshotPreservesSSHProjectMetadataWithoutRelaySecrets() throws {
    let identity = try SSHProjectIdentity(host: "devbox", remotePath: "/home/dev/myrepo")
    let metadata = SSHProjectWorkspaceMetadata(
        projectID: "ssh-abc123",
        groupID: "default",
        identity: identity,
        displayName: "myrepo"
    )
    let configuration = WorkspaceRemoteConfiguration(
        destination: "devbox",
        port: nil,
        identityFile: nil,
        sshOptions: [],
        localProxyPort: nil,
        relayPort: 64017,
        relayID: "relay",
        relayToken: "token",
        localSocketPath: "/tmp/cmux.sock",
        terminalStartupCommand: "/tmp/start.sh",
        sshProject: metadata
    )

    let snapshot = SessionWorkspaceRemoteConfigurationSnapshot(configuration: configuration)
    XCTAssertEqual(snapshot.sshProject?.projectID, "ssh-abc123")
    XCTAssertNil(snapshot.relayPort)
    XCTAssertNil(snapshot.relayID)
    XCTAssertNil(snapshot.relayToken)
}
```

- [ ] **Step 2: Verify workspace tests fail in CI/VM**

CI/VM command:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -only-testing:cmuxTests/TabManagerSSHProjectWorkspaceTests -only-testing:cmuxTests/SessionPersistenceTests/testWorkspaceRemoteConfigurationSnapshotPreservesSSHProjectMetadataWithoutRelaySecrets test
```

Expected: compile failure because `sshProject` metadata and `TabManager.addWorkspace(sshProject:)` do not exist.

- [ ] **Step 3: Extend `WorkspaceRemoteConfiguration`**

In `Sources/Workspace.swift`, add:

```swift
let sshProject: SSHProjectWorkspaceMetadata?
```

to `WorkspaceRemoteConfiguration`, update its initializer with:

```swift
sshProject: SSHProjectWorkspaceMetadata? = nil
```

and pass it through `withLocalRelayPort`.

- [ ] **Step 4: Extend project bootstrap for remote path**

Change `ProjectRemoteWorkspaceBootstrap.build` to support SSH project metadata:

```swift
static func build(sshProject: SSHProjectWorkspaceMetadata) -> ProjectRemoteWorkspaceBootstrap? {
    build(
        host: sshProject.identity.host,
        projectConfigPath: nil,
        sshProject: sshProject,
        remoteInitialDirectory: sshProject.identity.remotePath
    )
}

static func build(host: String, configPath: String) -> ProjectRemoteWorkspaceBootstrap? {
    build(
        host: host,
        projectConfigPath: configPath,
        sshProject: nil,
        remoteInitialDirectory: nil
    )
}
```

Replace the existing implementation body with a private shared builder:

```swift
private static func build(
    host: String,
    projectConfigPath: String?,
    sshProject: SSHProjectWorkspaceMetadata?,
    remoteInitialDirectory: String?
) -> ProjectRemoteWorkspaceBootstrap? {
    let relayPort = Int.random(in: 49152...65535)
    let relayID = UUID().uuidString.lowercased()
    let relayToken = randomHex(byteCount: 32)
    let sshOptions = effectiveSSHOptions(remoteRelayPort: relayPort)
    let foregroundAuthToken = UUID().uuidString.lowercased()
    let foregroundAuthCommand = deferredRemoteReconnectLocalCommand(
        in: sshOptions,
        foregroundAuthToken: foregroundAuthToken
    )
    let startupCommand = buildTerminalStartupCommand(
        host: host,
        relayPort: relayPort,
        localCommand: foregroundAuthCommand,
        remoteInitialDirectory: remoteInitialDirectory
    )
    guard let startupCommand else {
        NSLog("[ProjectRemote] failed to build managed terminal startup command for %@", host)
        return nil
    }
    return ProjectRemoteWorkspaceBootstrap(
        configuration: WorkspaceRemoteConfiguration(
            destination: host,
            port: nil,
            identityFile: nil,
            sshOptions: sshOptions,
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            localSocketPath: TerminalController.activeSocketPathForCurrentProcess(),
            terminalStartupCommand: startupCommand,
            foregroundAuthToken: foregroundAuthCommand == nil ? nil : foregroundAuthToken,
            projectConfigPath: projectConfigPath,
            sshProject: sshProject
        )
    )
}
```

Update `buildTerminalStartupCommand` and `buildInteractiveRemoteShellScript` to accept `remoteInitialDirectory: String?`. Before shell handoff, add:

```swift
if let remoteInitialDirectory,
   !remoteInitialDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    commonShellExportLines.append("cd \(shellQuote(remoteInitialDirectory)) || exit 1")
}
```

- [ ] **Step 5: Add `TabManager.addWorkspace(sshProject:)`**

In `Sources/TabManager.swift`, add an overload:

```swift
@discardableResult
func addWorkspace(
    title: String? = nil,
    sshProject: SSHProjectWorkspaceMetadata,
    select: Bool = true,
    eagerLoadTerminal: Bool = false
) -> Workspace {
    let bootstrap = ProjectRemoteWorkspaceBootstrap.build(sshProject: sshProject)
    return addWorkspace(
        title: title ?? sshProject.displayName,
        workingDirectory: nil,
        initialTerminalCommand: bootstrap?.configuration.terminalStartupCommand,
        initialTerminalEnvironment: [:],
        select: select,
        eagerLoadTerminal: eagerLoadTerminal,
        inferProjectRemote: false,
        explicitRemoteConfiguration: bootstrap?.configuration
    )
}
```

To make this compile without duplicating workspace creation logic, add an optional parameter to the existing `addWorkspace` implementation:

```swift
explicitRemoteConfiguration: WorkspaceRemoteConfiguration? = nil
```

Then choose:

```swift
let remoteConfigurationForWorkspace = explicitRemoteConfiguration ?? projectRemoteBootstrap?.configuration
```

and use `remoteConfigurationForWorkspace` where the current code uses `projectRemoteBootstrap?.configuration`.

- [ ] **Step 6: Persist SSH project metadata**

In `Sources/SessionPersistence.swift`, add:

```swift
var sshProject: SSHProjectWorkspaceMetadata?
```

to `SessionWorkspaceRemoteConfigurationSnapshot`.

In `init(configuration:)`, when `configuration.sshProject != nil`, persist `destination` and `sshProject`, but clear ephemeral fields:

```swift
if let sshProject = configuration.sshProject {
    self.port = nil
    self.identityFile = nil
    self.sshOptions = []
    self.localProxyPort = nil
    self.relayPort = nil
    self.localRelayPort = nil
    self.relayID = nil
    self.relayToken = nil
    self.localSocketPath = nil
    self.terminalStartupCommand = nil
    self.projectConfigPath = nil
    self.sshProject = sshProject
    return
}
```

In `workspaceRemoteConfiguration()`, rebuild SSH project remotes:

```swift
if let sshProject {
    return ProjectRemoteWorkspaceBootstrap.build(sshProject: sshProject)?.configuration
}
```

- [ ] **Step 7: Include SSH project in remote status payload**

In `Workspace.remoteStatusPayload()`, when `remoteConfiguration.sshProject` exists, add:

```swift
payload["project"] = [
    "id": sshProject.projectID,
    "group_id": sshProject.groupID,
    "transport": sshProject.identity.transport,
    "host": sshProject.identity.host,
    "remote_path": sshProject.identity.remotePath,
    "display_name": sshProject.displayName,
    "uri": sshProject.identity.displayURI,
]
```

- [ ] **Step 8: Verify workspace tests pass in CI/VM**

CI/VM command:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -only-testing:cmuxTests/TabManagerSSHProjectWorkspaceTests -only-testing:cmuxTests/SessionPersistenceTests/testWorkspaceRemoteConfigurationSnapshotPreservesSSHProjectMetadataWithoutRelaySecrets test
```

Expected: PASS.

- [ ] **Step 9: Commit workspace SSH project metadata**

```bash
git add Sources/Workspace.swift Sources/SessionPersistence.swift Sources/TabManager.swift cmuxTests/TabManagerUnitTests.swift cmuxTests/SessionPersistenceTests.swift
git commit -m "Attach workspaces to SSH projects"
```

---

### Task 6: SSH Project Opener UI

**Files:**
- Create: `Sources/SSHProjectOpenView.swift`
- Modify: `Sources/AppDelegate.swift`
- Modify: `Sources/ContentView.swift`
- Modify: `Sources/cmuxApp.swift`
- Modify: `Resources/Localizable.xcstrings`
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add opener view file**

Create `Sources/SSHProjectOpenView.swift`:

```swift
import SwiftUI

enum ProjectOpenMode: String, CaseIterable, Identifiable {
    case local
    case ssh

    var id: String { rawValue }
}

struct SSHProjectOpenView: View {
    @State private var mode: ProjectOpenMode = .local
    @State private var selectedHost: String = ""
    @State private var manualHost: String = ""
    @State private var remotePath: String = ""
    @State private var errorText: String?

    let sshHosts: [String]
    let openLocal: () -> Void
    let openSSH: (String, String) -> Void
    let cancel: () -> Void

    private var effectiveHost: String {
        let manual = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        return selectedHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canOpenSSH: Bool {
        !effectiveHost.isEmpty && remotePath.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $mode) {
                Text(String(localized: "openProject.mode.local", defaultValue: "Local Folder")).tag(ProjectOpenMode.local)
                Text(String(localized: "openProject.mode.ssh", defaultValue: "SSH Project")).tag(ProjectOpenMode.ssh)
            }
            .pickerStyle(.segmented)

            Group {
                switch mode {
                case .local:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "openProject.local.title", defaultValue: "Open a local folder"))
                            .font(.headline)
                        Text(String(localized: "openProject.local.detail", defaultValue: "Choose a folder on this Mac."))
                            .foregroundStyle(.secondary)
                    }
                case .ssh:
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "openProject.ssh.title", defaultValue: "Open an SSH project"))
                            .font(.headline)
                        Picker(String(localized: "openProject.ssh.host", defaultValue: "Host"), selection: $selectedHost) {
                            ForEach(sshHosts, id: \.self) { host in
                                Text(host).tag(host)
                            }
                        }
                        TextField(String(localized: "openProject.ssh.manualHost", defaultValue: "Host alias"), text: $manualHost)
                        TextField(String(localized: "openProject.ssh.remotePath", defaultValue: "/home/dev/project"), text: $remotePath)
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: cancel)
                Button(String(localized: "common.open", defaultValue: "Open")) {
                    switch mode {
                    case .local:
                        openLocal()
                    case .ssh:
                        guard canOpenSSH else {
                            errorText = String(localized: "openProject.ssh.invalid", defaultValue: "Enter an SSH host and an absolute remote path.")
                            return
                        }
                        openSSH(effectiveHost, remotePath)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            selectedHost = sshHosts.first ?? ""
        }
    }
}
```

Keep this view focused. Do not add a sidebar, cards, marketing copy, or remote project browsing in this task.

- [ ] **Step 2: Add `AppDelegate.showProjectOpenPanel`**

In `Sources/AppDelegate.swift`, add:

```swift
private var projectOpenWindowController: NSWindowController?

func showProjectOpenPanel(tabManager preferredTabManager: TabManager? = nil) {
    let hosts = SSHConfigHostScanner.hostAliases()
    let controller = NSHostingController(rootView: SSHProjectOpenView(
        sshHosts: hosts,
        openLocal: { [weak self] in
            self?.projectOpenWindowController?.close()
            self?.projectOpenWindowController = nil
            self?.showOpenFolderPanel()
        },
        openSSH: { [weak self] host, remotePath in
            self?.projectOpenWindowController?.close()
            self?.projectOpenWindowController = nil
            self?.openSSHProject(host: host, remotePath: remotePath, tabManager: preferredTabManager)
        },
        cancel: { [weak self] in
            self?.projectOpenWindowController?.close()
            self?.projectOpenWindowController = nil
        }
    ))
    let window = NSWindow(contentViewController: controller)
    window.title = String(localized: "openProject.title", defaultValue: "Open Project")
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    let windowController = NSWindowController(window: window)
    projectOpenWindowController = windowController
    windowController.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
}
```

Add:

```swift
func openSSHProject(host: String, remotePath: String, tabManager preferredTabManager: TabManager? = nil) {
    let identity: SSHProjectIdentity
    do {
        identity = try SSHProjectIdentity(host: host, remotePath: remotePath)
    } catch {
        presentSSHProjectOpenError(error)
        return
    }

    SSHProjectRegistryClient.upsert(identity: identity) { [weak self] result in
        guard let self else { return }
        do {
            let projectResult = try result.get()
            let metadata = try SSHProjectRegistryClient.workspaceMetadata(identity: identity, result: projectResult)
            let target: TabManager
            if let preferredTabManager {
                target = preferredTabManager
            } else if let existing = self.preferredMainWindowContextForWorkspaceCreation(debugSource: "openSSHProject")?.tabManager {
                target = existing
            } else {
                let windowID = self.createMainWindow()
                guard let created = self.tabManagerFor(windowId: windowID) else {
                    throw NSError(domain: "cmux.sshProject", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "Could not create a window for the SSH project."
                    ])
                }
                target = created
            }
            _ = target.addWorkspace(title: metadata.displayName, sshProject: metadata, select: true)
        } catch {
            self.presentSSHProjectOpenError(error)
        }
    }
}

private func presentSSHProjectOpenError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = String(localized: "openProject.ssh.error.title", defaultValue: "Could not open SSH project")
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
    alert.runModal()
}
```

- [ ] **Step 3: Route menu and palette to the new opener**

In `Sources/cmuxApp.swift`, change the File menu `Open Folder...` action:

```swift
AppDelegate.shared?.showProjectOpenPanel()
```

In `Sources/ContentView.swift`, change the `palette.openFolder` handler to:

```swift
registry.register(commandId: "palette.openFolder") {
    DispatchQueue.main.async {
        AppDelegate.shared?.showProjectOpenPanel(tabManager: tabManager)
    }
}
```

Keep `showOpenFolderPanel()` for Local Folder mode, services, and any call site that explicitly needs the old local folder picker.

- [ ] **Step 4: Add localized strings**

Add these keys to `Resources/Localizable.xcstrings` with English and Japanese entries, matching existing file format:

```text
openProject.title = Open Project
openProject.mode.local = Local Folder
openProject.mode.ssh = SSH Project
openProject.local.title = Open a local folder
openProject.local.detail = Choose a folder on this Mac.
openProject.ssh.title = Open an SSH project
openProject.ssh.host = Host
openProject.ssh.manualHost = Host alias
openProject.ssh.remotePath = /home/dev/project
openProject.ssh.invalid = Enter an SSH host and an absolute remote path.
openProject.ssh.error.title = Could not open SSH project
common.cancel = Cancel
common.open = Open
common.ok = OK
```

If `common.cancel`, `common.open`, or `common.ok` already exist, reuse the existing keys and do not duplicate them.

- [ ] **Step 5: Add new UI file to Xcode project**

Update `GhosttyTabs.xcodeproj/project.pbxproj` to include `Sources/SSHProjectOpenView.swift` in the app target source build phase.

- [ ] **Step 6: Verify UI compiles in CI/VM**

CI/VM command:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' build
```

Expected: build succeeds.

- [ ] **Step 7: Commit opener UI**

```bash
git add Sources/SSHProjectOpenView.swift Sources/AppDelegate.swift Sources/ContentView.swift Sources/cmuxApp.swift Resources/Localizable.xcstrings GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "Add SSH project opener UI"
```

---

### Task 7: Socket Coverage And Ad Hoc SSH Non-Regression

**Files:**
- Modify: `Sources/TerminalController.swift`
- Create: `tests_v2/test_ssh_project_workspace_metadata.py`
- Modify: `tests_v2/test_ssh_remote_cli_metadata.py`

- [ ] **Step 1: Add socket-create support for pre-upserted SSH project metadata**

In `Sources/TerminalController.swift`, extend `workspace.create` parsing:

```swift
let sshProjectMetadata: SSHProjectWorkspaceMetadata?
if let rawSSHProject = params["ssh_project"] as? [String: Any] {
    guard let host = rawSSHProject["host"] as? String,
          let remotePath = rawSSHProject["remote_path"] as? String,
          let projectID = rawSSHProject["project_id"] as? String else {
        return .err(code: "invalid_params", message: "ssh_project requires host, remote_path, and project_id", data: nil)
    }
    do {
        let identity = try SSHProjectIdentity(host: host, remotePath: remotePath)
        sshProjectMetadata = SSHProjectWorkspaceMetadata(
            projectID: projectID,
            groupID: (rawSSHProject["group_id"] as? String) ?? "default",
            identity: identity,
            displayName: (rawSSHProject["display_name"] as? String) ?? URL(fileURLWithPath: identity.remotePath).lastPathComponent
        )
    } catch {
        return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
    }
} else {
    sshProjectMetadata = nil
}
```

In the `v2MainSync` creation block:

```swift
let ws: Workspace
if let sshProjectMetadata {
    ws = tabManager.addWorkspace(
        title: title ?? sshProjectMetadata.displayName,
        sshProject: sshProjectMetadata,
        select: shouldFocus,
        eagerLoadTerminal: !shouldFocus
    )
} else {
    ws = tabManager.addWorkspace(
        title: title,
        workingDirectory: cwd,
        initialTerminalCommand: layoutNode == nil ? initialCommand : nil,
        initialTerminalEnvironment: layoutNode == nil ? initialEnv : [:],
        select: shouldFocus,
        eagerLoadTerminal: !shouldFocus,
        inferProjectRemote: inferProjectRemote
    )
}
```

- [ ] **Step 2: Write socket metadata regression**

Create `tests_v2/test_ssh_project_workspace_metadata.py`:

```python
#!/usr/bin/env python3
"""Regression: SSH project workspaces expose remote project metadata."""

import json
import os
import subprocess
import sys
import time

from cmux_test_client import CmuxClient


def _run_cli_json(cli, args):
    output = subprocess.check_output([cli, "--json", *args], text=True)
    return json.loads(output)


def _must(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    cli = os.environ["CMUX_CLI"]
    client = CmuxClient.from_env()
    stamp = str(int(time.time()))
    remote_path = f"/tmp/cmux-ssh-project-{stamp}"

    payload = _run_cli_json(cli, [
        "rpc",
        "workspace.create",
        json.dumps({
            "title": "ssh-project-test",
            "ssh_project": {
                "host": "devbox",
                "remote_path": remote_path,
                "project_id": "ssh-test-project",
                "group_id": "default",
                "display_name": "cmux-ssh-project-test",
            },
        }),
    ])
    workspace_id = payload.get("workspace_id")
    _must(workspace_id, f"workspace.create missing workspace_id: {payload}")

    row = client.workspace_status(workspace_id)
    remote = row.get("remote") or {}
    project = remote.get("project") or {}
    _must(project.get("id") == "ssh-test-project", f"project id mismatch: {project}")
    _must(project.get("group_id") == "default", f"group mismatch: {project}")
    _must(project.get("host") == "devbox", f"host mismatch: {project}")
    _must(project.get("remote_path") == remote_path, f"remote_path mismatch: {project}")
    _must(project.get("uri") == f"ssh://devbox{remote_path}", f"uri mismatch: {project}")

    print("PASS: SSH project workspace exposes remote project metadata")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise
```

If `CmuxClient.workspace_status` does not exist, use the existing helper pattern in nearby `tests_v2` files to call `workspace.list` or `workspace.remote.status` and find the row by `workspace_id`.

- [ ] **Step 3: Extend ad hoc SSH metadata test**

In `tests_v2/test_ssh_remote_cli_metadata.py`, after the first `cmux ssh` remote payload assertions, add:

```python
_must("project" not in remote, f"ad hoc cmux ssh workspace must not expose SSH project metadata: {remote}")
```

This protects the design decision that `cmux ssh host` remains ad hoc unless opened through SSH Project UI.

- [ ] **Step 4: Verify socket tests in CI/VM**

CI/VM commands:

```bash
python3 tests_v2/test_ssh_project_workspace_metadata.py
python3 tests_v2/test_ssh_remote_cli_metadata.py
```

Expected: both PASS in the configured cmux test environment.

- [ ] **Step 5: Commit socket coverage**

```bash
git add Sources/TerminalController.swift tests_v2/test_ssh_project_workspace_metadata.py tests_v2/test_ssh_remote_cli_metadata.py
git commit -m "Cover SSH project workspace metadata"
```

---

### Task 8: Build, Reload, And Final Verification

**Files:**
- Modify only if earlier tasks revealed missing docs or localization entries:
  `docs/remote-daemon-spec.md`, `web/messages/en.json`, `web/app/[locale]/docs/ssh/page.tsx`

- [ ] **Step 1: Run focused CI/VM test set**

CI/VM commands:

```bash
cd daemon/remote && go test ./cmd/cmuxd-remote -run 'TestProjectRegistry|TestProjectRPC|TestHelloAdvertisesProjectRegistryCapability' -count=1
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -only-testing:cmuxTests/SSHProjectIdentityTests -only-testing:cmuxTests/SSHProjectRegistryClientTests -only-testing:cmuxTests/TabManagerSSHProjectWorkspaceTests test
python3 tests_v2/test_ssh_project_workspace_metadata.py
python3 tests_v2/test_ssh_remote_cli_metadata.py
```

Expected: all PASS in CI/VM.

- [ ] **Step 2: Build tagged Debug app**

Repository policy requires `reload.sh --tag` after code changes:

```bash
./scripts/reload.sh --tag ssh-project-source
```

Expected: build succeeds and prints an `App path:` line.

- [ ] **Step 3: Manual UI smoke in tagged app**

Use the tagged app from the `App path:` output.

Smoke flow:

1. Open `File -> Open Folder...`.
2. Select `Local Folder`.
3. Verify the old local folder picker still opens.
4. Open `File -> Open Folder...` again.
5. Select `SSH Project`.
6. Choose an explicit SSH config host alias.
7. Enter an absolute remote path that exists on that host.
8. Press Open.
9. Verify the workspace title uses the project display name.
10. Verify the remote row appears in the sidebar.
11. Open a browser pane and confirm `localhost` routes through the remote proxy.

- [ ] **Step 4: Inspect git diff for unrelated changes**

```bash
git status --short
git diff --stat
```

Expected: only files listed in this plan changed.

- [ ] **Step 5: Commit final docs or localization fixes**

If Task 8 modified docs or localization after the smoke pass:

```bash
git add docs/remote-daemon-spec.md web/messages/en.json web/app/[locale]/docs/ssh/page.tsx Resources/Localizable.xcstrings
git commit -m "Document SSH project opener"
```

Skip this commit if there were no final docs/localization edits.
