#!/usr/bin/env node
// goal-statusline.js — Claude Code statusline for claude-goal.
//
// Shows, when a goal is active and claimed by THIS session:
//   ⎯ /goal:<3-word-slug> i<iteration>  │  <model>  │  <current task>  │  <dir>  <context-bar>
//
// Wire it in settings.json:
//   "statusLine": { "type": "command", "command": "node .claude/scripts/goal-statusline.js" }
//
// Detection is claim-scoped: it reads .claude/goals/session-<session_id>.goal (written at
// goal start) and shows only the goal THIS CLI owns — so parallel CLIs each show their own.
// Fails silent on any error (never breaks the statusline).

const fs = require('fs');
const path = require('path');
const os = require('os');

let input = '';
// Timeout guard: if stdin doesn't close within 3s (pipe issues on Windows/Git Bash), exit silently.
const stdinTimeout = setTimeout(() => process.exit(0), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => (input += chunk));
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const model = data.model?.display_name || 'Claude';
    const dir = data.workspace?.current_dir || process.cwd();
    const session = data.session_id || '';
    const remaining = data.context_window?.remaining_percentage;

    // ---- Context window bar (shows USED %, normalized to the usable window) ----
    // Claude Code reserves ~16.5% for the auto-compact buffer; normalize so 100% = that point.
    const AUTO_COMPACT_BUFFER_PCT = 16.5;
    let ctx = '';
    if (remaining != null) {
      const usableRemaining = Math.max(
        0,
        ((remaining - AUTO_COMPACT_BUFFER_PCT) / (100 - AUTO_COMPACT_BUFFER_PCT)) * 100
      );
      const used = Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));
      const filled = Math.floor(used / 10);
      const bar = '█'.repeat(filled) + '░'.repeat(10 - filled);
      if (used < 50) ctx = ` \x1b[32m${bar} ${used}%\x1b[0m`;
      else if (used < 65) ctx = ` \x1b[33m${bar} ${used}%\x1b[0m`;
      else if (used < 80) ctx = ` \x1b[38;5;208m${bar} ${used}%\x1b[0m`;
      else ctx = ` \x1b[5;31m💀 ${bar} ${used}%\x1b[0m`;
    }

    // ---- Current task (from the in-progress to-do, if any) ----
    let task = '';
    const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
    const todosDir = path.join(claudeDir, 'todos');
    if (session && fs.existsSync(todosDir)) {
      try {
        const files = fs
          .readdirSync(todosDir)
          .filter((f) => f.startsWith(session) && f.includes('-agent-') && f.endsWith('.json'))
          .map((f) => ({ name: f, mtime: fs.statSync(path.join(todosDir, f)).mtime }))
          .sort((a, b) => b.mtime - a.mtime);
        if (files.length > 0) {
          const todos = JSON.parse(fs.readFileSync(path.join(todosDir, files[0].name), 'utf8'));
          const inProgress = todos.find((t) => t.status === 'in_progress');
          if (inProgress) task = inProgress.activeForm || '';
        }
      } catch (e) {
        /* silent */
      }
    }

    // ---- Active goal tag (only the goal THIS session claimed) ----
    let goalTag = '';
    try {
      const goalsDir = path.join(dir, '.claude', 'goals');
      let matchedGoal = null;
      if (session) {
        const claimFile = path.join(goalsDir, `session-${session}.goal`);
        if (fs.existsSync(claimFile)) {
          const claimedId = fs.readFileSync(claimFile, 'utf8').trim();
          const gf = path.join(goalsDir, `goal-${claimedId}.json`);
          if (fs.existsSync(gf)) {
            matchedGoal = { id: claimedId, ...JSON.parse(fs.readFileSync(gf, 'utf8')) };
          }
        }
      }
      if (matchedGoal && matchedGoal.status === 'active') {
        const obj = (matchedGoal.objective || '').replace(/[^a-zA-Z0-9 ]/g, '').trim();
        const slug = obj.split(/\s+/).slice(0, 3).join('-').toLowerCase() || matchedGoal.id;
        const iters = matchedGoal.budget?.used ?? 0;
        goalTag = `\x1b[35m⎯ /goal:${slug} i${iters}\x1b[0m │ `;
      }
    } catch (e) {
      /* silent */
    }

    // ---- Output ----
    const dirname = path.basename(dir);
    if (task) {
      process.stdout.write(`${goalTag}\x1b[2m${model}\x1b[0m │ \x1b[1m${task}\x1b[0m │ \x1b[2m${dirname}\x1b[0m${ctx}`);
    } else {
      process.stdout.write(`${goalTag}\x1b[2m${model}\x1b[0m │ \x1b[2m${dirname}\x1b[0m${ctx}`);
    }
  } catch (e) {
    // Silent fail — never break the statusline.
  }
});
