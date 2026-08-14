package org.rosegold.ide;

import com.intellij.codeInsight.completion.CompletionContributor;
import com.intellij.codeInsight.completion.CompletionParameters;
import com.intellij.codeInsight.completion.CompletionProvider;
import com.intellij.codeInsight.completion.CompletionResultSet;
import com.intellij.codeInsight.completion.CompletionType;
import com.intellij.codeInsight.lookup.LookupElementBuilder;
import com.intellij.patterns.PlatformPatterns;
import com.intellij.util.ProcessingContext;
import org.jetbrains.annotations.NotNull;

public final class RoseGoldCompletionContributor extends CompletionContributor {
    private static final String[] KEYWORDS = {
            "import", "class", "struct", "extends", "uses", "func", "var", "const",
            "enum", "if", "elif", "else", "match", "for", "in", "while", "break",
            "continue", "return", "pass", "nil", "pub", "private", "static", "true",
            "false", "and", "or", "not", "signal", "try", "catch", "raise",
            "int", "float", "str", "bool", "void", "any", "list", "map",
    };

    private static final String[] BUILTINS = {
            "print", "echo", "len", "range", "str", "int", "float", "push", "pop",
            "keys", "values", "has", "connect", "emit", "abs", "min", "max", "upper",
            "lower", "split", "join", "contains", "sort", "reverse", "trim",
            "starts_with", "ends_with", "find", "replace", "map", "filter", "reduce",
            "sqrt", "pow", "floor", "ceil", "round",
    };

    public RoseGoldCompletionContributor() {
        extend(CompletionType.BASIC,
                PlatformPatterns.psiElement().withLanguage(RoseGoldLanguage.INSTANCE),
                new CompletionProvider<>() {
                    @Override
                    protected void addCompletions(@NotNull CompletionParameters parameters,
                                                  @NotNull ProcessingContext context,
                                                  @NotNull CompletionResultSet result) {
                        for (String kw : KEYWORDS) {
                            result.addElement(LookupElementBuilder.create(kw).bold());
                        }
                        for (String b : BUILTINS) {
                            result.addElement(LookupElementBuilder.create(b).withTypeText("builtin", true));
                        }
                    }
                });
    }
}
