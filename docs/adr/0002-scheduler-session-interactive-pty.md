# Une session `claude` interactive dans un PTY, pas `claude -p`

Le runner headless lance `claude` en **session interactive** dans un pseudo-terminal
120×40 qu'il possède, enregistre tout le flux dans `logs/<runID>.tty`, et la GUI le rejoue.
On a écarté `claude -p`, la voie évidente pour un process sans surveillance, pour deux
raisons : Julien veut **voir le rendu CLI** du run, comme dans Claude Launcher ; et en
interactif les **MCP de plugin sont gardés**, alors qu'en `-p` le plugin Sentry disparaît
derrière le connecteur claude.ai (réglé hors dépôt par `deniedMcpServers`, mais `-p` reste
le mode où ce masquage a été vu).

## Consequences

Mesuré le 2026-10-30 sur `claude` 2.1.314 (sonde `pty.fork`, 120×40) :

- **Dossier approuvé obligatoire.** Dans un dossier jamais approuvé, la session reste
  bloquée sur « Do you trust this folder? ». Le runner détecte ce dialogue dans le flux et
  échoue en quelques secondes : « dossier non approuvé par Claude : ouvrez-le une fois
  dans Claude Launcher ».
- **La fin n'est pas spontanée.** Une session interactive reste au prompt après sa
  réponse. Le runner injecte par `--settings` un hook `Stop` qui pose un marqueur, puis
  écrit `/exit\r` dans le PTY. Sans marqueur, c'est le délai de la planification qui tue
  le groupe de process (`timedOut`).
- **Pas de résultat JSON** : ni coût, ni nombre de tours, ni `--max-budget-usd` (réservés à
  `-p`). Le statut `completed` dit seulement que la session a rendu la main.
- **Personne devant l'écran** : `--permission-mode dontAsk` imposé (un prompt de
  permission figerait la session) et `CLAUDE_CODE_AUTO_CONNECT_IDE=false` (sinon un
  `openDiff` bloquant ouvrirait la fenêtre de revue de Potof sans personne pour répondre).
- **Reprise possible** : le runner impose `--session-id`, donc Claude Launcher rouvre la
  conversation par `claude --resume <sessionID>`.
- **Contrôle des MCP par `claude mcp list`**, lancé avant la session dans le même shell de
  login : c'est la liste qui reflète ce qu'aura une session interactive.
