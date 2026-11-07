#!/usr/bin/env python3
"""Testa a bandeja com o processo de verdade, sem ninguém na frente da tela.

Roda dentro de um Xvfb e de um D-Bus particular (ver tools/qa_bandeja.sh). Fecha
a janela pelo mesmo WM_DELETE_WINDOW de um gerenciador de janelas e faz o papel
do painel: registra o StatusNotifierWatcher, recebe o ícone do libappindicator e
clica nos itens do menu pelo dbusmenu. Só --demo: nunca conecta em lugar nenhum.
"""
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib
from Xlib import X, display, protocol
from Xlib.error import XError

BIN = sys.argv[1]
SLOW = "--slow" in sys.argv
WATCHER = "org.kde.StatusNotifierWatcher"
ICON_MAX_S = 5.0
passed = 0
failed = []


def check(name, ok, extra=""):
    global passed
    if ok:
        passed += 1
        print(f"  ok   {name}{'  (' + extra + ')' if extra else ''}")
    else:
        failed.append(name)
        print(f"  FALHA {name}{'  (' + extra + ')' if extra else ''}")


def wait_until(f, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        v = f()
        if v:
            return v
        time.sleep(0.05)
    return f()


# --- O painel falso ------------------------------------------------------------


class Watcher(dbus.service.Object):
    def __init__(self, bus):
        self.items = []
        self.name = dbus.service.BusName(WATCHER, bus)
        super().__init__(bus, "/StatusNotifierWatcher")
        # Como um painel de verdade: o protocolo não tem como tirar um ícone do
        # registro, ele só sai quando a conexão de quem o registrou fecha.
        self.owner_match = bus.add_signal_receiver(self.owner_changed, "NameOwnerChanged", "org.freedesktop.DBus")

    def owner_changed(self, name, old, new):
        if new:
            return
        for item in [i for i in self.items if i[0] == str(name)]:
            self.items.remove(item)
            self.StatusNotifierItemUnregistered(f"{item[0]}{item[1]}")

    @dbus.service.method(WATCHER, in_signature="s", sender_keyword="sender")
    def RegisterStatusNotifierItem(self, service, sender=None):
        path = service if service.startswith("/") else "/StatusNotifierItem"
        self.items.append((str(sender), str(path)))
        self.StatusNotifierItemRegistered(f"{sender}{path}")

    @dbus.service.method(WATCHER, in_signature="s")
    def RegisterStatusNotifierHost(self, service):
        pass

    @dbus.service.signal(WATCHER, signature="s")
    def StatusNotifierItemRegistered(self, service):
        pass

    @dbus.service.signal(WATCHER, signature="s")
    def StatusNotifierItemUnregistered(self, service):
        pass

    @dbus.service.signal(WATCHER, signature="")
    def StatusNotifierHostRegistered(self):
        pass

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="ss", out_signature="v")
    def Get(self, iface, prop):
        if prop == "IsStatusNotifierHostRegistered":
            return dbus.Boolean(True, variant_level=1)
        if prop == "ProtocolVersion":
            return dbus.Int32(0, variant_level=1)
        if prop == "RegisteredStatusNotifierItems":
            return dbus.Array([], signature="s", variant_level=1)
        raise dbus.exceptions.DBusException("org.freedesktop.DBus.Error.UnknownProperty")

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        return {
            "IsStatusNotifierHostRegistered": dbus.Boolean(True),
            "ProtocolVersion": dbus.Int32(0),
            "RegisteredStatusNotifierItems": dbus.Array([], signature="s"),
        }


class Panel:
    """Sobe e desce o painel no meio de um teste."""

    def __init__(self):
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SessionBus()
        self.watcher = None
        self.loop = GLib.MainLoop()
        threading.Thread(target=self.loop.run, daemon=True).start()

    def call(self, f):
        """Roda na thread do GLib e espera (o dbus-python não é para duas threads)."""
        done = threading.Event()
        box = {}

        def job():
            try:
                box["v"] = f()
            except Exception as e:  # o teste decide o que fazer
                box["e"] = e
            done.set()
            return False

        GLib.idle_add(job)
        done.wait(10)
        if "e" in box:
            raise box["e"]
        return box.get("v")

    def up(self):
        def go():
            if not self.watcher:
                self.watcher = Watcher(self.bus)

        self.call(go)

    def down(self):
        def go():
            if self.watcher:
                self.watcher.owner_match.remove()
                self.watcher.remove_from_connection()
                self.bus.release_name(WATCHER)
                self.watcher = None

        self.call(go)

    def items(self):
        return list(self.watcher.items) if self.watcher else []

    def clear(self):
        if self.watcher:
            self.watcher.items.clear()

    def prop(self, item, name):
        def go():
            o = self.bus.get_object(item[0], item[1])
            return dbus.Interface(o, dbus.PROPERTIES_IFACE).Get("org.kde.StatusNotifierItem", name)

        return self.call(go)

    def menu(self, item):
        """Os itens do menu do ícone: {rótulo: id}."""
        path = self.prop(item, "Menu")

        def go():
            o = self.bus.get_object(item[0], path)
            _, layout = dbus.Interface(o, "com.canonical.dbusmenu").GetLayout(0, -1, ["label"])
            return {str(ch[1].get("label", "")): int(ch[0]) for ch in layout[2]}

        return self.call(go)

    def click(self, item, menu_id):
        path = self.prop(item, "Menu")

        def go():
            o = self.bus.get_object(item[0], path)
            dbus.Interface(o, "com.canonical.dbusmenu").Event(menu_id, "clicked", dbus.String("", variant_level=1), 0)

        self.call(go)


# --- A janela no X -------------------------------------------------------------

dpy = display.Display()
root = dpy.screen().root
WM_PROTOCOLS = dpy.intern_atom("WM_PROTOCOLS")
WM_DELETE = dpy.intern_atom("WM_DELETE_WINDOW")


def windows():
    """Janelas do SigmaCord, mapeadas ou não."""
    out = []
    for w in root.query_tree().children:
        try:
            if w.get_wm_name() == "SigmaCord" or (w.get_wm_class() or ("", ""))[0] == "SigmaCord":
                out.append(w)
        except Exception:
            pass
    return out


def mapped():
    out = []
    for w in windows():
        try:
            if w.get_attributes().map_state == X.IsViewable:
                out.append(w)
        except Exception:
            pass
    dpy.sync()
    return out


def close_window():
    ws = mapped()
    if not ws:
        return False
    w = ws[0]
    ev = protocol.event.ClientMessage(window=w, client_type=WM_PROTOCOLS, data=(32, [WM_DELETE, X.CurrentTime, 0, 0, 0]))
    w.send_event(ev)
    dpy.sync()
    return True


def painted():
    """A janela tem desenho: várias cores, e não um retângulo liso."""
    ws = mapped()
    if not ws:
        return False
    try:
        g = ws[0].get_geometry()
        raw = ws[0].get_image(0, 0, g.width, g.height, X.ZPixmap, 0xFFFFFFFF).data
    except XError as e:
        # A janela pode sumir entre olhar e copiar. Se ficar assim, a checagem seguinte falha.
        print(f"  (a janela {ws[0].id:#x} recusou a cópia: {e.__class__.__name__}, geometria {g.width}x{g.height}+{g.x}+{g.y})" if "g" in locals() else "  (a janela sumiu)")
        return False
    return len({bytes(raw[i : i + 4]) for i in range(0, len(raw), 4 * 97)}) > 8


# --- Os processos --------------------------------------------------------------


running = []


class App:
    def __init__(self, home, *args, single=True):
        running.append(self)
        env = {k: v for k, v in os.environ.items() if k != "SIGMACORD_TOKEN"}
        env.update(
            HOME=str(home),
            XDG_CONFIG_HOME=str(home / "config"),
            XDG_CACHE_HOME=str(home / "cache"),
            XDG_RUNTIME_DIR=str(home),
            SDL_VIDEO_DRIVER="x11",
            GDK_BACKEND="x11",
            SIGMACORD_RENDERER="software",
            SDL_AUDIO_DRIVER="dummy",
            SIGMACORD_NO_PICS="1",
        )
        env.pop("WAYLAND_DISPLAY", None)
        if single:
            env["SIGMACORD_INSTANCE"] = "1"
        self.log = tempfile.TemporaryFile()
        self.p = subprocess.Popen([BIN, "--demo", "--no-live", "--theme", "classico", *args], env=env, stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)

    def alive(self):
        return self.p.poll() is None

    def wait(self, timeout):
        try:
            return self.p.wait(timeout)
        except subprocess.TimeoutExpired:
            return None

    def output(self):
        self.log.seek(0)
        return self.log.read().decode(errors="replace")

    def cpu_ticks(self):
        f = Path(f"/proc/{self.p.pid}/stat").read_text().rsplit(")", 1)[1].split()
        return int(f[11]) + int(f[12])

    def pss_kb(self):
        for line in Path(f"/proc/{self.p.pid}/smaps_rollup").read_text().splitlines():
            if line.startswith("Pss:"):
                return int(line.split()[1])
        return 0

    def threads(self):
        return len(list(Path(f"/proc/{self.p.pid}/task").iterdir()))

    def kill(self):
        # O grupo inteiro: o aviso de erro do SDL pode ser um processo filho.
        try:
            os.killpg(self.p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.p.wait()


def helpers(a):
    """Os processos do ícone: filhos do app."""
    out = []
    try:
        kids = Path(f"/proc/{a.p.pid}/task/{a.p.pid}/children").read_text().split()
    except OSError:
        return out
    for k in kids:
        try:
            if b"--tray-helper" in Path(f"/proc/{k}/cmdline").read_bytes():
                out.append(int(k))
        except OSError:
            pass
    return out


def pss_of(pid):
    for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
        if line.startswith("Pss:"):
            return int(line.split()[1])
    return 0


def no_windows():
    """Espera as janelas de quem foi morto sumirem do X."""
    wait_until(lambda: not windows(), 5)


def fresh_home():
    d = Path(tempfile.mkdtemp(prefix="sigma-qa-"))
    (d / "config" / "sigmacord").mkdir(parents=True)
    return d


def start(home, *args, **kw):
    """Abre e espera a janela aparecer de verdade (já pintada)."""
    a = App(home, *args, **kw)
    # Pintada já tem o app de pé: antes disso, fechar seria sair (sem conexão).
    wait_until(lambda: painted() or not a.alive(), 20)
    time.sleep(1.0)
    return a


def cpu_percent(a, seconds):
    t0 = a.cpu_ticks()
    time.sleep(seconds)
    return (a.cpu_ticks() - t0) / os.sysconf("SC_CLK_TCK") / seconds * 100


panel = Panel()


def section(name):
    print(f"\n{name}")


def no_panel():
    section("sem painel: o SDL_CreateTray até funcionaria, mas fechar tem que sair")
    panel.down()
    home = fresh_home()
    a = start(home)
    check("a janela abriu", bool(mapped()))
    t = time.time()
    close_window()
    code = a.wait(5)
    check("fechar encerra o processo", code == 0, f"código {code}, {time.time() - t:.2f} s")
    check("sem passar pelo vigia", "encerramento demorou" not in a.output())
    a.kill()
    shutil.rmtree(home)


def option_off():
    section("com painel e a opção desligada")
    panel.up()
    panel.clear()
    home = fresh_home()
    (home / "config/sigmacord/settings.kdl").write_text("settings close_to_tray=#false\n")
    a = start(home)
    close_window()
    code = a.wait(5)
    check("fechar encerra o processo", code == 0, f"código {code}")
    check("nenhum ícone foi criado", not panel.items())
    a.kill()
    shutil.rmtree(home)


def full_flow():
    section("com painel: fechar, voltar e sair")
    panel.up()
    panel.clear()
    home = fresh_home()
    a = start(home)
    check("janela aberta: sem ícone", not panel.items())
    # O "digitando" da demonstração anima nos primeiros 10 s.
    time.sleep(12)
    pss_open = a.pss_kb()
    cpu_open = cpu_percent(a, 5)

    close_window()
    item = wait_until(panel.items, ICON_MAX_S)
    check("fechar põe o ícone na bandeja", bool(item))
    check("a janela some", wait_until(lambda: not mapped()) is True or not mapped())
    check("o processo continua", a.alive())
    if not item:
        a.kill()
        return
    item = item[-1]
    icon = panel.prop(item, "IconName")
    theme = panel.prop(item, "IconThemePath")
    check("o ícone é o nosso PNG", bool(icon), f"{theme}/{icon}")
    labels = panel.menu(item)
    check("o menu tem Abrir e Sair", len(labels) == 2, ", ".join(labels))

    time.sleep(2)
    cpu_hidden = cpu_percent(a, 10)
    check("escondido: quase nada de CPU", cpu_hidden < 1.0, f"{cpu_hidden:.2f}% com a janela escondida, {cpu_open:.2f}% com ela aberta")
    pss_hidden = a.pss_kb()
    print(f"       RAM (PSS): {pss_open} KB aberta, {pss_hidden} KB na bandeja")

    open_id = next(v for k, v in labels.items() if "SigmaCord" in k)
    quit_id = next(v for k, v in labels.items() if "SigmaCord" not in k)
    panel.click(item, open_id)
    check("Abrir volta a janela", bool(wait_until(mapped, 5)))
    time.sleep(1.0)
    check("voltou desenhada, não em branco", painted(), "")
    cpu_back = cpu_percent(a, 5)
    check("aberta de novo, sem o ícone, volta ao custo de antes", cpu_back < cpu_open + 0.5, f"{cpu_back:.2f}% agora, {cpu_open:.2f}% antes de ir para a bandeja")

    section("segundo SigmaCord")
    b = App(home)
    code = b.wait(8)
    check("com a janela aberta: o segundo sai sem abrir outra", code == 0 and len(mapped()) == 1, f"código {code}")
    panel.clear()
    close_window()
    wait_until(panel.items, ICON_MAX_S)
    check("escondeu de novo", wait_until(lambda: not mapped()) is True or not mapped())
    t = time.time()
    b = App(home)
    code = b.wait(8)
    check("com a janela na bandeja: o segundo sai", code == 0, f"código {code}, {time.time() - t:.2f} s")
    check("e o primeiro volta", bool(wait_until(mapped, 5)))
    check("sempre uma janela só", len(windows()) == 1, f"{len(windows())}")
    time.sleep(0.5)

    section("idas e voltas")
    ok = True
    icons = []
    panel.clear()
    for _ in range(5):
        ok = ok and close_window()
        ok = ok and bool(wait_until(panel.items, ICON_MAX_S))
        ok = ok and wait_until(lambda: not mapped(), 3) is True
        icons.append(len(panel.items()))
        b = App(home)
        ok = ok and b.wait(8) == 0
        ok = ok and bool(wait_until(mapped, 5))
        time.sleep(0.3)
        icons.append(len(panel.items()))
    check("5 vezes para a bandeja e de volta", ok and a.alive())
    check("nunca sobra ícone: um na bandeja, nenhum com a janela aberta", icons == [1, 0] * 5, str(icons))

    section("o processo do ícone")
    close_window()
    wait_until(panel.items, ICON_MAX_S)
    wait_until(lambda: not mapped(), 3)
    kids = helpers(a)
    check("na bandeja: um processo só para o ícone", len(kids) == 1, str(kids))
    gtk = "libgtk-3" in Path(f"/proc/{a.p.pid}/maps").read_text()
    check("o GTK fica fora do app", not gtk)
    if kids:
        print(f"       RAM (PSS) do processo do ícone: {pss_of(kids[0])} KB")
        os.kill(kids[0], signal.SIGKILL)
    check("o processo do ícone morreu: a janela volta", bool(wait_until(mapped, 5)))
    check("e o ícone sai do painel", wait_until(lambda: not panel.items(), 3) is True)
    check("o app segue vivo", a.alive())
    time.sleep(0.3)

    section("Sair no menu")
    panel.clear()
    close_window()
    item = wait_until(panel.items, ICON_MAX_S)[-1]
    labels = panel.menu(item)
    quit_id = next(v for k, v in labels.items() if "SigmaCord" not in k)
    threads = a.threads()
    t = time.time()
    panel.click(item, quit_id)
    code = a.wait(5)
    check("Sair encerra tudo", code == 0, f"código {code}, {time.time() - t:.2f} s, {threads} threads antes")
    check("sem passar pelo vigia", "encerramento demorou" not in a.output())
    check("sem erro na saída", "panic" not in a.output() and "Segmentation" not in a.output(), a.output()[-200:] if "panic" in a.output() else "")
    a.kill()

    kdl = (home / "config/sigmacord/settings.kdl").read_text()
    check("as configurações ficaram salvas", "close_to_tray=#true" in kdl and "video_volume=100" in kdl)

    section("depois de sair: a trava não fica presa")
    a = start(home)
    check("abre de novo normalmente", a.alive() and bool(mapped()))
    a.p.kill()
    a.p.wait()
    no_windows()
    a = start(home)
    check("depois de um kill -9, também", a.alive() and bool(mapped()))
    close_window()
    wait_until(panel.items, ICON_MAX_S)
    a.p.send_signal(signal.SIGTERM)
    check("SIGTERM com a janela escondida sai", a.wait(5) == 0)
    a.kill()
    shutil.rmtree(home)


def restarted():
    section("primeiro travado")
    panel.up()
    home = fresh_home()
    a = start(home)
    a.p.send_signal(signal.SIGSTOP)
    b = App(home)
    time.sleep(6.5)
    # Parado no aviso do sistema, sem conexão nenhuma (fica até alguém clicar).
    check("o segundo não abre o app; avisa", b.alive() and "primeiro quadro" not in b.output() and len(mapped()) >= 1)
    b.kill()
    a.p.send_signal(signal.SIGCONT)
    a.kill()
    no_windows()
    shutil.rmtree(home)

    section("--restarted")
    panel.up()
    panel.clear()
    home = fresh_home()
    a = start(home)
    close_window()
    wait_until(panel.items, ICON_MAX_S)
    wait_until(lambda: not mapped())
    # Toma o lugar do antigo sem chamar por ele: o antigo continua escondido.
    b = App(home, "--restarted")
    time.sleep(2)
    check("não acorda o antigo", not mapped() and b.alive())
    # O antigo sai (como depois de `restart_wanted`).
    item = panel.items()[-1]
    labels = panel.menu(item)
    t = time.time()
    panel.click(item, next(v for k, v in labels.items() if "SigmaCord" not in k))
    check("o antigo saiu", a.wait(5) == 0)
    check("o novo assume dentro dos 5 s", bool(wait_until(mapped, 8)) and b.alive(), f"{time.time() - t:.2f} s")
    time.sleep(1)
    c = App(home)
    check("um terceiro chama o novo", c.wait(8) == 0 and b.alive())
    b.kill()
    no_windows()

    # O antigo não sai nunca: depois dos 5 s o reiniciado desiste e chama por ele.
    a = start(home)
    panel.clear()
    close_window()
    wait_until(panel.items, ICON_MAX_S)
    wait_until(lambda: not mapped())
    t = time.time()
    b = App(home, "--restarted")
    code = b.wait(9)
    took = time.time() - t
    check("antigo de pé: desiste depois de ~5 s e não abre outra conexão", code == 0 and 4.5 < took < 8, f"código {code}, {took:.1f} s")
    check("e o antigo aparece", bool(wait_until(mapped, 3)))
    a.kill()
    shutil.rmtree(home)


def demo_not_gated():
    section("a demonstração sem SIGMACORD_INSTANCE roda ao lado (não pega a trava)")
    panel.up()
    home = fresh_home()
    a = start(home, single=False)
    b = start(home, single=False)
    check("duas ao mesmo tempo", a.alive() and b.alive() and len(mapped()) == 2, f"{len(mapped())} janelas")
    a.kill()
    b.kill()
    shutil.rmtree(home)


def panel_dies():
    section("o painel morre com a janela escondida (--slow)")
    panel.up()
    panel.clear()
    home = fresh_home()
    a = start(home)
    close_window()
    wait_until(panel.items, ICON_MAX_S)
    wait_until(lambda: not mapped())
    panel.down()
    t = time.time()
    back = bool(wait_until(mapped, 190))
    check("a janela volta sozinha", back and a.alive(), f"{time.time() - t:.0f} s")
    a.kill()
    shutil.rmtree(home)


try:
    no_panel()
    option_off()
    full_flow()
    restarted()
    demo_not_gated()
    if SLOW:
        panel_dies()
except Exception as e:
    import traceback

    traceback.print_exc()
    failed.append(f"o teste quebrou: {e}")
finally:
    for a in running:
        a.kill()

print(f"\n{passed} passaram, {len(failed)} falharam")
for f in failed:
    print(f"  - {f}")
sys.exit(1 if failed else 0)
