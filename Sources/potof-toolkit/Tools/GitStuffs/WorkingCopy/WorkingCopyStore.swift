import Foundation
import Combine

/// Source de vérité de la couche « working copy » d'un repo : statut des fichiers, état de
/// synchronisation (ahead/behind), boîte de commit, et pilotage des actions git.
///
/// Contraintes respectées (cf. `CLAUDE.md`) :
/// - git en tâche de fond, **mutations publiées sur le thread principal** ;
/// - les commandes d'un même repo sont **sérialisées** (une file dédiée) pour éviter les
///   courses sur l'index ;
/// - `fetch` échoue proprement (auth/réseau) sans bloquer → `sync.fetchFailed`.
final class WorkingCopyStore: ObservableObject {

    // MARK: - État publié

    @Published private(set) var files: [FileStatus] = []
    @Published private(set) var sync: RepoSyncState = .unknown
    @Published private(set) var branch: String = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var isFetching = false
    /// Libellé de l'action en cours (désactive l'UI), ou `nil`.
    @Published private(set) var busyAction: String?
    /// Dernier message d'erreur d'action (banni​ère), effacé au succès suivant.
    @Published var actionError: String?
    /// Incrémenté à chaque rafraîchissement du statut → signal de rechargement pour les
    /// vues dépendantes (ex. le diff d'un fichier dans `WorkingDiffView`).
    @Published private(set) var revision = 0

    /// Boîte de commit (sujet + corps optionnel replié).
    @Published var commitSubject = ""
    @Published var commitBody = ""
    /// Génération du message de commit via la CLI `claude` en cours ?
    @Published private(set) var isGeneratingMessage = false

    /// Appelé (thread principal) quand l'historique a changé (commit, pull) → le graphe se
    /// recharge côté `RepoDetailView`.
    var onHistoryChanged: (() -> Void)?

    // MARK: - Dérivés (sections de la liste)

    var stagedFiles: [FileStatus] { files.filter { $0.isStaged } }
    var unstagedFiles: [FileStatus] { files.filter { $0.hasUnstagedChanges } }
    var untrackedFiles: [FileStatus] { files.filter { $0.isUntracked } }
    var conflictedFiles: [FileStatus] { files.filter { $0.isConflicted } }

    var hasStagedChanges: Bool { !stagedFiles.isEmpty }
    var isClean: Bool { files.isEmpty }
    var isBusy: Bool { busyAction != nil }
    var canCommit: Bool {
        hasStagedChanges && !commitSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }
    /// Générer un message n'a de sens qu'avec des fichiers indexés (la skill s'en sert).
    var canGenerateMessage: Bool { hasStagedChanges && !isGeneratingMessage && !isBusy }

    // MARK: - Privé

    let repo: URL
    private let service: WorkingCopyServicing
    private var fetchTimer: Timer?
    /// Sérialise les commandes git de ce repo.
    private let queue = DispatchQueue(label: "potof.gitstuffs.workingcopy")
    /// Intervalle de l'auto-fetch (repo sélectionné uniquement).
    private static let fetchInterval: TimeInterval = 180

    init(repo: URL, service: WorkingCopyServicing = GitWorkingActions()) {
        self.repo = repo
        self.service = service
    }

    deinit { fetchTimer?.invalidate() }

    // MARK: - Lecture (statut + ahead/behind)

    /// (Re)charge le statut des fichiers, la branche et l'état de synchronisation.
    func refresh() {
        isRefreshing = true
        let repo = self.repo
        queue.async { [weak self] in
            let statusR = Git.run(["status", "--porcelain=v2", "-z"], in: repo)
            let files = GitStatusParser.parseStatus(statusR.stdout)

            let branchR = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
            let rawBranch = branchR.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = (rawBranch == "HEAD") ? "" : rawBranch

            let (upstream, ahead, behind) = Self.readSync(repo: repo)

            DispatchQueue.main.async {
                guard let self else { return }
                self.files = files
                self.branch = branch
                self.sync.upstream = upstream
                self.sync.ahead = ahead
                self.sync.behind = behind
                self.isRefreshing = false
                self.revision &+= 1
            }
        }
    }

    /// Lit l'amont configuré + le compte ahead/behind (bloquant, hors thread principal).
    private static func readSync(repo: URL) -> (upstream: String?, ahead: Int, behind: Int) {
        let upstreamR = Git.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: repo
        )
        guard upstreamR.ok else { return (nil, 0, 0) }
        let upstream = upstreamR.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upstream.isEmpty else { return (nil, 0, 0) }

        let ab = Git.run(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], in: repo)
        if ab.ok, let parsed = GitStatusParser.parseAheadBehind(ab.stdout) {
            return (upstream, parsed.ahead, parsed.behind)
        }
        return (upstream, 0, 0)
    }

    // MARK: - Fetch (manuel + timer)

    /// Démarre l'auto-fetch périodique (à appeler quand le repo devient visible).
    func startAutoFetch() {
        stopAutoFetch()
        fetch()   // premier fetch immédiat à la sélection
        let timer = Timer.scheduledTimer(withTimeInterval: Self.fetchInterval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        RunLoop.main.add(timer, forMode: .common)
        fetchTimer = timer
    }

    /// Arrête l'auto-fetch (changement de repo, disparition de la vue).
    func stopAutoFetch() {
        fetchTimer?.invalidate()
        fetchTimer = nil
    }

    /// `git fetch` puis recalcul de ahead/behind. N'empile pas les fetchs.
    func fetch() {
        guard !isFetching else { return }
        isFetching = true
        let repo = self.repo
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.service.fetch(in: repo)
            let (upstream, ahead, behind) = Self.readSync(repo: repo)
            DispatchQueue.main.async {
                self.isFetching = false
                self.sync.upstream = upstream
                self.sync.ahead = ahead
                self.sync.behind = behind
                if result.ok {
                    self.sync.fetchFailed = false
                    self.sync.lastFetch = Date()
                } else {
                    // Auth/réseau : on le signale sans bloquer ni écraser l'état connu.
                    self.sync.fetchFailed = true
                }
            }
        }
    }

    // MARK: - Actions d'écriture

    func stage(_ file: FileStatus) {
        perform("Stage") { self.service.stage(path: file.path, in: self.repo) }
    }
    func unstage(_ file: FileStatus) {
        perform("Déstage") { self.service.unstage(path: file.path, in: self.repo) }
    }
    func discard(_ file: FileStatus) {
        perform("Jeter") { self.service.discard(file: file, in: self.repo) }
    }
    func stageAll() {
        perform("Tout stager") { self.service.stageAll(in: self.repo) }
    }
    func unstageAll() {
        perform("Tout déstager") { self.service.unstageAll(in: self.repo) }
    }
    /// Stage tout le contenu d'un dossier (`git add -A -- <dir>` accepte un pathspec dossier).
    func stageFolder(_ path: String) {
        perform("Stager le dossier") { self.service.stage(path: path, in: self.repo) }
    }
    /// Déstage tout le contenu d'un dossier (`git restore --staged -- <dir>`).
    func unstageFolder(_ path: String) {
        perform("Déstager le dossier") { self.service.unstage(path: path, in: self.repo) }
    }

    func commit() {
        let subject = commitSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return }
        let body = commitBody
        perform("Commit", historyChanged: true, onSuccess: { [weak self] in
            self?.commitSubject = ""
            self?.commitBody = ""
        }) {
            self.service.commit(subject: subject, body: body, in: self.repo)
        }
    }

    /// Génère un message de commit via la skill Claude `claude -p "/staged-file-commit-message"`
    /// (basée sur les fichiers indexés). Remplit le sujet (+ le corps si la sortie est
    /// multi-lignes). Outil **externe** invoqué via un shell de login (PATH complet).
    func generateCommitMessage() {
        guard canGenerateMessage else { return }
        isGeneratingMessage = true
        actionError = nil
        let repo = self.repo
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.runClaudeCommitMessage(repo: repo)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isGeneratingMessage = false
                guard result.ok, !result.message.isEmpty else {
                    self.actionError = result.message.isEmpty
                        ? "La génération du message a échoué (claude introuvable ou interrompu)."
                        : "Génération du message : \(result.message)"
                    return
                }
                // Sortie brute : 1ʳᵉ ligne = sujet, reste (après ligne vide) = corps.
                let lines = result.message.components(separatedBy: "\n")
                self.commitSubject = lines.first ?? result.message
                let body = lines.dropFirst()
                    .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.commitBody = body
            }
        }
    }

    /// Exécute `claude -p "/staged-file-commit-message"` dans le repo via un shell de login
    /// (pour retrouver `claude` dans le PATH, comme le lancement des sessions). Bloquant,
    /// avec garde-fou de timeout. **Hors thread principal.**
    private static func runClaudeCommitMessage(repo: URL) -> (ok: Bool, message: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l -i : login + interactif → source .zprofile ET .zshrc. `claude` vit souvent dans
        // un PATH ajouté par .zshrc (interactif) : lancée depuis le Finder, l'app n'hérite que
        // d'un PATH minimal, donc `-l` seul ne suffit pas (« command not found: claude »).
        // Même parade que les sessions du Launcher (cf. CLAUDE.md).
        process.arguments = ["-l", "-i", "-c", "claude -p '/staged-file-commit-message'"]
        process.currentDirectoryURL = repo
        process.standardInput = FileHandle.nullDevice     // headless : pas d'attente d'entrée
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (false, "impossible de lancer claude : \(error.localizedDescription)")
        }

        // Garde-fou : tue le process s'il dépasse le délai (auth manquante, blocage…).
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let out = Git.sanitize(String(data: outData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = Git.sanitize(String(data: errData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus == 0 {
            return (true, out)
        }
        return (false, err.isEmpty ? out : err)
    }

    func push() {
        // Pas d'amont configuré → publier la branche courante (`push -u origin <branche>`).
        let setUpstream = sync.hasUpstream ? nil : (branch.isEmpty ? nil : branch)
        perform("Push", historyChanged: true) {
            self.service.push(in: self.repo, setUpstreamBranch: setUpstream)
        }
    }

    func pullRebase() {
        perform("Pull (rebase)", historyChanged: true) {
            self.service.pullRebase(in: self.repo)
        }
    }

    // Staging par hunk / ligne (patch reconstruit par `WorkingDiffView`).
    func stageSelection(_ patch: String) {
        perform("Stager la sélection") {
            self.service.applyPatch(patch, in: self.repo, cached: true, reverse: false)
        }
    }
    func unstageSelection(_ patch: String) {
        perform("Déstager la sélection") {
            self.service.applyPatch(patch, in: self.repo, cached: true, reverse: true)
        }
    }
    func discardSelection(_ patch: String) {
        perform("Jeter la sélection") {
            self.service.applyPatch(patch, in: self.repo, cached: false, reverse: true)
        }
    }

    /// Enveloppe commune : sérialise l'op, gère `busyAction`, l'erreur, le rechargement et
    /// le signal « historique changé ».
    private func perform(
        _ label: String,
        historyChanged: Bool = false,
        onSuccess: (() -> Void)? = nil,
        _ op: @escaping () -> GitActionResult
    ) {
        guard busyAction == nil else { return }
        busyAction = label
        actionError = nil
        queue.async { [weak self] in
            guard let self else { return }
            let res = op()
            DispatchQueue.main.async {
                self.busyAction = nil
                if res.ok {
                    onSuccess?()
                } else {
                    self.actionError = res.message.isEmpty ? "« \(label) » a échoué." : res.message
                }
                if historyChanged { self.onHistoryChanged?() }
                self.refresh()
            }
        }
    }
}
