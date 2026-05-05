# SSH Project Source Of Truth Design

## Goal

Make SSH projects creatable from the cmux UI, with the remote host as the source of truth for project and group membership. A user should not need to write `cmux.json` or run `cmux ssh` to create a persistent SSH project.

## Decisions

1. An SSH project is identified by SSH host alias plus absolute remote path.
2. The canonical structured identity is:

   ```json
   {
     "transport": "ssh",
     "host": "devbox",
     "remotePath": "/home/dev/myrepo"
   }
   ```

3. The canonical display URI is `ssh://devbox/home/dev/myrepo`.
4. The UI may accept `devbox:/home/dev/myrepo` as a shortcut, but stored project identity must keep `transport`, `host`, and `remotePath` as separate fields.
5. Remote project registry state lives on the remote host. Local cmux may cache recent projects for convenience, but the remote registry wins on reconnect and refresh.

## Scope

First implementation phase:

1. Add a UI path from `Open Folder...` to create or open an SSH project.
2. Add remote daemon RPCs for listing, reading, and upserting remote projects.
3. Store project and group registry data under `~/.cmux/projects` on the remote host.
4. Create remote workspaces from that registry, with terminals starting in the configured remote path.
5. Keep existing `cmux ssh` behavior working.

Out of scope for the first phase:

1. Full durable terminal replay across local app reinstall or different local machines.
2. A multi-user permission model for shared remote hosts.
3. Automatic migration of existing local `cmux.json` project remotes into the remote registry.

## UI

`Open Folder...` becomes a project opener with two modes:

1. `Local Folder`: the existing local `NSOpenPanel` flow.
2. `SSH Project`: a form that selects an SSH config host alias and accepts an absolute remote path.

The SSH mode should show hosts from `~/.ssh/config` explicit `Host` aliases, matching the current project-remote restriction. It should also allow manual entry so a user can paste a valid alias after updating SSH config.

When the user submits `host + remotePath`:

1. cmux connects to or prepares the remote daemon for `host`.
2. cmux sends `project.upsert`.
3. cmux creates a remote workspace for the returned project.
4. The first terminal starts in `remotePath`.

The command palette `Open Folder...` should use the same opener so the menu and palette do not diverge.

## Remote Registry

Store registry files under:

```text
~/.cmux/projects/index.json
~/.cmux/projects/<project-id>/project.json
~/.cmux/projects/<project-id>/groups.json
```

`project-id` is a stable hash of normalized `transport`, lowercased `host`, and normalized absolute `remotePath`. It is not user-editable.

`project.json` contains:

```json
{
  "schemaVersion": 1,
  "id": "stable-project-id",
  "transport": "ssh",
  "host": "devbox",
  "remotePath": "/home/dev/myrepo",
  "displayName": "myrepo",
  "createdAt": "2026-05-05T00:00:00Z",
  "updatedAt": "2026-05-05T00:00:00Z"
}
```

`groups.json` contains a default group initially:

```json
{
  "schemaVersion": 1,
  "groups": [
    {
      "id": "default",
      "name": "Default",
      "createdAt": "2026-05-05T00:00:00Z",
      "updatedAt": "2026-05-05T00:00:00Z"
    }
  ]
}
```

The first phase only needs the default group, but the registry shape leaves room for user-created groups without changing project identity.

Writes must be atomic: write to a temporary file in the same directory, `fsync` when practical, then rename.

## Remote Daemon RPC

Add RPC methods to `cmuxd-remote`:

1. `project.list`
   Returns projects known to the remote registry.

2. `project.get`
   Params: `project_id` or `host + remote_path`.
   Returns project metadata and groups.

3. `project.upsert`
   Params: `host`, `remote_path`, optional `display_name`.
   Creates the project if missing, otherwise updates `updatedAt` and returns the existing project.

4. `project.groups.list`
   Params: `project_id`.
   Returns groups for the project.

The local app should treat `not_found`, invalid path, permission, and malformed registry responses as user-visible errors.

## Workspace Behavior

Opening an SSH project creates a local workspace attached to the remote project identity. The workspace model should store:

1. remote host
2. remote path
3. remote project id
4. selected group id, initially `default`

The terminal startup script should `cd` into the remote path before handing off to the user's interactive shell. If the path no longer exists, the remote daemon should reject `project.upsert` or `project.get` with a clear error before workspace creation.

Browser panes in this workspace keep using the existing remote proxy endpoint. `localhost` means the remote host, not the local Mac.

Existing `cmux ssh host` continues to create an ad hoc SSH workspace. It does not implicitly create a project unless the user opens it through the SSH Project UI.

## Local Cache

Local cmux may store recent SSH projects for faster UI suggestions, but each entry must include enough information to refresh from the remote daemon:

```json
{
  "transport": "ssh",
  "host": "devbox",
  "remotePath": "/home/dev/myrepo",
  "projectId": "stable-project-id",
  "lastOpenedAt": "2026-05-05T00:00:00Z"
}
```

If the remote daemon returns a different project record than the local cache, the UI updates to the remote record. If the remote record is missing, the UI asks whether to recreate it instead of silently using cached data.

## Error Handling

1. Missing SSH host alias: show an error explaining that SSH projects require an explicit `Host` alias in `~/.ssh/config`.
2. Non-absolute remote path: reject before RPC with a local validation error.
3. Remote path missing or inaccessible: remote daemon returns `invalid_params` or `permission_denied` with the path in the error detail.
4. Registry read failure: show the registry path and the daemon error detail.
5. Registry write failure: do not create a local-only project fallback.
6. Remote daemon unavailable: offer retry after host preparation fails.

## Testing

Do not add source-text tests. Behavioral coverage should include:

1. Unit tests in `daemon/remote` for project id normalization, atomic registry writes, `project.upsert`, `project.get`, and `project.list`.
2. A Swift unit seam for SSH project URI parsing and validation, including `ssh://devbox/home/dev/myrepo` and `devbox:/home/dev/myrepo`.
3. A socket or app-level test that opens an SSH project through the new workspace path and verifies the workspace remote metadata contains host, remote path, project id, and default group id.
4. A remote daemon integration test that rejects relative paths and missing paths.
5. A regression that existing `cmux ssh host` still creates an ad hoc remote workspace without creating a project registry entry.

Local GUI/E2E tests should run in CI or the VM according to the repository testing policy.
