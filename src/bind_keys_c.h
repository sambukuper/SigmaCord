// Só os códigos de tecla do ImGui para ui/bind_keys.zig: os testes puros
// (zig build test) não têm as bibliotecas do app nem os cabeçalhos do SDL,
// então não podem usar src/c.h inteiro. dcimgui.h é C puro e traz o enum
// ImGuiKey inteiro.
#include "dcimgui.h"
