// Só os formatos que o Discord manda (WebP fica com a libwebp, em ui/images.zig).
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
// Nada maior que 8192×8192: uma imagem pequena comprimida não pode pedir
// gigabytes ao decodificar (o padrão do stb é 2^24 por lado).
#define STBI_MAX_DIMENSIONS 8192
#include "stb_image.h"

// --- SigmaCord: GIF quadro a quadro -------------------------------------
// O stbi_load_gif_from_memory guarda todos os quadros em tamanho cheio (um
// GIF de 300 quadros passa fácil de 200 MB). Aqui cada quadro vai para o
// callback assim que sai, e só os dois últimos ficam guardados (o descarte
// "restaurar ao anterior" precisa do quadro de dois atrás).
typedef int (*sigma_gif_cb)(void *ud, const unsigned char *rgba, int w, int h, int delay_ms);

int sigma_gif_frames(const unsigned char *data, int len, sigma_gif_cb cb, void *ud)
{
   stbi__context s;
   stbi__gif g;
   stbi_uc *prev = 0, *prev2 = 0;
   size_t stride = 0;
   int comp = 0, n = 0;
   stbi__start_mem(&s, data, len);
   if (!stbi__gif_test(&s)) return 0;
   memset(&g, 0, sizeof(g));
   for (;;) {
      stbi_uc *u = stbi__gif_load_next(&s, &g, &comp, 4, n >= 2 ? prev2 : 0);
      if (!u || u == (stbi_uc *) &s) break;
      if (!stride) {
         stride = (size_t) g.w * g.h * 4;
         prev = (stbi_uc *) STBI_MALLOC(stride);
         prev2 = (stbi_uc *) STBI_MALLOC(stride);
         if (!prev || !prev2) break;
      }
      {
         stbi_uc *t = prev2;
         prev2 = prev;
         prev = t;
         memcpy(prev, u, stride);
      }
      ++n;
      if (!cb(ud, u, g.w, g.h, g.delay)) break;
   }
   STBI_FREE(g.out);
   STBI_FREE(g.history);
   STBI_FREE(g.background);
   STBI_FREE(prev);
   STBI_FREE(prev2);
   return n;
}
