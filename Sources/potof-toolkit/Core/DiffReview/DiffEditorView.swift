import SwiftUI
import AppKit

/// **Éditeur de texte brut** pour amender un contenu proposé avant de l'accepter.
///
/// Pourquoi c'est possible (et sûr) : depuis `claude 2.1.220`, le contenu renvoyé avec
/// `FILE_SAVED` **devient l'input réel** de l'outil `Edit`/`Write` (cf.
/// `IDEProtocolContract`) — accepter en ayant modifié n'est donc pas un détournement,
/// c'est le mécanisme prévu. L'app n'écrit toujours rien elle-même.
///
/// **Conséquence directe sur ce composant : ce qui sort d'ici finit tel quel dans le
/// fichier de l'utilisateur.** Un guillemet droit transformé en guillemet typographique,
/// un `--` devenu tiret cadratin, une tabulation convertie en espaces, une fin de ligne
/// normalisée : chacune de ces « aides » de macOS produirait un fichier différent de ce
/// que l'utilisateur croit valider — et un `old_string` qui ne correspond plus. D'où
/// l'inventaire exhaustif de désactivations plus bas : ce n'est pas de la coquetterie,
/// c'est le contrat.
///
/// Deux cas limites à traiter (T6) :
/// - contenu édité **identique** à l'ancien ⇒ le CLI en déduit un diff vide et
///   **refuse** : il faut le dire à l'utilisateur avant qu'il ne clique ;
/// - fichier > ~100 000 lignes ⇒ le hunk reconstruit côté CLI se scinde et seul le
///   premier est repris ⇒ édition à désactiver, avec l'explication.
///
/// Ces deux cas se décident **en amont** (côté `DiffReviewView`) : ici, ils arrivent
/// simplement sous la forme d'un `isEditable == false`.
///
/// `NSViewRepresentable` sur `NSTextView` plutôt que `TextEditor` : monospace fiable,
/// tabulations respectées, correction automatique désactivable, gros fichiers tenables.
struct DiffEditorView: NSViewRepresentable {
    /// La vue AppKit exposée est le **scroll view** : c'est lui qui porte les deux
    /// barres de défilement (verticale ET horizontale) ; la `NSTextView` est son
    /// `documentView`.
    typealias NSViewType = NSScrollView

    /// Contenu édité, initialisé avec le contenu **proposé** par l'agent.
    @Binding var text: String
    /// `false` quand l'édition n'est pas permise (mode lecture, fichier trop gros).
    var isEditable: Bool

    // MARK: - Réglages de rendu

    /// Corps du texte. Fixe : ce n'est pas un éditeur de confort, c'est un panneau de
    /// relecture — on privilégie la densité et la stabilité du rendu.
    fileprivate static let fontSize: CGFloat = 12
    /// Largeur d'une tabulation, en caractères. Purement **visuel** : on ne touche
    /// jamais aux octets, on choisit seulement où tombent les taquets.
    fileprivate static let tabWidthInCharacters = 4

    // MARK: - Cycle de vie AppKit

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true       // ⇦ indispensable au non-wrapping
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        // Le fond du scroll view est visible autour d'un document plus étroit que la
        // zone visible : même couleur que le texte, sinon on voit une bande grise.
        scrollView.backgroundColor = .textBackgroundColor

        // --- Pile TextKit 1 montée à la main -------------------------------------
        // Depuis macOS 13, `NSTextView()` bascule par défaut sur TextKit 2. On lui
        // préfère ici TextKit 1, construit explicitement, pour une raison précise :
        // la recette « pas de retour à la ligne » (containerSize infinie +
        // widthTracksTextView = false + isHorizontallyResizable) est documentée et
        // déterministe sur TextKit 1, alors qu'elle a un comportement flottant selon
        // les versions sur TextKit 2. Du code re-wrappé visuellement rendrait la
        // relecture d'un diff mensongère (une ligne longue paraîtrait être plusieurs).
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        // `CGFloat.greatestFiniteMagnitude` explicite : `NSSize(width:height:)` a des
        // surcharges `Int`/`Double`/`CGFloat`, le `.membre` seul est ambigu.
        let container = NSTextContainer(
            containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = false   // la largeur ne suit PAS la vue…
        container.heightTracksTextView = false  // …ni la hauteur : le texte déborde,
                                                //   et c'est le scroll qui compense.
        layoutManager.addTextContainer(container)

        // Perf : autorise le layout paresseux/par morceaux plutôt qu'un calcul
        // intégral au premier affichage. Le gain reste partiel (une vue
        // « verticalement redimensionnable » a besoin d'une estimation de hauteur),
        // mais c'est le seul levier gratuit à ce niveau.
        layoutManager.allowsNonContiguousLayout = true

        let textView = CodeTextView(frame: .zero, textContainer: container)

        // --- Géométrie : scroll horizontal ---------------------------------------
        // Ordre important : le masque d'autoresize est posé AVANT les drapeaux
        // `is*Resizable`, car sur `NSText` ces drapeaux et le masque décrivent la même
        // chose. `[]` (NSViewNotSizable) = la vue se dimensionne d'elle-même par
        // `sizeToFit`, dans les deux axes — c'est la recette Apple pour un texte non
        // wrappé dans un scroll view.
        textView.autoresizingMask = []
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 6)

        // --- Apparence -----------------------------------------------------------
        // Couleurs système uniquement : correctes en clair comme en sombre, sans
        // aucune logique de thème à maintenir.
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        textView.font = DiffEditorView.codeFont()
        textView.typingAttributes = DiffEditorView.codeAttributes()

        // --- Tout ce qui pourrait CORROMPRE le texte : off ------------------------
        // Rappel du pourquoi (cf. en-tête) : ce buffer devient l'input réel de
        // `Edit`/`Write`. Chacune de ces options réécrit silencieusement ce que
        // l'utilisateur a tapé ou collé.
        textView.isRichText = false                            // pas d'attributs collés
        textView.importsGraphics = false                       // pas de pièces jointes
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isFieldEditor = false                         // Tab ≠ navigation (cf. CodeTextView)
        textView.smartInsertDeleteEnabled = false              // pas d'espaces « intelligents » au coller
        textView.isAutomaticQuoteSubstitutionEnabled = false   // " ne doit jamais devenir “ ”
        textView.isAutomaticDashSubstitutionEnabled = false    // -- ne doit jamais devenir —
        textView.isAutomaticTextReplacementEnabled = false     // pas de raccourcis utilisateur
        textView.isAutomaticSpellingCorrectionEnabled = false  // pas d'autocorrection
        textView.isAutomaticDataDetectionEnabled = false       // pas de détection dates/adresses
        textView.isAutomaticLinkDetectionEnabled = false       // pas de lien sur une URL
        textView.isAutomaticTextCompletionEnabled = false      // pas de complétion inline
        textView.isContinuousSpellCheckingEnabled = false      // ni soulignés rouges…
        textView.isGrammarCheckingEnabled = false              // …ni verts
        // Filet global : coupe la totalité des « text checking » d'un coup, y compris
        // ceux qui seraient réactivés par une préférence système ou un futur type.
        // Bonus perf : plus de passe d'analyse en tâche de fond sur tout le document.
        textView.enabledTextCheckingTypes = 0

        // Confort sans risque : annulation locale + barre de recherche (⌘F), aucune
        // des deux ne modifie le texte dans le dos de l'utilisateur.
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        // Contenu initial posé ICI, et pas dans `updateNSView` : le coordinateur naît
        // déjà « synchronisé » sur `parent.text` (c'est ce qui rend la garde
        // anti-boucle fiable dès la première frappe), donc `updateNSView` n'aurait
        // aucune raison de détecter un écart — la vue resterait vide.
        applyExternalText(text, to: textView, coordinator: context.coordinator)
        textView.isEditable = isEditable
        textView.isSelectable = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Le coordinateur survit aux recréations de la struct (SwiftUI la recrée à
        // chaque recomposition) : on lui repasse la version courante pour qu'il écrive
        // dans le **binding actuel** et pas dans une copie périmée.
        context.coordinator.parent = self

        // --- Le piège classique : la boucle SwiftUI → AppKit → SwiftUI -------------
        // Frappe clavier ⇒ `textDidChange` ⇒ on écrit dans le binding ⇒ SwiftUI
        // invalide ⇒ `updateNSView` ⇒ si on réécrivait `textView.string` sans
        // condition, on détruirait à CHAQUE caractère la position du curseur, la
        // sélection et la pile d'annulation (curseur qui saute en début de document :
        // le symptôme canonique de ce composant).
        //
        // Parade en deux temps :
        //  1. comparaison rapide au dernier texte que le coordinateur a fait
        //     transiter (même instance de `String` ⇒ égalité en O(1) par identité de
        //     buffer) : c'est le cas de la frappe, on sort immédiatement ;
        //  2. si le contenu vient réellement d'ailleurs, comparaison autoritaire au
        //     contenu de la vue (O(n), mais uniquement sur ce chemin rare) — évite de
        //     tout réécrire quand la valeur externe se trouve être déjà celle affichée.
        if text != context.coordinator.lastSyncedText, text != textView.string {
            applyExternalText(text, to: textView, coordinator: context.coordinator)
        }
        // Dans tous les cas on note la valeur observée : c'est elle qui sert de repère
        // au prochain passage (y compris quand on vient de sortir par le point 2).
        context.coordinator.lastSyncedText = text

        // Non éditable ⇒ **toujours sélectionnable** : on doit pouvoir copier ce que
        // l'agent propose même quand on n'a pas le droit de l'amender.
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        if !textView.isSelectable { textView.isSelectable = true }

        // Confort : garder le document au moins aussi large que la zone visible, pour
        // que le clic à droite d'une ligne courte place bien le curseur. `minSize` est
        // le plancher utilisé par `sizeToFit`. (Limite assumée : la prise en compte
        // n'intervient qu'au prochain recalcul de layout, pas instantanément au
        // redimensionnement de la fenêtre.)
        let visible = scrollView.contentSize
        if textView.minSize.width != visible.width || textView.minSize.height != visible.height {
            textView.minSize = visible
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // `delegate` est une référence faible non sûre côté AppKit : on la coupe pour
        // ne pas laisser la vue pointer vers un coordinateur libéré.
        (scrollView.documentView as? NSTextView)?.delegate = nil
        coordinator.textView = nil
    }

    // MARK: - Application d'un contenu venu de l'extérieur

    /// Remplace intégralement le contenu affiché. Chemin **rare** (nouvelle demande de
    /// diff, réinitialisation, bascule d'onglet) : on peut se permettre un `O(n)`.
    private func applyExternalText(_ newText: String,
                                   to textView: NSTextView,
                                   coordinator: Coordinator) {
        guard let storage = textView.textStorage else { return }

        // On mémorise la sélection pour la reposer si elle tient encore dans le
        // nouveau contenu : sinon on repart du début, jamais d'index hors bornes.
        let previousSelection = textView.selectedRange()

        // `coordinator.isApplyingExternalText` : garde-fou de réentrance. En principe
        // une écriture programmatique dans le storage ne passe pas par
        // `didChangeText()` (donc pas par le délégué), mais on ne veut pas que la
        // correction de la boucle repose sur ce détail d'implémentation d'AppKit : si
        // la notification partait, on renverrait vers le binding un texte qu'on vient
        // d'en recevoir — exactement la boucle qu'on cherche à éviter.
        coordinator.isApplyingExternalText = true
        defer { coordinator.isApplyingExternalText = false }

        // Une seule transaction, un seul passage d'attributs : pas de coloration
        // syntaxique, donc pas de re-attribution par frappe (choix assumé, cf. plus
        // bas). Les attributs sont posés à la construction de la chaîne, ce qui évite
        // un second parcours `addAttributes(_:range:)` sur tout le document.
        storage.beginEditing()
        storage.setAttributedString(
            NSAttributedString(string: newText, attributes: DiffEditorView.codeAttributes())
        )
        storage.endEditing()

        // Les nouveaux caractères tapés ensuite doivent hériter des mêmes attributs.
        textView.typingAttributes = DiffEditorView.codeAttributes()

        // `storage.length` plutôt que `(textView.string as NSString).length` : même
        // valeur (unités UTF-16), sans repasser par un pont Objective-C sur tout le
        // document. On repose un curseur simple, jamais une plage : une sélection
        // héritée d'un autre contenu n'aurait aucun sens.
        let restored = NSRange(
            location: min(previousSelection.location, storage.length),
            length: 0
        )
        textView.setSelectedRange(restored)

        // Un contenu venu de l'extérieur n'est pas une action annulable de
        // l'utilisateur : on repart d'une pile propre.
        textView.undoManager?.removeAllActions()

        coordinator.lastSyncedText = newText
    }

    // MARK: - Attributs

    fileprivate static func codeFont() -> NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Attributs appliqués à la totalité du texte. **Aucun** n'altère la chaîne : police,
    /// couleur et taquets de tabulation sont du rendu pur.
    fileprivate static func codeAttributes() -> [NSAttributedString.Key: Any] {
        let font = codeFont()

        // Taquets de tabulation calés sur la largeur réelle d'un caractère de la police
        // monospace : sans ça les tabulations tombent tous les 28 pt (valeur par défaut,
        // sans rapport avec la grille du code) et l'indentation paraît incohérente.
        // On vide `tabStops` pour que `defaultTabInterval` s'applique partout, y compris
        // au-delà des 12 taquets prédéfinis.
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        paragraph.tabStops = []
        paragraph.defaultTabInterval = advance * CGFloat(tabWidthInCharacters)
        // Pas de retour à la ligne : cohérent avec le conteneur de largeur infinie.
        paragraph.lineBreakMode = .byClipping

        return [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    // MARK: - Coordinateur

    /// Fait le pont AppKit → SwiftUI. Porte aussi les deux états qui empêchent la
    /// boucle de mise à jour (`lastSyncedText`, `isApplyingExternalText`).
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Version courante de la vue SwiftUI, rafraîchie à chaque `updateNSView` :
        /// donne accès au binding **à jour**.
        var parent: DiffEditorView
        /// Vue possédée par le scroll view ; référence non détenue logiquement (le
        /// scroll view en est le propriétaire), utile pour le démontage.
        weak var textView: NSTextView?
        /// Dernier contenu connu comme partagé entre AppKit et SwiftUI. Sert de test
        /// rapide dans `updateNSView` (cf. commentaire là-bas).
        var lastSyncedText: String
        /// Vrai pendant qu'on injecte un contenu externe dans le storage : les
        /// notifications `textDidChange` déclenchées par cette écriture ne doivent PAS
        /// repartir vers le binding.
        var isApplyingExternalText = false

        init(parent: DiffEditorView) {
            self.parent = parent
            self.lastSyncedText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView else { return }

            // `textView.string` rend la chaîne **telle quelle** : tabulations et fins
            // de ligne (`\n` comme `\r\n`) sont conservées octet pour octet, le système
            // de texte ne normalise rien de lui-même — il se contente de traiter
            // `\r\n` comme une seule rupture de ligne à l'affichage.
            let current = textView.string
            // On enregistre AVANT de publier : la republication par SwiftUI nous
            // reviendra sur cette même instance de `String`, que `updateNSView`
            // reconnaîtra immédiatement.
            lastSyncedText = current
            parent.text = current
        }
    }
}

// MARK: - Vue de texte

/// `NSTextView` avec un seul écart de comportement : la touche Tab **insère une
/// tabulation**. Une `NSTextView` non-field-editor le fait déjà par défaut, mais on
/// l'écrit explicitement — c'est un point sur lequel on ne veut pas dépendre d'un
/// défaut AppKit : dans un éditeur de code, Tab qui déplacerait le focus serait au
/// mieux surprenant, au pire une indentation perdue.
private final class CodeTextView: NSTextView {
    override func insertTab(_ sender: Any?) {
        insertText("\t", replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) {
        // ⇧Tab : ne rien faire plutôt que de sortir du champ. (Désindenter la
        // sélection serait un vrai comportement d'éditeur, hors périmètre ici : ça
        // supposerait de deviner l'unité d'indentation du fichier.)
    }
}

// MARK: - Notes de performance (ce qui a été fait, ce qui a été écarté)
//
// Fait :
// - `allowsNonContiguousLayout = true` : layout par morceaux plutôt qu'intégral.
// - Aucune réécriture du storage à la frappe (cf. la garde de `updateNSView`) : c'est
//   de loin le premier poste de coût sur un gros fichier, et le plus facile à rater.
// - Attributs posés en une passe, à la construction de la chaîne, dans un unique
//   `beginEditing`/`endEditing`.
// - Vérification orthographique, grammaticale et détection de données coupées : elles
//   parcourent tout le document en tâche de fond.
//
// Écarté volontairement :
// - **Coloration syntaxique** : imposerait de ré-attribuer le texte à chaque frappe
//   (ou un moteur incrémental) ; la lisibilité du diff est déjà assurée par la vue de
//   diff (`Core/Diff`), cet éditeur n'a qu'à être fidèle. Aucune dépendance ajoutée,
//   conformément aux contraintes du projet.
// - **Règle de numéros de ligne** (`NSRulerView`) : redessinée à chaque défilement,
//   coût non nul, bénéfice faible ici.
// - **Chargement paresseux du contenu** : le contenu arrive déjà entièrement en
//   mémoire dans la requête `openDiff`, il n'y a rien à streamer. Le cas réellement
//   pathologique (> 100 000 lignes) est traité en amont par `isEditable == false`
//   (§2.3 point 2 du plan), pas par ce composant.
