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

## Current Scaffold

Sprint 1 includes v0.13.2-shaped Swift Codable models for the stable ACP schema, typed JSON-RPC request/response dispatch, typed `session/update` streaming, local `initialize`, `session/new`, `session/prompt`, and `session/cancel` client APIs, and a single local chat surface.

Permission requests, diff-specific UI, session browsing, SSH-backed live sessions, and admin surfaces remain later-sprint work.
