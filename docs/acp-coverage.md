# ACP Coverage

This file tracks which ACP methods and events Talaria handles.

## MVP Required

- `initialize`
- `session/new`
- `session/load`
- `session/prompt`
- `session/cancel`
- text deltas
- reasoning or thinking deltas
- tool start, progress, and completion events
- permission requests
- diff payloads

## Current Coverage

Sprint 2 includes v0.13.2-shaped Swift Codable models for the stable ACP schema, typed JSON-RPC request/response dispatch, typed `session/update` streaming, local `initialize`, `session/new`, `session/prompt`, and `session/cancel` client APIs.

Talaria now handles agent-initiated `session/request_permission` requests with typed permission outcomes, renders tool-call diff payloads in chat, renders markdown text bubbles, surfaces slash commands from `available_commands_update`, and shows local turn status with elapsed time plus the session git branch.

Session browsing, SSH-backed live sessions, and admin surfaces remain later-sprint work.
