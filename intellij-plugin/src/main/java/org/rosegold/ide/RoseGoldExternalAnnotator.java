package org.rosegold.ide;

import com.intellij.execution.configurations.GeneralCommandLine;
import com.intellij.execution.process.ProcessOutput;
import com.intellij.execution.util.ExecUtil;
import com.intellij.lang.annotation.AnnotationHolder;
import com.intellij.lang.annotation.ExternalAnnotator;
import com.intellij.lang.annotation.HighlightSeverity;
import com.intellij.openapi.editor.Document;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.psi.PsiDocumentManager;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Runs {@code RoseGold_Zig check} on the file and turns each reported diagnostic
 * into an editor annotation, so real compiler errors are underlined live. Errors
 * reflect the file on disk, so they refresh on save.
 */
public final class RoseGoldExternalAnnotator
        extends ExternalAnnotator<RoseGoldExternalAnnotator.Info, List<RoseGoldExternalAnnotator.Diag>> {

    public static final class Info {
        final String path;
        final String basePath;

        Info(String path, String basePath) {
            this.path = path;
            this.basePath = basePath;
        }
    }

    public static final class Diag {
        final int line;
        final int col;
        final String message;

        Diag(int line, int col, String message) {
            this.line = line;
            this.col = col;
            this.message = message;
        }
    }

    // Matches the location line, e.g. `  --> /path/file.rg:3:5`.
    private static final Pattern LOCATION = Pattern.compile("-->\\s+.+:(\\d+):(\\d+)");

    @Override
    public @Nullable Info collectInformation(@NotNull PsiFile file) {
        VirtualFile vf = file.getVirtualFile();
        if (vf == null) {
            return null;
        }
        String base = file.getProject().getBasePath();
        return new Info(vf.getPath(), base);
    }

    @Override
    public @Nullable List<Diag> doAnnotate(Info info) {
        if (info == null) {
            return null;
        }
        String exe = RoseGoldExecutable.resolve(info.basePath);
        GeneralCommandLine cmd = new GeneralCommandLine(exe, "check", info.path);
        if (info.basePath != null) {
            cmd.setWorkDirectory(info.basePath);
        }
        final ProcessOutput output;
        try {
            output = ExecUtil.execAndGetOutput(cmd);
        } catch (Exception e) {
            return null; // executable missing / not runnable — stay quiet
        }
        return parse(output.getStderr());
    }

    private static List<Diag> parse(String stderr) {
        List<Diag> diags = new ArrayList<>();
        String pendingMessage = null;
        for (String raw : stderr.split("\n")) {
            String line = raw.strip();
            if (line.startsWith("error:")) {
                pendingMessage = line.substring("error:".length()).trim();
            } else if (line.startsWith("runtime error:")) {
                pendingMessage = line.substring("runtime error:".length()).trim();
            } else if (pendingMessage != null) {
                Matcher m = LOCATION.matcher(line);
                if (m.find()) {
                    try {
                        int lineNo = Integer.parseInt(m.group(1));
                        int col = Integer.parseInt(m.group(2));
                        diags.add(new Diag(lineNo, col, pendingMessage));
                    } catch (NumberFormatException ignored) {
                        // skip a malformed location
                    }
                    pendingMessage = null;
                }
            }
        }
        return diags;
    }

    @Override
    public void apply(@NotNull PsiFile file, List<Diag> diags, @NotNull AnnotationHolder holder) {
        if (diags == null || diags.isEmpty()) {
            return;
        }
        Document doc = PsiDocumentManager.getInstance(file.getProject()).getDocument(file);
        if (doc == null) {
            return;
        }
        int textLen = doc.getTextLength();
        for (Diag d : diags) {
            int lineIndex = Math.max(0, Math.min(d.line - 1, doc.getLineCount() - 1));
            int lineStart = doc.getLineStartOffset(lineIndex);
            int lineEnd = doc.getLineEndOffset(lineIndex);
            int start = Math.min(lineStart + Math.max(0, d.col - 1), lineEnd);
            int end = lineEnd;
            if (end <= start) {
                end = Math.min(start + 1, textLen);
            }
            holder.newAnnotation(HighlightSeverity.ERROR, d.message)
                    .range(new com.intellij.openapi.util.TextRange(start, end))
                    .create();
        }
    }
}
