import SwiftUI

/// Sélecteur de cible — **lot L4bis**.
///
/// ⭐ On saisit les **COORDONNÉES** du workspace (projet + nom), jamais son `workspaceID` :
/// un workspace supprimé puis recréé garde son nom mais **change d'id**, et la résolution
/// se refait à chaque run. Le sélecteur ci-dessous ne fait donc que **remplir le nom** à
/// partir de la liste — il ne mémorise aucun identifiant.
///
/// Conséquence heureuse : désigner un workspace qui **n'existe pas encore** est légitime,
/// le premier run le crée. D'où les deux modes du sélecteur (choisir / créer).
struct TargetPicker: View {

    @Binding var target: Target

    init(target: Binding<Target>) {
        self._target = target
    }

    @State private var projects: [SupersetProject] = []
    @State private var workspaces: [SupersetWorkspace] = []
    @State private var projectsState: LoadState = .loading
    @State private var workspacesState: LoadState = .loading
    /// Vrai quand l'utilisateur veut créer un workspace plutôt qu'en réutiliser un.
    @State private var creatingWorkspace = false

    private enum LoadState: Equatable { case loading, loaded, failed }

    private enum Mode: String, CaseIterable, Identifiable {
        case permanent = "Workspace permanent"
        case fresh = "Nouveau workspace à chaque run"
        var id: String { rawValue }
    }

    private var mode: Mode {
        switch target {
        case .permanentWorkspace: return .permanent
        case .freshWorkspace:     return .fresh
        }
    }

    /// Workspaces du projet sélectionné, triés — la liste brute couvre tous les projets.
    private var projectWorkspaces: [SupersetWorkspace] {
        workspaces
            .filter { $0.projectId == target.projectID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: Binding(get: { mode }, set: switchMode)) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            projectRow

            switch target {
            case .permanentWorkspace(_, _, let workspaceName, let branch, let baseBranch, let refresh):
                permanentControls(workspaceName: workspaceName, branch: branch,
                                  baseBranch: baseBranch, refresh: refresh)
            case .freshWorkspace(_, _, let namePrefix, let branchPrefix, let baseBranch):
                freshControls(namePrefix: namePrefix, branchPrefix: branchPrefix,
                              baseBranch: baseBranch)
            }
        }
        .onAppear {
            load()
            // Un nom déjà saisi qui ne correspond à aucun workspace connu = mode création.
            if case .permanentWorkspace(_, _, let name, _, _, _) = target, !name.isEmpty {
                creatingWorkspace = !workspaces.contains { $0.name == name }
            }
        }
    }

    // MARK: - Projet

    @ViewBuilder
    private var projectRow: some View {
        HStack(spacing: 8) {
            label("Projet")
            switch projectsState {
            case .loading:
                ProgressView().controlSize(.small)
                Text("lecture des projets…").font(.system(size: 11)).foregroundStyle(.secondary)
            case .failed:
                // Ne JAMAIS bloquer sur une liste illisible : le host service peut être
                // éteint alors que la planification est parfaitement valide.
                Text("Liste indisponible (Superset injoignable) — projet conservé : "
                     + (target.projectName.isEmpty ? target.projectID : target.projectName))
                    .font(.system(size: 11)).foregroundStyle(.orange)
            case .loaded:
                Picker("", selection: Binding(get: { target.projectID }, set: setProject)) {
                    if !projects.contains(where: { $0.id == target.projectID }) {
                        Text(target.projectID.isEmpty ? "— choisir —" : target.projectName)
                            .tag(target.projectID)
                    }
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }
            Spacer()
        }
    }

    private func load() {
        guard projectsState == .loading else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = SupersetCLI.isInstalled()
            let foundProjects = installed ? SupersetCLI.projects() : []
            let foundWorkspaces = installed ? SupersetCLI.workspaces() : nil
            DispatchQueue.main.async {
                projects = foundProjects
                projectsState = foundProjects.isEmpty ? .failed : .loaded
                workspaces = foundWorkspaces ?? []
                workspacesState = foundWorkspaces == nil ? .failed : .loaded
                if case .permanentWorkspace(_, _, let name, _, _, _) = target, !name.isEmpty {
                    creatingWorkspace = !workspaces.contains { $0.name == name }
                }
            }
        }
    }

    // MARK: - Mutations

    private func setProject(id: String) {
        let name = projects.first { $0.id == id }?.name ?? target.projectName
        switch target {
        case .permanentWorkspace(_, _, _, _, let baseBranch, let refresh):
            // Changer de projet invalide le workspace choisi : on repart à vide plutôt
            // que de garder un nom qui n'existe pas dans le nouveau projet.
            target = .permanentWorkspace(projectID: id, projectName: name,
                                         workspaceName: "", branch: "",
                                         baseBranch: baseBranch, refreshWorktree: refresh)
            creatingWorkspace = false
        case .freshWorkspace(_, _, let namePrefix, let branchPrefix, let baseBranch):
            target = .freshWorkspace(projectID: id, projectName: name,
                                     namePrefix: namePrefix, branchPrefix: branchPrefix,
                                     baseBranch: baseBranch)
        }
    }

    private func switchMode(_ new: Mode) {
        switch new {
        case .permanent:
            target = .permanentWorkspace(
                projectID: target.projectID, projectName: target.projectName,
                workspaceName: "", branch: "", baseBranch: nil, refreshWorktree: true)
            creatingWorkspace = false
        case .fresh:
            target = .freshWorkspace(
                projectID: target.projectID, projectName: target.projectName,
                namePrefix: "", branchPrefix: "", baseBranch: nil)
        }
    }

    private func setPermanent(workspaceName: String? = nil, branch: String? = nil,
                              baseBranch: String?? = nil, refresh: Bool? = nil) {
        guard case .permanentWorkspace(let projectID, let projectName, let currentName,
                                       let currentBranch, let currentBase,
                                       let currentRefresh) = target else { return }
        target = .permanentWorkspace(
            projectID: projectID, projectName: projectName,
            workspaceName: workspaceName ?? currentName,
            branch: branch ?? currentBranch,
            baseBranch: baseBranch ?? currentBase,
            refreshWorktree: refresh ?? currentRefresh)
    }

    // MARK: - Workspace permanent

    private static let createTag = "\u{0}créer"

    @ViewBuilder
    private func permanentControls(workspaceName: String, branch: String,
                                   baseBranch: String?, refresh: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                label("Workspace")
                if workspacesState == .failed {
                    TextField("nom du workspace", text: Binding(
                        get: { workspaceName },
                        set: { setPermanent(workspaceName: $0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .accessibilityLabel("Nom du workspace")
                } else {
                    Picker("", selection: Binding(
                        get: { creatingWorkspace ? Self.createTag : workspaceName },
                        set: selectWorkspace
                    )) {
                        if !creatingWorkspace && workspaceName.isEmpty {
                            Text("— choisir —").tag("")
                        }
                        ForEach(projectWorkspaces) { workspace in
                            Text(workspace.name).tag(workspace.name)
                        }
                        Divider()
                        Text("Créer un nouveau workspace…").tag(Self.createTag)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .help("Le workspace est retrouvé par (projet, nom) à chaque run — jamais "
                          + "par son identifiant, qui change s'il est supprimé puis recréé.")
                }
                Spacer()
            }

            if workspacesState == .failed {
                Text("Liste des workspaces indisponible — saisie libre.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }

            // Nom et branche ne servent QU'À LA CRÉATION : sur un workspace existant ils
            // ne sont jamais relus. Les afficher quand même laisserait croire qu'on peut
            // changer la branche d'un workspace depuis ici.
            if creatingWorkspace || workspacesState == .failed {
                field("Nom du nouveau workspace", text: workspaceName,
                      help: "Créé au premier run s'il n'existe pas encore.") {
                    setPermanent(workspaceName: $0)
                }
                field("Branche", text: branch,
                      help: "Branche du worktree. Créée depuis la branche de base si elle "
                          + "n'existe pas.") {
                    setPermanent(branch: $0)
                }
            }

            Toggle(isOn: Binding(get: { refresh }, set: { setPermanent(refresh: $0) })) {
                Text("Rafraîchir le worktree avant chaque run").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .help("Le RUNNER fait le fetch et le reset --hard, jamais l'agent : l'agent "
                  + "trouve un arbre propre et n'a pas à savoir sur quoi il travaille. "
                  + "Aucun git clean — trop risqué sur un worktree permanent. "
                  + "Exige une branche de base.")

            // ⭐ UN SEUL champ « branche de base », quelles que soient les deux raisons de
            // le demander (créer le workspace, ou rafraîchir). Deux conditions
            // indépendantes affichaient le même champ en double, lié à la même valeur.
            // Son caractère obligatoire, lui, dépend du rafraîchissement : le
            // `reset --hard` a besoin d'une référence explicite, là où la création peut
            // retomber sur la branche de base du projet.
            if creatingWorkspace || workspacesState == .failed || refresh {
                baseBranchField(baseBranch, required: refresh) {
                    setPermanent(baseBranch: .some($0))
                }
            }
        }
    }

    private func selectWorkspace(_ tag: String) {
        if tag == Self.createTag {
            creatingWorkspace = true
            setPermanent(workspaceName: "", branch: "")
            return
        }
        creatingWorkspace = false
        // On recopie la branche du workspace choisi : si celui-ci est un jour supprimé,
        // le run saura le recréer à l'identique.
        let branch = projectWorkspaces.first { $0.name == tag }?.branch ?? ""
        setPermanent(workspaceName: tag, branch: branch)
    }

    // MARK: - Workspace neuf à chaque run

    private func freshControls(namePrefix: String, branchPrefix: String,
                               baseBranch: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Préfixe de nom", text: namePrefix,
                  help: "Le workspace s'appellera « <préfixe> AAAA-MM-JJ HH:mm ». "
                      + "Laissé vide, le nom de la planification est utilisé. "
                      + "C'est aussi sur ce préfixe que se compte le plafond de "
                      + "\(Target.freshWorkspaceCap) workspaces.",
                  placeholder: "défaut : le nom de la planification") { value in
                target = .freshWorkspace(
                    projectID: target.projectID, projectName: target.projectName,
                    namePrefix: value, branchPrefix: branchPrefix, baseBranch: baseBranch)
            }
            field("Préfixe de branche", text: branchPrefix,
                  help: "La branche s'appellera « <préfixe>-AAAA-MM-JJ-HHmm ». "
                      + "Laissé vide, le préfixe de nom est réutilisé (accents retirés).",
                  placeholder: "défaut : le préfixe de nom") { value in
                target = .freshWorkspace(
                    projectID: target.projectID, projectName: target.projectName,
                    namePrefix: namePrefix, branchPrefix: value, baseBranch: baseBranch)
            }
            baseBranchField(baseBranch) { value in
                target = .freshWorkspace(
                    projectID: target.projectID, projectName: target.projectName,
                    namePrefix: namePrefix, branchPrefix: branchPrefix,
                    baseBranch: value.isEmpty ? nil : value)
            }

            if !namePrefix.isEmpty {
                Text("Exemple : « \(Target.freshWorkspaceName(prefix: namePrefix, date: Date())) » "
                     + "· branche « \(Target.freshWorkspaceBranch(prefix: branchPrefix.isEmpty ? namePrefix : branchPrefix, date: Date())) »")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // Avertissement inline NON bloquant, avec des chiffres réels (§6.5).
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.system(size: 11))
                    .accessibilityHidden(true)
                Text("Un workspace par run consomme environ 2 Go de disque par exécution et "
                     + "change le dossier de travail : la mémoire de Claude Code étant indexée "
                     + "par ce dossier, elle repart de zéro à chaque fois. Au-delà de "
                     + "\(Target.freshWorkspaceCap) workspaces accumulés, le run est sauté "
                     + "plutôt que d'en créer un de plus — rien n'est supprimé "
                     + "automatiquement. Le workspace permanent est recommandé.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Fragments

    /// ⭐ `--base-branch` est **facultatif** côté CLI : *« Branch to fork from when `branch`
    /// does not exist (**defaults to project default**) »*. Laissé vide, le drapeau n'est
    /// pas émis du tout et Superset utilise la branche de base du projet. C'est le cas
    /// nominal, et l'UI doit le dire — sinon on croit devoir la saisir.
    private func baseBranchField(_ value: String?, required: Bool = false,
                                 set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            field(required ? "Branche de base *" : "Branche de base",
                  text: value ?? "",
                  help: required
                      ? "Obligatoire quand le rafraîchissement est actif : c'est la "
                        + "référence du `git reset --hard origin/<branche>`."
                      : "Facultatif. Laissé vide, Superset utilise la branche de base du "
                        + "projet — le drapeau --base-branch n'est même pas transmis.",
                  placeholder: required ? "obligatoire (ex. main)" : "défaut du projet Superset",
                  set: set)
            if required && (value ?? "").isEmpty {
                Text("Requise tant que « Rafraîchir le worktree » est coché.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .padding(.leading, 148)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 140, alignment: .leading)
    }

    private func field(_ title: String, text: String, help: String,
                       placeholder: String = "",
                       set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            label(title)
            TextField(placeholder, text: Binding(get: { text }, set: set))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(maxWidth: 320)
                .help(help)
                .accessibilityLabel(title)
            Spacer()
        }
    }
}
