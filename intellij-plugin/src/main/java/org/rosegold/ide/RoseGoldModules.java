package org.rosegold.ide;

import com.intellij.openapi.vfs.LocalFileSystem;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.Nullable;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Shared resolution of {@code import a.b.c} to the module's {@code .rg} file,
 * through the virtual file system (so it finds in-memory / unsaved buffers and
 * fixture files, not just what's on disk). Mirrors the language's own resolution:
 * relative to the importing file's directory first, then a few ancestors and the
 * project base.
 */
public final class RoseGoldModules {
    private RoseGoldModules() {
    }

    private static final Pattern IMPORT =
            Pattern.compile("^\\s*import\\s+([A-Za-z_][A-Za-z0-9_.]*)", Pattern.MULTILINE);

    /**
     * If {@code receiver} is the bound (leaf) name of an {@code import a.b.c} in
     * {@code text}, the path segments {@code {a, b, c}}; otherwise null.
     */
    public static String @Nullable [] importSegments(CharSequence text, String receiver) {
        Matcher im = IMPORT.matcher(text);
        while (im.find()) {
            String[] segs = im.group(1).split("\\.");
            if (segs[segs.length - 1].equals(receiver)) {
                return segs;
            }
        }
        return null;
    }

    /** Resolve module {@code segs} to its {@code .rg} file, or null if not found. */
    public static @Nullable VirtualFile resolveModuleFile(PsiFile file, String[] segs) {
        String rel = String.join("/", segs) + ".rg";
        List<VirtualFile> bases = new ArrayList<>();
        VirtualFile vf = file.getVirtualFile();
        if (vf != null && vf.getParent() != null) {
            VirtualFile dir = vf.getParent();
            bases.add(dir);
            VirtualFile up = dir;
            for (int k = 0; k < 4 && up != null; k++) {
                up = up.getParent();
                if (up != null) {
                    bases.add(up);
                }
            }
        }
        String base = file.getProject().getBasePath();
        if (base != null) {
            VirtualFile baseDir = LocalFileSystem.getInstance().findFileByPath(base);
            if (baseDir != null) {
                bases.add(baseDir);
            }
        }
        for (VirtualFile b : bases) {
            VirtualFile f = b.findFileByRelativePath(rel);
            if (f != null && !f.isDirectory()) {
                return f;
            }
        }
        return null;
    }
}
