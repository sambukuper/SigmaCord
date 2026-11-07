#!/usr/bin/env python3
"""Quadros de verdade: o app sem a bandeira de QA, numa janela X11 dentro de um Xvfb,
com o mouse movido por XTEST. Nada aparece na tela de quem roda e nada conecta em
lugar nenhum (--demo). Confere o que o QA não vê, porque lá todo quadro é desenhado:
quadro igual não vai para a tela, o que muda continua chegando, a janela escondida
volta inteira e solta as imagens.

  tools/qa_quadros.py BIN [--slow | --only-slow] [--compare OUTRO_BIN]

--slow: inclui as imagens saindo da memória (mais de 2 min com a janela escondida).
--only-slow: só essa parte.
--compare: mede o custo do mouse nos dois executáveis, só para mostrar (não reprova).
"""
import ctypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

DISP = ":78"
W, H = 1280, 800

X = ctypes.CDLL("libX11.so.6")
T = ctypes.CDLL("libXtst.so.6")
X.XOpenDisplay.restype = ctypes.c_void_p
X.XOpenDisplay.argtypes = [ctypes.c_char_p]
X.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
X.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X.XDefaultRootWindow.restype = ctypes.c_ulong
X.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint)]
X.XUnmapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
X.XMapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
T.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
T.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]

failed = 0


def check(name, ok, detail=""):
    global failed
    print(f"  {'ok  ' if ok else 'FALHOU'} {name}" + (f" ({detail})" if detail else ""), flush=True)
    if not ok:
        failed += 1


class Xv:
    def __init__(self):
        self.proc = subprocess.Popen(["Xvfb", DISP, "-screen", "0", f"{W}x{H}x24", "-nolisten", "tcp"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)
        self.d = X.XOpenDisplay(DISP.encode())
        assert self.d, "sem Xvfb"

    def close(self):
        self.proc.terminate()
        self.proc.wait(5)

    def move(self, x, y):
        T.XTestFakeMotionEvent(self.d, 0, x, y, 0)
        X.XSync(self.d, 0)

    def click(self, x, y):
        self.move(x, y)
        time.sleep(0.2)
        T.XTestFakeButtonEvent(self.d, 1, 1, 0)
        X.XSync(self.d, 0)
        time.sleep(0.1)
        T.XTestFakeButtonEvent(self.d, 1, 0, 0)
        X.XSync(self.d, 0)

    def shot(self):
        """Os pixels da tela inteira."""
        return subprocess.run(["import", "-display", DISP, "-window", "root", "-depth", "8", "RGB:-"], capture_output=True, check=True).stdout

    def top_window(self):
        root, parent = ctypes.c_ulong(), ctypes.c_ulong()
        kids, n = ctypes.POINTER(ctypes.c_ulong)(), ctypes.c_uint()
        X.XQueryTree(self.d, X.XDefaultRootWindow(self.d), ctypes.byref(root), ctypes.byref(parent), ctypes.byref(kids), ctypes.byref(n))
        return kids[n.value - 1] if n.value else None

    def set_mapped(self, win, mapped):
        (X.XMapWindow if mapped else X.XUnmapWindow)(self.d, win)
        X.XSync(self.d, 0)


def differ(a, b):
    """Quantos pixels mudaram."""
    if len(a) != len(b):
        return max(len(a), len(b)) // 3
    return sum(1 for i in range(0, len(a), 3) if a[i:i + 3] != b[i:i + 3])


open_apps = []


class App:
    def __init__(self, binary, pics):
        self.tmp = tempfile.mkdtemp(prefix="sigma-quadros.")
        keep = {k: v for k, v in os.environ.items() if k not in ("WAYLAND_DISPLAY", "SIGMACORD_TOKEN", "DBUS_SESSION_BUS_ADDRESS")}
        keep.update(DISPLAY=DISP, SDL_VIDEO_DRIVER="x11", SIGMACORD_RENDERER="software", SDL_AUDIODRIVER="dummy",
                    XDG_CONFIG_HOME=self.tmp + "/c", XDG_CACHE_HOME=self.tmp + "/k", XDG_RUNTIME_DIR=self.tmp, HOME=self.tmp)
        if not pics:
            keep["SIGMACORD_NO_PICS"] = "1"
        self.log_path = self.tmp + "/log"
        self.log = open(self.log_path, "w")
        self.proc = subprocess.Popen([binary, "--demo", "--no-live", "--stats"], env=keep, stdout=self.log, stderr=self.log)
        open_apps.append(self)
        # O "digitando" da demonstração anima nos primeiros 10 s.
        time.sleep(12)

    def close(self):
        open_apps.remove(self)
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ticks(self):
        s = open(f"/proc/{self.proc.pid}/stat").read()
        r = s[s.rindex(")") + 2:].split()
        return int(r[11]) + int(r[12])

    def anon_kb(self):
        for line in open(f"/proc/{self.proc.pid}/smaps_rollup"):
            if line.startswith("Pss_Anon:"):
                return int(line.split()[1])
        return 0

    def windows(self):
        """As janelas de 2 s do --stats: (quadros, sem desenhar)."""
        out = []
        for line in open(self.log_path):
            m = re.search(r"(\d+) quadros em 2 s(?:, (\d+) sem desenhar)?", line)
            if m:
                out.append((int(m.group(1)), int(m.group(2) or 0)))
        return out


def wiggle(xv, x, y, seconds, hz=250):
    """Mouse andando sem sair de cima do mesmo lugar."""
    t0 = time.time()
    i = 0
    while time.time() - t0 < seconds:
        i += 1
        xv.move(x + i % 4, y + (i // 4) % 4)
        time.sleep(1 / hz)


def mouse_cost(xv, app, x, y, seconds=8):
    a = app.ticks()
    seen = len(app.windows())
    t0 = time.time()
    wiggle(xv, x, y, seconds)
    dt = time.time() - t0
    cpu = (app.ticks() - a) / dt
    time.sleep(0.3)
    # A primeira janela pode pegar o começo parado; a última, o fim.
    w = app.windows()[seen + 1:-1] or app.windows()[seen:]
    built = sum(n for n, _ in w)
    skipped = sum(k for _, k in w)
    return cpu, built / max(len(w) * 2, 1), skipped, built


def main():
    args = sys.argv[1:]
    binary = os.path.abspath(args[0])
    only_slow = "--only-slow" in args
    slow = only_slow or "--slow" in args
    compare = os.path.abspath(args[args.index("--compare") + 1]) if "--compare" in args else None
    if not shutil.which("Xvfb") or not shutil.which("import"):
        print("precisa de Xvfb e ImageMagick")
        return 2

    xv = Xv()
    try:
        cx, cy = 800, 420
        if not only_slow:
            print("mouse passando sem mudar nada", flush=True)
            app = App(binary, pics=False)
            # A área das mensagens: o mesmo lugar, sem atravessar nada.
            xv.move(cx, cy)
            time.sleep(1)
            cpu, fps, skipped, built = mouse_cost(xv, app, cx, cy)
            print(f"  {cpu:.1f}% de um núcleo, {fps:.0f} quadros/s, {skipped} de {built} sem desenhar")
            check("mouse sozinho fica em ~30 quadros por segundo", 0 < fps <= 36, f"{fps:.0f}")
            check("quase todos os quadros saem sem desenhar", built > 0 and skipped >= built * 0.8, f"{skipped}/{built}")

            print("o que muda continua chegando à tela", flush=True)
            time.sleep(0.6)
            base = xv.shot()
            # Outra mensagem, mais acima: o destaque precisa acompanhar.
            xv.move(cx, cy - 170)
            time.sleep(0.4)
            moved = xv.shot()
            check("o destaque do mouse aparece", differ(base, moved) > 50, f"{differ(base, moved)} pixels")
            xv.move(cx, cy)
            time.sleep(0.4)
            back = xv.shot()
            check("e some quando o mouse volta", differ(base, back) == 0, f"{differ(base, back)} pixels")
            time.sleep(1)
            check("parado, a tela não muda", differ(back, xv.shot()) == 0)
            xv.click(150, 300)
            time.sleep(0.5)
            check("clicar num canal muda a tela", differ(back, xv.shot()) > 500)
            time.sleep(0.8)
            before_hide = xv.shot()

            print("janela escondida volta inteira", flush=True)
            win = xv.top_window()
            check("achou a janela", win is not None)
            xv.set_mapped(win, False)
            time.sleep(0.8)
            hidden = xv.shot()
            check("escondida, a tela fica vazia", differ(before_hide, hidden) > 10000)
            xv.set_mapped(win, True)
            time.sleep(1)
            check("ao voltar, o desenho volta igual", differ(before_hide, xv.shot()) == 0, f"{differ(before_hide, xv.shot())} pixels")
            app.close()

        if compare and not only_slow:
            print("comparando com o outro executável (só para mostrar)", flush=True)
            old = App(compare, pics=False)
            xv.move(cx, cy)
            time.sleep(1)
            old_cpu, old_fps, _, _ = mouse_cost(xv, old, cx, cy)
            print(f"  outro: {old_cpu:.1f}% de um núcleo, {old_fps:.0f} quadros/s")
            print(f"  este:  {cpu:.1f}% de um núcleo, {fps:.0f} quadros/s")
            old.close()

        if slow:
            print("imagens saem da memória com a janela escondida", flush=True)
            app = App(binary, pics=True)
            xv.move(cx, cy)
            time.sleep(1)
            # Sobe até as imagens grandes e o GIF da demonstração, que precisam estar carregados.
            for _ in range(40):
                T.XTestFakeButtonEvent(xv.d, 4, 1, 0)
                T.XTestFakeButtonEvent(xv.d, 4, 0, 0)
                X.XSync(xv.d, 0)
                time.sleep(0.05)
            time.sleep(5)
            win = xv.top_window()
            with_images = app.anon_kb()
            before = xv.shot()
            xv.set_mapped(win, False)
            # Solta depois de 1 min escondida, na primeira vez que o app acordar (no máximo mais 1 min).
            time.sleep(128)
            released = app.anon_kb()
            print(f"  memória anônima: {with_images} KB antes, {released} KB depois")
            freed = 0
            for line in open(app.log_path):
                m = re.search(r"janela escondida: soltou (\d+) KB", line)
                if m:
                    print("  " + line.strip())
                    freed += int(m.group(1))
            check("as imagens grandes saem", freed > 2048, f"{freed} KB")
            # O software guarda as texturas na RAM: o que saiu tem que voltar ao sistema.
            check("a memória volta ao sistema", with_images - released >= freed // 2, f"{with_images - released} KB")
            xv.set_mapped(win, True)
            time.sleep(4)
            changed = differ(before, xv.shot())
            # O GIF da demonstração pode estar em outro quadro: só ele pode ter mudado.
            check("ao voltar, as imagens voltam", changed < W * H // 8, f"{changed} pixels")
            app.close()
    finally:
        for a in list(open_apps):
            a.close()
        xv.close()

    print(f"{'tudo certo' if failed == 0 else f'{failed} falharam'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
