-- aggrometer/version.lua
--
-- Single source of truth for the AggroMeter version. Semantic versioning
-- per https://semver.org — MAJOR.MINOR.PATCH.
--
-- BUMP POLICY (see decisions/0008-semantic-versioning.md):
--   * MAJOR — breaking changes to the wire protocol, slash-command surface,
--             or config file schema in a way that older peers/configs can't
--             interoperate or load.
--   * MINOR — new user-facing functionality, new wire protocol messages
--             that older peers safely ignore, additive config fields with
--             safe defaults.
--   * PATCH — bug fixes, internal refactors, doc/runbook changes that
--             don't alter user-observable behavior.
--
-- WHEN YOU BUMP:
--   1. Edit MAJOR / MINOR / PATCH below.
--   2. Move the matching CHANGELOG.md entries from `[Unreleased]` into a
--      new `[X.Y.Z] - YYYY-MM-DD` section.
--   3. Commit, then `git tag vX.Y.Z` and push the tag.
-- See runbooks/cut-a-release.md for the full ritual.

local M = {}

M.MAJOR = 1
M.MINOR = 0
M.PATCH = 0

-- Pre-release tag — leave empty ('') for a stable release. Set to e.g.
-- 'rc.1' or 'dev' if you need to mark an in-progress build. The string()
-- helper appends it as `-<tag>` per semver.
M.PRERELEASE = ''

-- Render `1.0.0` or `1.0.0-rc.1`.
function M.string()
    local s = string.format('%d.%d.%d', M.MAJOR, M.MINOR, M.PATCH)
    if M.PRERELEASE and M.PRERELEASE ~= '' then
        s = s .. '-' .. M.PRERELEASE
    end
    return s
end

-- Render `v1.0.0` for UI display + chat. Matches the EQXPInfo footer
-- convention adopted as a project standard.
function M.display()
    return 'v' .. M.string()
end

return M
