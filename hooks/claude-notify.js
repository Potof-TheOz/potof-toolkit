#!/usr/bin/env node
'use strict';

/**
 * Notifications macOS pour Claude Code.
 *
 * Deux modes :
 *   1. Mode hook (défaut) : appelé par Claude Code avec le JSON de l'event sur
 *      stdin. Envoie une notification macOS via terminal-notifier — sauf si
 *      l'onglet iTerm2 de cette session est déjà au premier plan (anti-spam).
 *   2. Mode focus : `claude-notify.js focus <uuid>` — lancé au clic sur la
 *      notification, met iTerm2 au premier plan sur l'onglet exact de la session.
 *
 * Enregistré dans ~/.claude/settings.json sous les events Notification et Stop.
 */

const path = require('path');
const { execFileSync } = require('child_process');

const ITERM_BUNDLE = 'com.googlecode.iterm2';

// UUID de la session iTerm2 courante (format de ITERM_SESSION_ID : "w0t1p0:UUID")
function sessionUuid() {
  return (process.env.ITERM_SESSION_ID || '').split(':').pop() || '';
}

function osascript(script) {
  return execFileSync('osascript', ['-e', script], {
    encoding: 'utf8',
    timeout: 5000,
  }).trim();
}

// ---------------------------------------------------------------------------
// Mode focus : ramène iTerm2 au premier plan sur l'onglet de la session `uuid`.
// ---------------------------------------------------------------------------
function focus(uuid) {
  if (!uuid) return;
  const script = `
    tell application "iTerm2"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if (id of s) is "${uuid}" then
              select w
              tell t to select
              tell s to select
              return
            end if
          end repeat
        end repeat
      end repeat
    end tell`;
  try {
    osascript(script);
  } catch (_) {
    // À défaut de retrouver l'onglet, on active au moins iTerm2.
    try {
      osascript(`tell application "iTerm2" to activate`);
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Anti-spam : true si l'utilisateur regarde déjà cette session iTerm2.
// ---------------------------------------------------------------------------
function isAlreadyFocused(uuid) {
  if (!uuid) return false;
  let frontApp = '';
  try {
    frontApp = osascript(
      'tell application "System Events" to get bundle identifier of first application process whose frontmost is true'
    );
  } catch (_) {
    return false; // en cas de doute, on notifie
  }
  if (frontApp !== ITERM_BUNDLE) return false;

  try {
    const current = osascript(
      'tell application "iTerm2" to get id of current session of current window'
    );
    return current === uuid;
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Mode hook : lit le JSON de stdin et envoie la notification.
// ---------------------------------------------------------------------------
function readStdin() {
  try {
    return require('fs').readFileSync(0, 'utf8');
  } catch (_) {
    return '';
  }
}

// ---------------------------------------------------------------------------
// Canal Potof Toolkit : quand la session tourne dans le terminal embarqué de
// l'app (POTOF_SESSION_ID présent), on append une ligne JSON dans un fichier que
// l'app surveille. L'app pose alors sa propre bannière + cloche + Dock. Voir
// potof-toolkit/docs/NOTIFICATIONS.md.
// ---------------------------------------------------------------------------
function appendPotofChannel(obj) {
  try {
    const os = require('os');
    const fs = require('fs');
    const dir = path.join(os.homedir(), 'Library', 'Application Support', 'PotofToolkit');
    fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(path.join(dir, 'notifications.jsonl'), JSON.stringify(obj) + '\n');
  } catch (_) {
    // Ne jamais bloquer Claude Code.
  }
}

function runHook() {
  let data = {};
  try {
    data = JSON.parse(readStdin() || '{}');
  } catch (_) {
    data = {};
  }

  const event = data.hook_event_name || '';
  const message = data.message || '';
  const cwd = data.cwd || process.cwd();
  const project = path.basename(cwd) || 'projet';

  // Session dans le terminal embarqué de Potof Toolkit : l'app gère la notif.
  // On écrit dans le canal et on saute terminal-notifier (pas de double bannière).
  const potofSid = process.env.POTOF_SESSION_ID;
  if (potofSid) {
    appendPotofChannel({
      potofSessionId: potofSid,
      event,
      notificationType: data.notification_type || null,
      message,
      // Sur un Stop, Claude peut poser une question : on transmet son dernier
      // message pour que l'app distingue « question » de « tâche terminée ».
      lastMessage: data.last_assistant_message || null,
      cwd,
      ts: Date.now(),
    });
    return;
  }

  const uuid = sessionUuid();

  // Ne pas déranger si l'onglet est déjà à l'écran.
  if (isAlreadyFocused(uuid)) return;

  let title;
  let body;
  let sound;
  if (event === 'Stop') {
    title = `✅ Claude a terminé — ${project}`;
    body = `Tâche terminée dans ${project}`;
    sound = 'Glass';
  } else {
    // Notification (permission / idle / needs input) ou fallback
    title = `⏳ Claude attend — ${project}`;
    body = message || 'Claude a besoin de toi';
    sound = 'Ping';
  }

  const args = ['-title', title, '-message', body, '-sound', sound];

  if (uuid) {
    // Regroupe par session + type d'event : deux notifs du même type se
    // remplacent (pas d'empilement), mais un ✅ "terminé" n'écrase pas un
    // ⏳ "attend" de la même session. Clic → focus de l'onglet.
    args.push('-group', `${uuid}-${event || 'notif'}`);
    args.push('-execute', `${process.execPath} ${__filename} focus ${uuid}`);
  } else {
    // Hors iTerm2 : au clic, on active simplement l'app.
    args.push('-activate', ITERM_BUNDLE);
  }

  try {
    execFileSync('terminal-notifier', args, { timeout: 5000 });
  } catch (_) {
    // terminal-notifier absent ou en échec : on échoue silencieusement pour ne
    // jamais bloquer Claude Code.
  }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------
if (process.argv[2] === 'focus') {
  focus(process.argv[3]);
} else {
  runHook();
}
