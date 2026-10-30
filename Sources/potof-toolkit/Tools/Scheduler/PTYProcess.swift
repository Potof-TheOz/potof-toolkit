import Foundation
import SwiftTerm

/// Une commande à exécuter dans un pseudo-terminal 120×40.
struct PTYRequest {
    var executable: String
    var arguments: [String]          // argv complet, argv[0] inclus (execve)
    var environment: [String]        // "CLÉ=valeur"
    var directory: String
    var ttyFile: URL?                // flux brut ajouté en fin de fichier (créé si absent)
    var timeout: TimeInterval
    var stopMarker: URL?             // fichier posé par le hook Stop
    var detectTrustDialog: Bool
    var keepOutput: Bool             // garder le flux en mémoire (pour `mcp list`)
}

enum PTYEnd: Equatable {
    case exited(code: Int32)         // fin spontanée ; signal N ⇒ 128 + N
    case stopped(code: Int32?)       // marqueur vu puis fin (nil si tué)
    case timedOut, trustDialog, spawnFailed
}

struct PTYResult {
    let end: PTYEnd
    let output: Data
}

/// Exécute une commande dans un PTY que **le runner possède**, enregistre tout le flux
/// et décide de sa fin : sortie spontanée, marqueur du hook `Stop` (puis `/exit`),
/// délai dépassé, ou dialogue « trust this folder ».
///
/// Headless : de SwiftTerm on n'utilise que `PseudoTerminalHelpers` (aucune vue, aucun
/// `NSApp`). `forkpty` fait de l'enfant le chef de session et de son groupe : tous les
/// signaux visent le **groupe** (`kill(-pid, …)`), petits-enfants compris.
enum PTYProcess {
    static let columns: UInt16 = 120
    static let rows: UInt16 = 40
    static let exitInput = "/exit\r"
    static let stopGrace: TimeInterval = 10
    static let killGrace: TimeInterval = 3

    /// Pas de la boucle (borne du `poll` sur le maître).
    private static let pollStep: Int32 = 300
    /// Seuls les premiers octets du flux sont examinés pour le dialogue de confiance.
    private static let trustScanLimit = 64 * 1024

    static func run(_ request: PTYRequest) -> PTYResult {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard let child = PseudoTerminalHelpers.fork(andExec: request.executable,
                                                     args: request.arguments,
                                                     env: request.environment,
                                                     currentDirectory: request.directory,
                                                     desiredWindowSize: &size) else {
            return PTYResult(end: .spawnFailed, output: Data())
        }
        let session = Session(request: request, pid: child.pid, master: child.masterFd)
        return session.drive()
    }

    /// Vrai si le flux contient le dialogue « Do you trust this folder? » de `claude`.
    /// Le TUI espace les mots avec des déplacements de curseur (`ESC [ 1 C`), pas des
    /// blancs : on retire donc les séquences d'échappement ET tout blanc avant de
    /// chercher (forme mesurée sur `claude` 2.1.314).
    static func containsTrustDialog(_ output: Data) -> Bool {
        let bytes = [UInt8](output)
        var kept: [UInt8] = []
        kept.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B {                                  // ESC
                i += 1
                guard i < bytes.count else { break }
                switch bytes[i] {
                case 0x5B:                                  // CSI : ESC [ params… lettre
                    i += 1
                    while i < bytes.count, !(0x40...0x7E).contains(bytes[i]) { i += 1 }
                    i += 1
                case 0x5D:                                  // OSC : ESC ] … BEL | ESC \
                    i += 1
                    while i < bytes.count {
                        if bytes[i] == 0x07 { i += 1; break }
                        if bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5C {
                            i += 2; break
                        }
                        i += 1
                    }
                case 0x28, 0x29, 0x2A, 0x2B:                // ESC ( X : jeu de caractères
                    i += 2
                default:                                    // ESC + un octet (ESC 7, ESC =…)
                    i += 1
                }
                continue
            }
            if b != 0x20, b != 0x09, b != 0x0A, b != 0x0D { kept.append(b) }
            i += 1
        }
        return String(decoding: kept, as: UTF8.self).lowercased().contains("trustthisfolder")
    }

    // MARK: - Boucle d'un run

    private final class Session {
        let request: PTYRequest
        let pid: pid_t
        let master: Int32
        var ttyFD: Int32 = -1
        var output = Data()          // flux complet, seulement si keepOutput
        var scan = Data()            // 64 premiers Ko, seulement si detectTrustDialog
        var scanDirty = false
        var eof = false              // le maître ne rend plus rien (esclave fermé)
        var status: Int32?           // statut waitpid BRUT une fois l'enfant récolté

        init(request: PTYRequest, pid: pid_t, master: Int32) {
            self.request = request
            self.pid = pid
            self.master = master
        }

        func drive() -> PTYResult {
            _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
            openTTYFile()
            defer {
                close(master)
                if ttyFD >= 0 { close(ttyFD) }
            }

            let deadline = Date().addingTimeInterval(request.timeout)
            var exitSentAt: Date?
            var trustSeen = false

            while true {
                waitForOutput()
                drain()

                if request.detectTrustDialog, scanDirty {
                    scanDirty = false
                    trustSeen = PTYProcess.containsTrustDialog(scan)
                }
                if exitSentAt == nil, let marker = request.stopMarker,
                   FileManager.default.fileExists(atPath: marker.path) {
                    exitSentAt = Date()
                    send(PTYProcess.exitInput)
                }
                if let raw = reap() {
                    drain()
                    let code = PTYProcess.decode(raw)
                    return finish(exitSentAt != nil ? .stopped(code: code) : .exited(code: code))
                }
                if trustSeen {
                    terminateGroup()
                    return finish(.trustDialog)
                }
                if let sent = exitSentAt, Date().timeIntervalSince(sent) > PTYProcess.stopGrace {
                    terminateGroup()
                    return finish(.stopped(code: nil))
                }
                if Date() >= deadline {
                    terminateGroup()
                    return finish(.timedOut)
                }
            }
        }

        private func finish(_ end: PTYEnd) -> PTYResult {
            PTYResult(end: end, output: request.keepOutput ? output : Data())
        }

        private func openTTYFile() {
            guard let url = request.ttyFile else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            ttyFD = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        }

        /// Attend du contenu sur le maître, au plus un pas. Une fois le maître à EOF,
        /// `poll` rendrait la main en boucle : on dort le pas à la place.
        private func waitForOutput() {
            if eof {
                usleep(100_000)
                return
            }
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            _ = poll(&pfd, 1, PTYProcess.pollStep)
        }

        /// Lit tout ce qui est disponible (maître non bloquant).
        private func drain() {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while !eof {
                let n = read(master, &chunk, chunk.count)
                if n > 0 {
                    record(Data(chunk[0..<n]))
                } else if n == 0 {
                    eof = true
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    eof = true                              // EIO : l'esclave s'est fermé
                }
            }
        }

        private func record(_ data: Data) {
            if ttyFD >= 0 {
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(ttyFD, raw.baseAddress! + offset, raw.count - offset)
                        if n <= 0 { if n < 0, errno == EINTR { continue }; break }
                        offset += n
                    }
                }
            }
            if request.keepOutput { output.append(data) }
            if request.detectTrustDialog, scan.count < PTYProcess.trustScanLimit {
                scan.append(data.prefix(PTYProcess.trustScanLimit - scan.count))
                scanDirty = true
            }
        }

        private func send(_ text: String) {
            let bytes = Array(text.utf8)
            _ = write(master, bytes, bytes.count)
        }

        /// Récolte l'enfant sans bloquer. Rend le statut BRUT, une seule fois.
        private func reap() -> Int32? {
            if let status { return status }
            var raw: Int32 = 0
            let result = waitpid(pid, &raw, WNOHANG)
            if result == pid { status = raw; return raw }
            if result < 0, errno == ECHILD { status = 0; return 0 }
            return nil
        }

        /// SIGTERM au groupe, SIGKILL après `killGrace`, puis récolte. Un dernier SIGKILL
        /// vise les membres du groupe qui auraient survécu à la mort du chef.
        private func terminateGroup() {
            kill(-pid, SIGTERM)
            if !waitForExit(PTYProcess.killGrace) {
                kill(-pid, SIGKILL)
                _ = waitForExit(5)
            }
            kill(-pid, SIGKILL)
            drain()
        }

        private func waitForExit(_ seconds: TimeInterval) -> Bool {
            let limit = Date().addingTimeInterval(seconds)
            while true {
                drain()                                     // l'enfant ne doit pas bloquer sur l'écriture
                if reap() != nil { return true }
                if Date() >= limit { return false }
                usleep(50_000)
            }
        }
    }

    /// Statut waitpid brut → code. Un signal N donne 128 + N.
    fileprivate static func decode(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7F
        return signal == 0 ? (raw >> 8) & 0xFF : 128 + signal
    }
}
