package org.rosegold.ide;

import com.intellij.execution.configurations.GeneralCommandLine;
import com.intellij.execution.process.ProcessOutput;
import com.intellij.execution.util.ExecUtil;
import com.intellij.openapi.editor.Document;
import com.intellij.openapi.editor.Editor;
import com.intellij.openapi.util.io.FileUtil;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.lang.annotation.AnnotationHolder;
import com.intellij.lang.annotation.ExternalAnnotator;
import com.intellij.lang.annotation.HighlightSeverity;
import com.intellij.psi.PsiDocumentManager;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Runs {@code RoseGold_Zig check} and turns each reported diagnostic into an
 * editor annotation, so real compiler errors are underlined live. It checks the
 * <em>current editor buffer</em> (written to a temp file), not the file on disk,
 * so errors refresh as you type rather than only after a save.
 */
public final class RoseGoldExternalAnnotator
        extends ExternalAnnotator<RoseGoldExternalAnnotator.Info, List<RoseGoldExternalAnnotator.Diag>> {

    public static final class Info {
        final String text;      // live buffer contents
        final String dir;       // the real file's directory (for import resolution)
        final String basePath;  // project base (working dir + executable lookup)

        Info(String text, String dir, String basePath) {
            this.text = text;
            this.dir = dir;
            this.basePath = basePath;
        }
    }

    public static final class Diag {
        final String path;
        final int line;
        final int col;
        final String message;

        Diag(String path, int line, int col, String message) {
            this.path = path;
            this.line = line;
            this.col = col;
            this.message = message;
        }
    }

    // The location line, e.g. `  --> /path/file.rg:3:5` — captures path, line, col.
    private static final Pattern LOCATION = Pattern.compile("-->\\s+(.+):(\\d+):(\\d+)");

    @Override
    public @Nullable Info collectInformation(@NotNull PsiFile file) {
        return infoFor(file, file.getText());
    }

    @Override
    public @Nullable Info collectInformation(@NotNull PsiFile file, @NotNull Editor editor, boolean hasErrors) {
        // The document text reflects unsaved edits — that's what we want to check.
        return infoFor(file, editor.getDocument().getText());
    }

    private static @Nullable Info infoFor(@NotNull PsiFile file, @NotNull String text) {
        VirtualFile vf = file.getVirtualFile();
        if (vf == null || vf.getParent() == null) {
            return null;
        }
        return new Info(text, vf.getParent().getPath(), file.getProject().getBasePath());
    }

    @Override
    public @Nullable List<Diag> doAnnotate(Info info) {
        if (info == null) {
            return null;
        }
        File temp = null;
        try {
            // Check the live buffer: write it to a temp file and point imports at
            // the real file's directory (`--path`) so they resolve exactly as they
            // would on disk, but against the current unsaved content.
            temp = FileUtil.createTempFile("rosegold_check", ".rg", true);
            FileUtil.writeToFile(temp, info.text);
            String exe = RoseGoldExecutable.resolve(info.basePath);
            GeneralCommandLine cmd = new GeneralCommandLine(exe, "check", "--path", info.dir, temp.getAbsolutePath());
            if (info.basePath != null) {
                cmd.setWorkDirectory(info.basePath);
            }
            ProcessOutput output = ExecUtil.execAndGetOutput(cmd);
            return parse(output.getStderr(), temp.getName());
        } catch (Exception e) {
            return null; // executable missing / not runnable — stay quiet
        } finally {
            if (temp != null) {
                FileUtil.delete(temp);
            }
        }
    }

    /** Parse diagnostics, keeping only those in the checked file ({@code tempName}). */
    private static List<Diag> parse(String stderr, String tempName) {
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
                    String path = m.group(1);
                    // Only surface diagnostics for the file being edited, not for
                    // imported modules it pulls in.
                    if (path.endsWith(tempName)) {
                        try {
                            diags.add(new Diag(path, Integer.parseInt(m.group(2)),
                                    Integer.parseInt(m.group(3)), pendingMessage));
                        } catch (NumberFormatException ignored) {
                            // skip a malformed location
                        }
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
