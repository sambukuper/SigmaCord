// As bindings em C do ImGui deixam ImFontBaked opaco (tem campos de bits), e a
// linha de base dos runs do `label` precisa do Ascent de cada fonte e tamanho.
#include "imgui.h"
#include "imgui_internal.h"

extern "C" float sigma_font_ascent(ImFont* font, float size) {
    return font->GetFontBaked(size)->Ascent;
}

// Onde o ImGui quebra uma linha da caixa de texto com WordWrap (InputTextLineIndexBuild).
extern "C" const char* sigma_input_wrap(ImFont* font, float size, const char* s, const char* end, float wrap) {
    return ImFontCalcWordWrapPositionEx(font, size, s, end, wrap, ImDrawTextFlags_WrapKeepBlanks);
}

// Põe uma fonte já mesclada na posição `pos` de `font`: para um mesmo caractere, vence a
// que vem primeiro. A ordem que vale é a da lista do atlas (ImFontAtlasBuildUpdatePointers).
extern "C" void sigma_font_source_to(ImFont* font, const void* data, int font_no, int pos) {
    ImFontAtlas* atlas = font->OwnerAtlas;
    // Os dados de cada tamanho seguem a ordem das fontes: esses saem antes de mudar.
    ImFontAtlasFontDiscardBakes(atlas, font, 0);
    int to = -1, from = -1, seen = 0;
    for (int i = 0; i < atlas->Sources.Size; i++) {
        const ImFontConfig& src = atlas->Sources[i];
        if (src.DstFont != font) continue;
        if (seen == pos) to = i;
        if (src.FontData == data && (int)src.FontNo == font_no) from = i;
        seen++;
    }
    if (to < 0 || from <= to) return;
    ImFontConfig moved = atlas->Sources[from];
    memmove(&atlas->Sources[to + 1], &atlas->Sources[to], (size_t)(from - to) * sizeof(ImFontConfig));
    atlas->Sources[to] = moved;
    ImFontAtlasBuildUpdatePointers(atlas);
}

// Quantas entradas a tabela de caracteres dessa fonte+tamanho tem (o QA confere
// que um emoji não reserva a tabela até U+1F600).
extern "C" int sigma_font_index_size(ImFont* font, float size) {
    return font->GetFontBaked(size)->IndexLookup.Size;
}
