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
import com.intellij.openapi.util.io.FileUtil
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import java.io.File
import javax.swing.JComponent
import javax.swing.JPanel

/**
 * Parameter-name inlay hints: at a call `f(a, b)`, show the callee's parameter
 * names inline — `f(x: a, y: b)`. The PSI is a flat token stream, so calls are
 * found by scanning the document text; parameter names come from the callee's
 * `(…)` header (a local `func`, an imported `mod.func`, or a small builtin table).
 *
 * Implemented in Kotlin because this platform ships only the legacy, Kotlin-shaped
 * inlay API (the declarative one isn't on the classpath).
 */
class RoseGoldInlayHintsProvider : InlayHintsProvider<NoSettings> {

    override val key: SettingsKey<NoSettings> = SettingsKey("rosegold.parameter.hints")
    override val name: String = "Parameter names"
    override val previewText: String = "func f(x: int):\n    pass\nfunc main():\n    f(1)"

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
            val text = element.text
            for (hint in collectHints(element, text)) {
                sink.addInlineElement(
                    hint.offset, false,
                    factory.roundWithBackground(factory.smallText("${hint.name}:")),
                    false,
                )
            }
            return true
        }
    }

    private data class Hint(val offset: Int, val name: String)

    // A call: `ident(` or `mod.ident(`, but not a declaration (`func ident(`).
    private val callRegex = Regex("""([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)\s*\(""")

    private fun collectHints(file: PsiFile, text: String): List<Hint> {
        val hints = ArrayList<Hint>()
        for (m in callRegex.findAll(text)) {
            val callee = m.groupValues[1]
            val open = m.range.last // index of '('
            // Skip declarations: `func name(`.
            val before = text.substring(0, m.range.first).trimEnd()
            if (before.endsWith("func")) continue
            val params = resolveParamNames(file, text, callee) ?: continue
            if (params.isEmpty()) continue
            val args = argStarts(text, open)
            for (i in args.indices) {
                if (i >= params.size) break
                val (start, argText) = args[i]
                // Skip when the argument already reads as the parameter (noise).
                if (argText == params[i]) continue
                hints.add(Hint(start, params[i]))
            }
        }
        return hints
    }

    /** Start offset + leading token of each top-level argument after `(` at [open]. */
    private fun argStarts(text: String, open: Int): List<Pair<Int, String>> {
        val out = ArrayList<Pair<Int, String>>()
        var depth = 0
        var i = open
        var segStart = open + 1
        val n = text.length
        while (i < n) {
            val c = text[i]
            when {
                c == '(' || c == '[' || c == '<' -> depth++
                c == ')' && depth == 0 -> { addArg(text, segStart, i, out); return out }
                c == ')' || c == ']' || c == '>' -> depth--
                c == ',' && depth == 1 -> { addArg(text, segStart, i, out); segStart = i + 1 }
            }
            i++
        }
        return out
    }

    private fun addArg(text: String, from: Int, to: Int, out: MutableList<Pair<Int, String>>) {
        var s = from
        while (s < to && text[s].isWhitespace()) s++
        if (s >= to) return // empty arg
        var e = s
        while (e < to && (text[e] == '_' || text[e].isLetterOrDigit())) e++
        out.add(Pair(s, text.substring(s, e)))
    }

    /** Parameter names for a callee: local func, imported `mod.func`, or a builtin. */
    private fun resolveParamNames(file: PsiFile, text: String, callee: String): List<String>? {
        val dot = callee.indexOf('.')
        if (dot > 0) {
            val mod = callee.substring(0, dot)
            val fn = callee.substring(dot + 1)
            val src = resolveModuleFile(file, text, mod)?.let {
                runCatching { FileUtil.loadFile(it) }.getOrNull()
            } ?: return null
            return paramNamesFromHeader(src, fn)
        }
        paramNamesFromHeader(text, callee)?.let { return it }
        return BUILTIN_PARAMS[callee]
    }

    /** The parameter names declared in `func NAME(<params>)`. */
    private fun paramNamesFromHeader(src: String, name: String): List<String>? {
        val header = Regex("""\bfunc\s+${Regex.escape(name)}\s*\(""").find(src) ?: return null
        var depth = 0
        var i = header.range.last // '('
        val start = i + 1
        while (i < src.length) {
            when (src[i]) {
                '(' -> depth++
                ')' -> { depth--; if (depth == 0) break }
            }
            i++
        }
        if (i >= src.length) return null
        val params = src.substring(start, i).trim()
        if (params.isEmpty()) return emptyList()
        return splitTopLevel(params).map { part ->
            // A param is `name`, `name: type`, or `name = default` — take the name.
            part.trim().takeWhile { it == '_' || it.isLetterOrDigit() }
        }.filter { it.isNotEmpty() }
    }

    private fun splitTopLevel(s: String): List<String> {
        val out = ArrayList<String>()
        var depth = 0
        var seg = StringBuilder()
        for (c in s) {
            when (c) {
                '<', '(', '[' -> { depth++; seg.append(c) }
                '>', ')', ']' -> { depth--; seg.append(c) }
                ',' -> if (depth == 0) { out.add(seg.toString()); seg = StringBuilder() } else seg.append(c)
                else -> seg.append(c)
            }
        }
        if (seg.isNotEmpty()) out.add(seg.toString())
        return out
    }

    /** Resolve an imported module `mod` to its source file. */
    private fun resolveModuleFile(file: PsiFile, text: String, mod: String): File? {
        val imp = Regex("""^\s*import\s+([A-Za-z_][A-Za-z0-9_.]*)""", RegexOption.MULTILINE)
        val segs = imp.findAll(text).map { it.groupValues[1].split(".") }
            .firstOrNull { it.last() == mod } ?: return null
        val rel = segs.joinToString(File.separator) + ".rg"
        val bases = ArrayList<File>()
        file.virtualFile?.parent?.path?.let {
            var dir: File? = File(it)
            repeat(5) { dir?.let { d -> bases.add(d); dir = d.parentFile } }
        }
        file.project.basePath?.let { bases.add(File(it)) }
        return bases.map { File(it, rel) }.firstOrNull { it.isFile }
    }

    companion object {
        private val BUILTIN_PARAMS = mapOf(
            "push" to listOf("list", "x"),
            "has" to listOf("map", "key"),
            "map" to listOf("list", "f"),
            "filter" to listOf("list", "pred"),
            "reduce" to listOf("list", "f", "init"),
            "split" to listOf("s", "sep"),
            "join" to listOf("list", "sep"),
            "replace" to listOf("s", "from", "to"),
            "pow" to listOf("base", "exp"),
            "min" to listOf("a", "b"),
            "max" to listOf("a", "b"),
            "connect" to listOf("signal", "handler"),
        )
    }
}
