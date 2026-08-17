@file:Suppress("UnstableApiUsage")

package org.rosegold.ide

import com.intellij.codeInsight.hints.ChangeListener
import com.intellij.codeInsight.hints.FactoryInlayHintsCollector
import com.intellij.codeInsight.hints.ImmediateConfigurable
import com.intellij.codeInsight.hints.InlayHintsCollector
import com.intellij.codeInsight.hints.InlayHintsProvider
import com.intellij.codeInsight.hints.InlayHintsSink
import com.intellij.codeInsight.hints.NoSettings
import com.intellij.codeInsight.hints.SettingsKey
import com.intellij.lang.Language
import com.intellij.openapi.editor.Editor
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import javax.swing.JComponent
import javax.swing.JPanel

/**
 * Inferred-type inlay hints: for an un-annotated `var x = 5` / `const c = "hi"`,
 * show the initializer's inferred type inline — `var x: int = 5`. Heuristic and
 * text-based (to fit the flat PSI): a hint is emitted only when the type is
 * unambiguous from the initializer's leading tokens (a literal, a `[`/`{`/tuple,
 * a known class/struct constructor, or a known enum case). Unknown initializers
 * (a bare call, an identifier, `nil`, a lambda) get no hint rather than a guess.
 */
class RoseGoldTypeHintsProvider : InlayHintsProvider<NoSettings> {

    override val key: SettingsKey<NoSettings> = SettingsKey("rosegold.type.hints")
    override val name: String = "Inferred types"
    override val previewText: String = "func main():\n    var x = 5\n    var s = \"hi\""

    override fun createSettings(): NoSettings = NoSettings()

    override fun createConfigurable(settings: NoSettings): ImmediateConfigurable =
        object : ImmediateConfigurable {
            override fun createComponent(listener: ChangeListener): JComponent = JPanel()
        }

    override fun isLanguageSupported(language: Language): Boolean =
        language === RoseGoldLanguage.INSTANCE

    override fun getCollectorFor(
        file: PsiFile,
        editor: Editor,
        settings: NoSettings,
        sink: InlayHintsSink,
    ): InlayHintsCollector = object : FactoryInlayHintsCollector(editor) {
        override fun collect(element: PsiElement, editor: Editor, sink: InlayHintsSink): Boolean {
            if (element !is PsiFile) return true
            for (hint in collectHints(element.text)) {
                // Wrap in roundWithBackground so the small text is vertically
                // centered on the line (bare smallText is top-aligned and looks
                // raised) and matches the parameter-name hints' presentation.
                sink.addInlineElement(
                    hint.offset, false,
                    factory.roundWithBackground(factory.smallText(": ${hint.type}")),
                    false,
                )
            }
            return true
        }
    }

    private data class Hint(val offset: Int, val type: String)

    // `var NAME = …` / `const NAME = …` with no `: type` annotation (the `=`
    // immediately follows the name). Destructuring (`var a, b = …`) is excluded
    // since a comma sits between the name and `=`.
    private val declRegex =
        Regex("""(?m)^\s*(?:pub\s+|private\s+)?(?:static\s+)?(?:var|const)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$""")

    private fun collectHints(text: String): List<Hint> {
        val classes = HashSet<String>()
        val enums = HashSet<String>()
        for (d in RoseGoldDeclarations.scanFlat(text)) {
            when (d.kind) {
                RoseGoldDeclaration.Kind.CLASS, RoseGoldDeclaration.Kind.STRUCT -> classes.add(d.name)
                RoseGoldDeclaration.Kind.ENUM -> enums.add(d.name)
                else -> {}
            }
        }
        val hints = ArrayList<Hint>()
        for (m in declRegex.findAll(text)) {
            val name = m.groups[1]!!
            val init = m.groupValues[2].trim()
            val type = inferType(init, classes, enums) ?: continue
            hints.add(Hint(name.range.last + 1, type)) // just after the name
        }
        return hints
    }

    companion object {
        /** The inferred type of an initializer, or null when it's not unambiguous. */
        @JvmStatic
        fun inferType(init: String, classes: Set<String>, enums: Set<String>): String? {
            if (init.isEmpty()) return null
            val c = init[0]
            return when {
                c == '"' -> "str"
                c == '[' -> "list"
                c == '{' -> "map"
                c.isDigit() -> when {
                    Regex("""^[0-9][0-9_]*\s*\.\.""").containsMatchIn(init) -> "list" // a range a..b
                    Regex("""^[0-9][0-9_]*\.[0-9]""").containsMatchIn(init) -> "float"
                    else -> "int"
                }
                init.startsWith("true") -> if (isWordEnd(init, 4)) "bool" else null
                init.startsWith("false") -> if (isWordEnd(init, 5)) "bool" else null
                c == '(' -> if (hasTopLevelComma(init)) "tuple" else null
                c.isLetter() || c == '_' -> {
                    val id = init.takeWhile { it == '_' || it.isLetterOrDigit() }
                    val rest = init.substring(id.length).trimStart()
                    when {
                        rest.startsWith("(") && id in classes -> id // T(…) constructor
                        rest.startsWith(".") && id in enums -> id    // Enum.Case
                        else -> null
                    }
                }
                else -> null
            }
        }

        /** Whether the char at [at] ends the word (so `true`/`false` isn't a prefix). */
        private fun isWordEnd(s: String, at: Int): Boolean =
            at >= s.length || !(s[at] == '_' || s[at].isLetterOrDigit())

        private fun hasTopLevelComma(s: String): Boolean {
            var depth = 0
            for (c in s) when (c) {
                '(', '[', '{', '<' -> depth++
                ')', ']', '}', '>' -> { depth--; if (depth == 0) return false }
                ',' -> if (depth == 1) return true
            }
            return false
        }
    }
}
