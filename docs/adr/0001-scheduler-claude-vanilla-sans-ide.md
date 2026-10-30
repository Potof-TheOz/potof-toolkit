# Le scheduler lance `claude` vanilla dans un dossier, sans IDE ni Superset

Le 4ᵉ outil lançait des agents Superset (`superset agents create`, workspaces, worktrees).
Superset a été abandonné le 2026-09-07 au profit d'Orca : la CLI `superset` n'existe plus et
l'outil était hors service. On a décidé que le scheduler lance **`claude` vanilla** dans un
**dossier** choisi, après un **préscript** shell facultatif, sans aucun IDE intermédiaire.
Raison : un outil local ne doit pas dépendre d'un IDE tiers qu'on peut abandonner, et
`claude` suffit à tout ce que faisaient les planifications.

## Considered Options

- **IDE au choix (Orca ou Superset)** : écarté le 2026-10-30. On aurait refait un
  adaptateur par IDE, pour un IDE déjà mort et un autre dont les automations existent déjà.
- **Piloter les automations Orca depuis Potof** : écarté. Les automations Orca (dont le
  rapport Sentry quotidien) restent à côté et vivent leur vie ; Potof ne les lit ni ne les
  modifie.

## Consequences

- Tout le code Superset part : `SupersetCLI`, `AgentPresence`, `TargetPicker`, host
  service, résolution de workspace, garde « agent vif », `git reset --hard` du runner. La
  mise à jour du dossier, s'il en faut une, passe par le préscript.
- `schedules.json` passe en **v2**. Les 3 planifications v1 (Superset, déjà recréées dans
  Orca) sont **supprimées** : la GUI réécrit un fichier v2 vide quand elle trouve un v1.
  Rien n'est migré.
- Plus d'isolation par worktree : deux planifications sur le même dossier partagent son
  arbre de travail. Le verrou n'exclut que deux runs d'**une même** planification.
