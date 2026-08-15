package org.rosegold.ide;

import com.intellij.execution.configurations.GeneralCommandLine;
import com.intellij.execution.process.ProcessOutput;
import com.intellij.execution.util.ExecUtil;
import com.intellij.openapi.editor.Document;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.util.TextRange;
import com.intellij.openapi.util.io.FileUtil;
import com.intellij.psi.PsiDocumentManager;
import com.intellij.psi.PsiFile;
import com.intellij.psi.codeStyle.ExternalFormatProcessor;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import java.io.File;

/**
 * Hooks "Reformat Code" to the compiler's {@code fmt} command, so a `.rg` file is
 * reformatted in the canonical style the language itself defines. The current
 * (possibly unsaved) text is written to a temp file and formatted there, so
 * editing doesn't need a save first.
 */
public final class RoseGoldFormattingProcessor implements ExternalFormatProcessor {
    @Override
    public boolean activeForFile(@NotNull PsiFile source) {
        return source instanceof RoseGoldFile;
    }

    @Override
    public @Nullable TextRange format(@NotNull PsiFile source,
                                      @NotNull TextRange range,
                                      boolean canChangeWhiteSpaceOnly,
                                      boolean keepLineBreaks,
                                      boolean enableBulkUpdate,
                                      int cursorOffset) {
        Project project = source.getProject();
        Document document = PsiDocumentManager.getInstance(project).getDocument(source);
        if (document == null) {
            return null;
        }
        String formatted = runFmt(project, document.getText());
        if (formatted == null || formatted.equals(document.getText())) {
            return null;
        }
        document.replaceString(0, document.getTextLength(), formatted);
        PsiDocumentManager.getInstance(project).commitDocument(document);
        return new TextRange(0, formatted.length());
    }

    @Override
    public @Nullable String indent(@NotNull PsiFile source, int lineStartOffset) {
        return null; // whole-file `fmt` only; no on-the-fly single-line indentation
    }

    @Override
    public @NotNull String getId() {
        return "RoseGoldFmt";
    }

    private static @Nullable String runFmt(Project project, String text) {
        File temp = null;
        try {
            temp = FileUtil.createTempFile("rosegold", ".rg", true);
            FileUtil.writeToFile(temp, text);
            String exe = RoseGoldExecutable.resolve(project.getBasePath());
            GeneralCommandLine cmd = new GeneralCommandLine(exe, "fmt", temp.getAbsolutePath());
            ProcessOutput output = ExecUtil.execAndGetOutput(cmd);
            if (output.getExitCode() != 0) {
                return null; // a parse error — leave the file untouched
            }
            return output.getStdout();
        } catch (Exception e) {
            return null;
        } finally {
            if (temp != null) {
                FileUtil.delete(temp);
            }
        }
    }
}
