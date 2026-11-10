#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Astra Linux Helper — диагностика и исправление типичных проблем Astra Linux SE 1.6 / 1.7 / 1.8.
1) «Проверить всё» — проверки (astra-doctor.sh), итог и пошаговые инструкции; система не меняется.
2) Вкладка «Исправления» — готовые команды с галочками; выполняются только отмеченные,
   после подтверждения и с резервной копией настроек в /var/backups/astra-helper/.
3) Вкладка «Домен» — поиск контроллеров с замером отклика, выбор контроллера,
   проверка перед вводом и сам ввод в домен (astra-domain.sh).
Текст на всех вкладках можно выделять и копировать (Ctrl+C, Ctrl+A, правая кнопка мыши).
Совместимо с Python 3.5+ (Astra 1.6) и Python 3.11 (Astra 1.8). Нужен пакет python3-tk.
"""
import os
import re
import sys
import threading
import subprocess
import base64
import shlex
import tempfile

try:
    import queue
    import tkinter as tk
    from tkinter import ttk, messagebox, simpledialog, filedialog
except ImportError:
    print("Не найден tkinter (пакет python3-tk). Запустите установку: sudo ./install.sh")
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "astra-doctor.sh")
DOMSCRIPT = os.path.join(HERE, "astra-domain.sh")
VERSION = "1.3"

MODULES = [
    ("sys", "Диск, память, службы, время"),
    ("apt", "Пакеты и репозитории"),
    ("sec", "Средства защиты Astra"),
    ("gui", "Графика и вход"),
    ("net", "Сеть"),
    ("print", "Печать"),
    ("sound", "Звук"),
    ("ad", "Домен AD / SSSD"),
]

ANSI = re.compile(r'\x1b\[[0-9;]*m')
SECTION_RE = re.compile(r'^==\s*(.+?)\s*==\s*$')
ITEM_RE = re.compile(r'^\s*\[(OK|ОШИБКА|ВНИМАНИЕ)\]\s*(.*)$')
FIX_RE = re.compile(r'^\s*\[FIX\] ?(.*)$')
SYS_RE = re.compile(r'^\s*\[SYS\]\s*(.*)$')
ICON = {"OK": "✔", "ВНИМАНИЕ": "⚠", "ОШИБКА": "✖", "RUN": "…", "FIX": "→"}
RANK = {"OK": 0, "ВНИМАНИЕ": 1, "ОШИБКА": 2}

# ---------------------------------------------------------------------------
# Копирование: все текстовые поля только для чтения, но текст в них выделяется
# и копируется (Ctrl+C, Ctrl+A, правая кнопка мыши) — в любой раскладке клавиатуры.
# ---------------------------------------------------------------------------
NAV_KEYS = ("Left", "Right", "Up", "Down", "Prior", "Next", "Home", "End", "Shift_L", "Shift_R",
            "Control_L", "Control_R", "Tab", "ISO_Left_Tab", "F10", "Menu")


def _is_key(e, keycode, names):
    # keycode — физическая клавиша (X11), поэтому Ctrl+С работает и в русской раскладке
    return e.keycode == keycode or e.keysym.lower() in names


def to_clipboard(widget, text):
    if text:
        widget.clipboard_clear()
        widget.clipboard_append(text)
        widget.update_idletasks()


def make_readonly(t):
    """Text: запрет правки, но выделение и копирование работают."""
    def sel():
        try:
            return t.get("sel.first", "sel.last")
        except tk.TclError:
            return ""

    def copy(_e=None):
        to_clipboard(t, sel())
        return "break"

    def select_all(_e=None):
        t.tag_add("sel", "1.0", "end-1c")
        return "break"

    def on_key(e):
        if e.state & 0x4:
            if _is_key(e, 54, ("c", "cyrillic_es", "insert")):
                return copy()
            if _is_key(e, 38, ("a", "cyrillic_ef")):
                return select_all()
            return "break"
        return None if e.keysym in NAV_KEYS else "break"

    t.bind("<Key>", on_key)
    for ev in ("<<Paste>>", "<<Cut>>", "<<Clear>>", "<<PasteSelection>>", "<Button-2>", "<ButtonRelease-2>"):
        t.bind(ev, lambda e: "break")
    menu = tk.Menu(t, tearoff=0)
    menu.add_command(label="Копировать", command=copy)
    menu.add_command(label="Копировать всё", command=lambda: to_clipboard(t, t.get("1.0", "end-1c")))
    menu.add_separator()
    menu.add_command(label="Выделить всё", command=select_all)

    def popup(e):
        t.focus_set()
        menu.entryconfigure(0, state="normal" if sel() else "disabled")
        menu.tk_popup(e.x_root, e.y_root)
    t.bind("<Button-3>", popup)


def tree_lines(tree, iid, depth=0, seen=None):
    if seen is not None:
        if iid in seen:
            return []
        seen.add(iid)
    vals = [str(v) for v in tree.item(iid, "values") if str(v)]
    out = ["  " * depth + tree.item(iid, "text").strip() + ("\t" + "\t".join(vals) if vals else "")]
    for c in tree.get_children(iid):
        out += tree_lines(tree, c, depth + 1, seen)
    return out


def make_tree_copyable(tree):
    """Treeview: Ctrl+C копирует выделенные строки (с вложенными), правая кнопка — меню."""
    def copy_sel(_e=None):
        seen, rows = set(), []
        for iid in tree.selection():
            rows += tree_lines(tree, iid, 0, seen)
        to_clipboard(tree, "\n".join(rows))
        return "break"

    def copy_all():
        rows = []
        for iid in tree.get_children(""):
            rows += tree_lines(tree, iid)
        to_clipboard(tree, "\n".join(rows))

    def on_key(e):
        if e.state & 0x4:
            if _is_key(e, 54, ("c", "cyrillic_es", "insert")):
                return copy_sel()
            if _is_key(e, 38, ("a", "cyrillic_ef")) and str(tree.cget("selectmode")) == "extended":
                tree.selection_set(tree.get_children(""))
                return "break"
        return None

    tree.bind("<Control-Key>", on_key)
    menu = tk.Menu(tree, tearoff=0)
    menu.add_command(label="Копировать строку", command=copy_sel)
    menu.add_command(label="Копировать всё", command=copy_all)

    def popup(e):
        iid = tree.identify_row(e.y)
        if iid and iid not in tree.selection():
            tree.selection_set(iid)
        tree.focus_set()
        menu.entryconfigure(0, state="normal" if tree.selection() else "disabled")
        menu.tk_popup(e.x_root, e.y_root)
    tree.bind("<Button-3>", popup)


def make_label_copyable(lbl, var):
    menu = tk.Menu(lbl, tearoff=0)
    menu.add_command(label="Копировать", command=lambda: to_clipboard(lbl, var.get()))
    lbl.bind("<Button-3>", lambda e: menu.tk_popup(e.x_root, e.y_root))


class App:
    def __init__(self, root):
        self.root = root
        root.title("Astra Linux Helper %s — диагностика" % VERSION)
        root.geometry("1040x700")
        self.q = queue.Queue()
        self.running = False
        self.reset_state()

        top = ttk.Frame(root, padding=(8, 8, 8, 2))
        top.pack(fill="x")
        ttk.Label(top, text="Домен:").pack(side="left")
        self.domain = tk.StringVar()
        ttk.Entry(top, textvariable=self.domain, width=20).pack(side="left", padx=(4, 10))
        ttk.Label(top, text="Пользователь:").pack(side="left")
        self.user = tk.StringVar()
        ttk.Entry(top, textvariable=self.user, width=14).pack(side="left", padx=(4, 10))
        self.btn = ttk.Button(top, text="▶  Проверить всё", command=self.start)
        self.btn.pack(side="left")
        self.save_btn = ttk.Button(top, text="Сохранить отчёт", command=self.save, state="disabled")
        self.save_btn.pack(side="left", padx=6)

        mods = ttk.Frame(root, padding=(8, 2))
        mods.pack(fill="x")
        ttk.Label(mods, text="Проверять:").grid(row=0, column=0, sticky="w", padx=(0, 6))
        self.mod_vars = {}
        for n, (key, title) in enumerate(MODULES):
            v = tk.BooleanVar(value=True)
            self.mod_vars[key] = v
            ttk.Checkbutton(mods, text=title, variable=v).grid(row=n // 4, column=1 + n % 4, sticky="w", padx=4)

        self.sysinfo = tk.StringVar(value="Домен и пользователь — необязательно (домен определится сам). Нажмите «Проверить всё».")
        lbl = ttk.Label(root, textvariable=self.sysinfo, padding=(8, 2), foreground="#444")
        lbl.pack(fill="x")
        make_label_copyable(lbl, self.sysinfo)
        self.pb = ttk.Progressbar(root, mode="indeterminate")
        self.pb.pack(fill="x", padx=8, pady=4)

        nb = ttk.Notebook(root)
        nb.pack(fill="both", expand=True, padx=8, pady=(0, 8))
        self.nb = nb

        f1 = ttk.Frame(nb)
        nb.add(f1, text="Проверки")
        self.tree = ttk.Treeview(f1, show="tree")
        make_tree_copyable(self.tree)
        sb = ttk.Scrollbar(f1, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        for tag, color in (("OK", "#1a7f37"), ("ВНИМАНИЕ", "#9a6700"), ("ОШИБКА", "#cf222e"),
                           ("RUN", "#555555"), ("FIX", "#0b5cad")):
            self.tree.tag_configure(tag, foreground=color)

        f2 = ttk.Frame(nb)
        self.tab_summary = f2
        nb.add(f2, text="Итог и что сделать")
        self.summary = self._text(f2)

        f3 = ttk.Frame(nb)
        nb.add(f3, text="Полный лог")
        self.log = self._text(f3)

        self.root.after(100, self.poll)

    def reset_state(self):
        self.log_lines = []
        self.sections = []     # [{'title','items':[{'lvl','msg','fix':[]}]}]
        self.sys_lines = []
        self.cur = None
        self.cur_node = None
        self.last_item = None
        self.last_node = None
        self.in_summary = False
        self.report_path = ""

    def _text(self, parent):
        t = tk.Text(parent, wrap="word", font=("DejaVu Sans Mono", 10), padx=8, pady=6)
        sb = ttk.Scrollbar(parent, orient="vertical", command=t.yview)
        t.configure(yscrollcommand=sb.set)
        t.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        t.tag_configure("OK", foreground="#1a7f37")
        t.tag_configure("ВНИМАНИЕ", foreground="#9a6700")
        t.tag_configure("ОШИБКА", foreground="#cf222e")
        t.tag_configure("FIX", foreground="#0b5cad")
        t.tag_configure("h", font=("DejaVu Sans", 13, "bold"))
        t.tag_configure("h2", font=("DejaVu Sans", 11, "bold"))
        make_readonly(t)
        return t

    def _append(self, t, text, tag=None):
        t.insert("end", text, tag)
        t.see("end")

    def _clear(self, t):
        t.delete("1.0", "end")

    # ---------------- запуск ----------------
    def start(self):
        if self.running or getattr(self, "dom_busy", False):
            return
        if not os.path.isfile(SCRIPT):
            messagebox.showerror("Ошибка", "Не найден файл проверок:\n" + SCRIPT)
            return
        only = [k for k, _ in MODULES if self.mod_vars[k].get()]
        if not only:
            messagebox.showinfo("Нечего проверять", "Отметьте хотя бы один раздел.")
            return
        ok, pw = self.ask_password()
        if not ok:
            return
        self.running = True
        self.btn.configure(state="disabled")
        self.save_btn.configure(state="disabled")
        for i in self.tree.get_children():
            self.tree.delete(i)
        self._clear(self.log)
        self._clear(self.summary)
        self.reset_state()
        self.sysinfo.set("Идёт проверка… (до пары минут, если сервера в сети не отвечают)")
        self.pb.start(12)
        self.nb.select(0)
        args = ["--only", ",".join(only)]
        if self.domain.get().strip():
            args += ["--domain", self.domain.get().strip()]
        if self.user.get().strip():
            args += ["--user", self.user.get().strip()]
        args += self.extra_args
        threading.Thread(target=self.worker, args=(pw, args), daemon=True).start()

    extra_args = []

    def extra_report(self):
        return ""

    def ask_password(self):
        """(ok, пароль): пароль None — уже root; ok False — пользователь отменил."""
        if os.geteuid() == 0:
            return True, None
        pw = simpledialog.askstring(
            "Нужны права администратора",
            "Нужны права root (чтение и изменение системных настроек).\n"
            "Введите пароль sudo для пользователя %s:" % os.environ.get("USER", ""),
            show="*", parent=self.root)
        return (pw is not None), pw

    def on_event(self, kind, val):
        pass

    def worker(self, pw, args):
        try:
            if pw is None:
                cmd = ["bash", SCRIPT] + args
            else:
                cmd = ["sudo", "-S", "-p", "", "bash", SCRIPT] + args
            p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT)
            if pw is not None:
                try:
                    p.stdin.write((pw + "\n").encode("utf-8"))
                except Exception:
                    pass
            p.stdin.close()
            for raw in iter(p.stdout.readline, b""):
                self.q.put(("line", ANSI.sub("", raw.decode("utf-8", "replace")).rstrip("\n")))
            p.wait()
            self.q.put(("done", p.returncode))
        except Exception as e:
            self.q.put(("line", "Ошибка запуска: %s" % e))
            self.q.put(("done", -1))

    # ---------------- разбор вывода ----------------
    def poll(self):
        try:
            while True:
                kind, val = self.q.get_nowait()
                if kind == "line":
                    self.handle(val)
                elif kind == "done":
                    self.finish(val)
                else:
                    self.on_event(kind, val)
        except queue.Empty:
            pass
        self.root.after(100, self.poll)

    def handle(self, line):
        self.log_lines.append(line)
        m_item = ITEM_RE.match(line)
        m_fix = FIX_RE.match(line)
        tag = m_item.group(1) if m_item else ("FIX" if m_fix else None)
        self._append(self.log, line + "\n", tag)
        if "Полный отчёт:" in line:
            self.report_path = line.split("Полный отчёт:", 1)[1].strip()
        if self.in_summary:
            return
        m_sys = SYS_RE.match(line)
        if m_sys:
            if m_sys.group(1).startswith("Домен: ") and not self.domain.get().strip():
                self.domain.set(m_sys.group(1)[7:].strip())
            self.sys_lines.append(m_sys.group(1))
            self.sysinfo.set("   •   ".join(self.sys_lines))
            return
        m = SECTION_RE.match(line)
        if m:
            title = m.group(1)
            self._close_section()
            if title.startswith("ИТОГ"):
                self.in_summary = True
                return
            self.cur = {"title": title, "items": [], "rank": -1}
            self.sections.append(self.cur)
            self.cur_node = self.tree.insert("", "end", text="%s  %s" % (ICON["RUN"], title),
                                             open=False, tags=("RUN",))
            self.last_item = None
            return
        if m_fix and self.last_item is not None:
            self.last_item["fix"].append(m_fix.group(1))
            self.tree.insert(self.last_node, "end", text="   %s %s" % (ICON["FIX"], m_fix.group(1)), tags=("FIX",))
            return
        if not m_item or self.cur is None:
            return
        lvl, msg = m_item.group(1), m_item.group(2)
        item = {"lvl": lvl, "msg": msg, "fix": []}
        self.cur["items"].append(item)
        self.cur["rank"] = max(self.cur["rank"], RANK[lvl])
        self.last_item = item
        self.last_node = self.tree.insert(self.cur_node, "end", text="%s  %s" % (ICON[lvl], msg),
                                          tags=(lvl,), open=False)
        if lvl != "OK":
            self.tree.item(self.cur_node, open=True)

    def _close_section(self):
        if self.cur is None:
            return
        lvl = {-1: "OK", 0: "OK", 1: "ВНИМАНИЕ", 2: "ОШИБКА"}[self.cur["rank"]]
        self.tree.item(self.cur_node, text="%s  %s" % (ICON[lvl], self.cur["title"]), tags=(lvl,))
        self.cur = None

    def finish(self, rc):
        self._close_section()
        self.pb.stop()
        self.running = False
        self.btn.configure(state="normal")
        if not self.sections:
            joined = "\n".join(self.log_lines)
            self.sysinfo.set("Проверка не запустилась.")
            if re.search(r"incorrect password|Sorry|неверн|attempt", joined, re.I):
                messagebox.showerror("Ошибка", "Неверный пароль sudo (или пользователь не входит в группу администраторов).")
            else:
                messagebox.showerror("Ошибка", "Не удалось запустить проверку:\n\n" + joined[-800:])
            return
        self.save_btn.configure(state="normal")
        self.build_summary()
        self.nb.select(self.tab_summary)

    def build_summary(self):
        t = self.summary
        errs = sum(1 for s in self.sections for i in s["items"] if i["lvl"] == "ОШИБКА")
        warns = sum(1 for s in self.sections for i in s["items"] if i["lvl"] == "ВНИМАНИЕ")
        if self.sys_lines:
            self._append(t, "\n".join(self.sys_lines) + "\n\n")
        if errs == 0 and warns == 0:
            self._append(t, "✔ Проблем не найдено\n", "h")
        else:
            self._append(t, "Найдено ошибок: %d, предупреждений: %d\n" % (errs, warns), "h")
            self._append(t, "Исправляйте по порядку сверху вниз; после каждого шага можно снова нажать «Проверить всё».\n"
                            "Средства защиты (раздел 3) меняйте только по согласованию с ответственным за ИБ.\n")
        seen_fix = set()
        step = 0
        for s in self.sections:
            bad = [i for i in s["items"] if i["lvl"] != "OK"]
            if not bad:
                continue
            self._append(t, "\n%s\n" % s["title"], "h2")
            for lvl in ("ОШИБКА", "ВНИМАНИЕ"):
                for i in bad:
                    if i["lvl"] != lvl:
                        continue
                    step += 1
                    self._append(t, "%d. %s %s\n" % (step, ICON[lvl], i["msg"]), lvl)
                    fix = "\n".join(i["fix"])
                    if fix and fix in seen_fix:
                        self._append(t, "     → то же решение, что выше\n", "FIX")
                    elif fix:
                        seen_fix.add(fix)
                        for fl in i["fix"]:
                            self._append(t, "     %s\n" % fl, "FIX")
        if self.report_path:
            self._append(t, "\nПолный отчёт на диске: %s\n" % self.report_path)
        self.sysinfo.set("Готово. Ошибок: %d, предупреждений: %d.   %s" % (errs, warns, "   •   ".join(self.sys_lines[:2])))

    def save(self):
        fn = filedialog.asksaveasfilename(defaultextension=".txt",
                                          initialfile="astra-helper-otchet.txt",
                                          filetypes=[("Текст", "*.txt")])
        if not fn:
            return
        try:
            with open(fn, "w", encoding="utf-8") as f:
                f.write(self.summary.get("1.0", "end"))
                f.write("\n\n===== ПОЛНЫЙ ЛОГ =====\n")
                f.write("\n".join(self.log_lines))
                f.write(self.extra_report())
            messagebox.showinfo("Сохранено", "Отчёт сохранён:\n" + fn)
        except Exception as e:
            messagebox.showerror("Ошибка", str(e))



CMD_RE = re.compile(r'^\s*\[CMD\]\s*(safe|careful|danger)\|([^|]*)\|([^|]*)\|(\S*)\s*$')
RISK = {"safe": "безопасно", "careful": "осторожно", "danger": "⚠ защита"}
BACKUP_PATHS = ("/etc/apt/sources.list /etc/apt/sources.list.d /etc/krb5.conf /etc/sssd "
                "/etc/samba/smb.conf /etc/nsswitch.conf /etc/hosts /etc/pam.d /etc/X11/xorg.conf /etc/fstab")
BOX = {True: "☑", False: "☐"}


class HelperApp(App):
    extra_args = ["--cmds"]

    def __init__(self, root):
        self._pw = None
        self._dpw = None
        self.fixes = []
        self.fixing = False
        self.dom_busy = False
        App.__init__(self, root)
        root.title("Astra Linux Helper %s — диагностика и исправление" % VERSION)

        f = ttk.Frame(self.nb)
        self.tab_fixes = f
        self.nb.insert(1, f, text="Исправления")
        bar = ttk.Frame(f, padding=(0, 4))
        bar.pack(fill="x")
        ttk.Button(bar, text="Отметить безопасные", command=lambda: self.mark({"safe"})).pack(side="left")
        ttk.Button(bar, text="Отметить всё, кроме защиты",
                   command=lambda: self.mark({"safe", "careful"})).pack(side="left", padx=4)
        ttk.Button(bar, text="Снять все", command=lambda: self.mark(set())).pack(side="left")
        self.run_btn = ttk.Button(bar, text="▶  Выполнить отмеченные", command=self.run_fixes, state="disabled")
        self.run_btn.pack(side="right")

        pan = ttk.PanedWindow(f, orient="vertical")
        pan.pack(fill="both", expand=True)
        tf = ttk.Frame(pan)
        self.ftree = ttk.Treeview(tf, columns=("risk", "status"), show="tree headings", selectmode="browse")
        self.ftree.heading("#0", text="Что сделать (щёлкните по строке, чтобы отметить)")
        self.ftree.heading("risk", text="Риск")
        self.ftree.heading("status", text="Результат")
        self.ftree.column("#0", width=640)
        self.ftree.column("risk", width=110, anchor="center")
        self.ftree.column("status", width=150, anchor="center")
        for tag, color in (("safe", "#1a7f37"), ("careful", "#9a6700"), ("danger", "#cf222e")):
            self.ftree.tag_configure(tag, foreground=color)
        make_tree_copyable(self.ftree)
        sb = ttk.Scrollbar(tf, orient="vertical", command=self.ftree.yview)
        self.ftree.configure(yscrollcommand=sb.set)
        self.ftree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        pan.add(tf, weight=3)
        df = ttk.Frame(pan)
        self.detail = tk.Text(df, height=7, wrap="word", font=("DejaVu Sans Mono", 10), padx=8, pady=6)
        self.detail.pack(fill="both", expand=True)
        self.detail.tag_configure("h2", font=("DejaVu Sans", 10, "bold"))
        self.detail.tag_configure("cmd", foreground="#0b5cad")
        make_readonly(self.detail)
        pan.add(df, weight=1)
        self.ftree.bind("<ButtonRelease-1>", self.on_click)
        self.ftree.bind("<space>", lambda e: self.toggle(self.ftree.focus()))
        self.ftree.bind("<<TreeviewSelect>>", lambda e: self.show_detail(self.ftree.focus()))

        f4 = ttk.Frame(self.nb)
        self.fixlog_tab = f4
        self.nb.add(f4, text="Журнал исправлений")
        self.fixlog = self._text(f4)
        self.fixlog.tag_configure("run", font=("DejaVu Sans Mono", 10, "bold"))
        self.build_domain_tab()

    # ---------- пароль запоминается на время работы программы ----------
    def ask_password(self):
        if os.geteuid() == 0:
            return True, None
        if self._pw is not None:
            return True, self._pw
        ok, pw = App.ask_password(self)
        if ok:
            self._pw = pw
        return ok, pw

    # ---------- разбор вывода проверок ----------
    def reset_state(self):
        App.reset_state(self)
        self.pending = []

    def handle(self, line):
        m = CMD_RE.match(line)
        if not m:
            App.handle(self, line)
            return
        lvl, _cid, title, b64 = m.groups()
        try:
            cmd = base64.b64decode(b64).decode("utf-8")
        except Exception:
            return
        self.pending.append({
            "lvl": lvl, "title": title, "cmd": cmd,
            "problem": self.last_item["msg"] if self.last_item else "",
            "section": self.cur["title"] if self.cur else "",
        })

    def finish(self, rc):
        App.finish(self, rc)
        if not self.sections:
            self._pw = None          # вероятно, неверный пароль — спросим заново
            return
        self.fill_fixes()

    def fill_fixes(self):
        for i in self.ftree.get_children():
            self.ftree.delete(i)
        self.fixes = []
        seen = {}
        for p in self.pending:
            if p["cmd"] in seen:
                f = seen[p["cmd"]]
                if p["problem"] and p["problem"] not in f["problems"]:
                    f["problems"].append(p["problem"])
                continue
            f = {"lvl": p["lvl"], "title": p["title"], "cmd": p["cmd"], "section": p["section"],
                 "problems": [p["problem"]] if p["problem"] else [], "checked": p["lvl"] == "safe",
                 "status": ""}
            seen[p["cmd"]] = f
            self.fixes.append(f)
        # перезагрузка — всегда последней
        self.fixes.sort(key=lambda f: f["cmd"] == "systemctl reboot")
        for f in self.fixes:
            f["iid"] = self.ftree.insert("", "end", text="%s  %s" % (BOX[f["checked"]], f["title"]),
                                         values=(RISK[f["lvl"]], ""), tags=(f["lvl"],))
        self.run_btn.configure(state="normal" if self.fixes else "disabled")
        if self.fixes:
            self.nb.select(self.tab_fixes)
            self.ftree.focus(self.fixes[0]["iid"])
            self.ftree.selection_set(self.fixes[0]["iid"])
            self.sysinfo.set("Найдено готовых исправлений: %d. Отметьте нужные и нажмите «Выполнить отмеченные». "
                             "Остальное — вручную, см. «Итог и что сделать»." % len(self.fixes))
        else:
            self.nb.select(self.tab_summary)

    # ---------- работа со списком ----------
    def by_iid(self, iid):
        for f in self.fixes:
            if f.get("iid") == iid:
                return f
        return None

    def on_click(self, e):
        iid = self.ftree.identify_row(e.y)
        if iid and self.ftree.identify_region(e.x, e.y) in ("tree", "cell") and self.ftree.identify_column(e.x) == "#0":
            self.toggle(iid)

    def toggle(self, iid):
        f = self.by_iid(iid)
        if not f or self.fixing:
            return
        f["checked"] = not f["checked"]
        self.ftree.item(iid, text="%s  %s" % (BOX[f["checked"]], f["title"]))

    def mark(self, levels):
        for f in self.fixes:
            f["checked"] = f["lvl"] in levels
            self.ftree.item(f["iid"], text="%s  %s" % (BOX[f["checked"]], f["title"]))

    def show_detail(self, iid):
        f = self.by_iid(iid)
        t = self.detail
        t.delete("1.0", "end")
        if f:
            t.insert("end", "Команда (выполняется от root):\n", "h2")
            t.insert("end", f["cmd"] + "\n\n", "cmd")
            if f["problems"]:
                t.insert("end", "Исправляет:\n", "h2")
                for p in f["problems"]:
                    t.insert("end", "  • %s\n" % p)
            if f["lvl"] == "danger":
                t.insert("end", "\n⚠ Отключает средство защиты Astra — только по решению ответственного за ИБ.\n")

    # ---------- выполнение ----------
    def run_fixes(self):
        if self.fixing or self.running or self.dom_busy:
            return
        sel = [f for f in self.fixes if f["checked"]]
        if not sel:
            messagebox.showinfo("Ничего не отмечено", "Отметьте исправления щелчком по строке.")
            return
        lst = "\n".join("• %s\n     %s" % (f["title"], f["cmd"] if len(f["cmd"]) < 160 else f["cmd"][:157] + "…")
                        for f in sel)
        if not messagebox.askyesno(
                "Подтверждение",
                "Будут выполнены от root %d команд:\n\n%s\n\nПеред этим настройки будут сохранены в "
                "/var/backups/astra-helper/.\nВыполнить?" % (len(sel), lst[:3500])):
            return
        danger = [f for f in sel if f["lvl"] == "danger"]
        if danger:
            ans = simpledialog.askstring(
                "Изменение средств защиты",
                "Отмечены команды, отключающие средства защиты Astra:\n\n%s\n\n"
                "Делайте это только по решению ответственного за ИБ.\nНапишите ДА для подтверждения:"
                % "\n".join("• " + f["title"] for f in danger), parent=self.root)
            if (ans or "").strip().upper() != "ДА":
                return
        ok, pw = self.ask_password()
        if not ok:
            return
        lines = ["#!/bin/bash", "export LC_ALL=C",
                 'BK=/var/backups/astra-helper/$(date +%Y%m%d-%H%M%S)', 'mkdir -p "$BK"',
                 'tar czf "$BK/etc-backup.tgz" --ignore-failed-read %s 2>/dev/null' % BACKUP_PATHS,
                 'echo "### BACKUP $BK/etc-backup.tgz"']
        self.run_list = sel
        for i, f in enumerate(sel):
            lines += ['echo "### START %d"' % i,
                      "bash -c %s 2>&1 </dev/null" % shlex.quote(f["cmd"]),
                      'echo "### RC %d $?"' % i]
        lines.append('echo "### END"')
        fd, path = tempfile.mkstemp(prefix="astra-fix-", suffix=".sh")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        os.chmod(path, 0o644)
        self.fixing = True
        self.run_btn.configure(state="disabled")
        self.btn.configure(state="disabled")
        for f in sel:
            f["status"] = "ожидает"
            self.ftree.set(f["iid"], "status", "ожидает")
        self._clear(self.fixlog)
        self.nb.select(self.fixlog_tab)
        self.pb.start(12)
        self.sysinfo.set("Выполняю исправления…")
        threading.Thread(target=self.fix_worker, args=(pw, path), daemon=True).start()

    def fix_worker(self, pw, path):
        try:
            cmd = ["bash", path] if pw is None else ["sudo", "-S", "-p", "", "bash", path]
            p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if pw is not None:
                try:
                    p.stdin.write((pw + "\n").encode("utf-8"))
                except Exception:
                    pass
            p.stdin.close()
            for raw in iter(p.stdout.readline, b""):
                self.q.put(("fixline", ANSI.sub("", raw.decode("utf-8", "replace")).rstrip("\n")))
            p.wait()
            self.q.put(("fixdone", p.returncode))
        except Exception as e:
            self.q.put(("fixline", "Ошибка запуска: %s" % e))
            self.q.put(("fixdone", -1))
        finally:
            try:
                os.unlink(path)
            except Exception:
                pass

    def on_event(self, kind, val):
        if kind in ("dline", "ddone"):
            self.dom_event(kind, val)
        elif kind == "fixline":
            m = re.match(r"^### (BACKUP|START|RC|END) ?(\S*) ?(\S*)", val)
            if not m:
                self._append(self.fixlog, "    " + val + "\n")
                return
            what, a, b = m.groups()
            if what == "BACKUP":
                self.backup = a
                self._append(self.fixlog, "Резервная копия настроек: %s\n" % a, "OK")
            elif what == "START":
                f = self.run_list[int(a)]
                self.ftree.set(f["iid"], "status", "выполняется…")
                self._append(self.fixlog, "\n▶ %s\n  # %s\n" % (f["title"], f["cmd"]), "run")
            elif what == "RC":
                f = self.run_list[int(a)]
                okk = b == "0"
                f["status"] = "✔ готово" if okk else "✖ ошибка (код %s)" % b
                self.ftree.set(f["iid"], "status", f["status"])
                self._append(self.fixlog, "  %s\n" % f["status"], "OK" if okk else "ОШИБКА")
        elif kind == "fixdone":
            self.fixing = False
            self.pb.stop()
            self.btn.configure(state="normal")
            self.run_btn.configure(state="normal")
            done = [f for f in self.run_list if f["status"].startswith("✔")]
            failed = [f for f in self.run_list if not f["status"].startswith("✔")]
            if val != 0 and all(f["status"] in ("ожидает", "") for f in self.run_list):
                self._pw = None
                messagebox.showerror("Ошибка", "Не удалось выполнить команды (неверный пароль sudo?).")
                return
            self.sysinfo.set("Исправления выполнены: успешно %d, с ошибкой %d." % (len(done), len(failed)))
            msg = "Успешно: %d, с ошибкой: %d.\nРезервная копия: %s\n\nПроверить систему ещё раз?" % (
                len(done), len(failed), getattr(self, "backup", "—"))
            if messagebox.askyesno("Готово", msg):
                self.start()

    # =====================================================================
    # Вкладка «Домен»: поиск контроллеров, выбор, проверка перед вводом, ввод
    # =====================================================================
    DC_STATE = {"ok": "доступен", "partial": "частично", "dead": "не отвечает", "nodns": "нет в DNS"}
    DC_RANK = {"ok": 0, "partial": 1, "dead": 2, "nodns": 3}
    NUM = "①②③④⑤⑥⑦⑧⑨"

    def build_domain_tab(self):
        f = ttk.Frame(self.nb)
        self.tab_domain = f
        self.nb.insert(2, f, text="Домен")
        self.dcs, self.dc_sel, self.dsite, self.dsort = [], [], "", "auto"
        self.dom_mode, self.pre_key, self.pre_errors = "", None, None

        r1 = ttk.Frame(f, padding=(0, 6, 0, 2))
        r1.pack(fill="x")
        ttk.Label(r1, text="Домен:").pack(side="left")
        ttk.Entry(r1, textvariable=self.domain, width=18).pack(side="left", padx=(4, 10))
        ttk.Label(r1, text="Администратор домена:").pack(side="left")
        self.dadmin = tk.StringVar()
        ttk.Entry(r1, textvariable=self.dadmin, width=16).pack(side="left", padx=(4, 10))
        ttk.Label(r1, text="OU (необязательно):").pack(side="left")
        self.dou = tk.StringVar()
        ttk.Entry(r1, textvariable=self.dou).pack(side="left", padx=(4, 0), fill="x", expand=True)
        self.dadmin.trace("w", lambda *a: setattr(self, "_dpw", None))

        r2 = ttk.Frame(f, padding=(0, 2))
        r2.pack(fill="x")
        self.b_scan = ttk.Button(r2, text="1. Найти контроллеры", command=self.dom_scan)
        self.b_scan.pack(side="left")
        self.b_pre = ttk.Button(r2, text="2. Проверка перед вводом", command=self.dom_precheck, state="disabled")
        self.b_pre.pack(side="left", padx=4)
        self.b_join = ttk.Button(r2, text="3. Ввести в домен", command=self.dom_join, state="disabled")
        self.b_join.pack(side="left")
        self.dsrv = tk.BooleanVar(value=True)
        ttk.Checkbutton(r2, text="+ автопоиск (_srv_)", variable=self.dsrv).pack(side="right")
        self.donly = tk.BooleanVar(value=True)
        ttk.Checkbutton(r2, text="Только доступные", variable=self.donly, command=self.dom_render).pack(side="right", padx=8)
        self.dfilter = tk.StringVar()
        ttk.Entry(r2, textvariable=self.dfilter, width=12).pack(side="right")
        ttk.Label(r2, text="Фильтр:").pack(side="right", padx=(8, 4))
        self.dfilter.trace("w", lambda *a: self.dom_render())

        self.dstatus = tk.StringVar(value="Шаг 1: нажмите «Найти контроллеры» — программа найдёт их в DNS, проверит "
                                          "доступность и измерит отклик. Система при этом не меняется.")
        lbl = ttk.Label(f, textvariable=self.dstatus, padding=(0, 2), foreground="#444", wraplength=1000, justify="left")
        lbl.pack(fill="x")
        make_label_copyable(lbl, self.dstatus)

        pan = ttk.PanedWindow(f, orient="vertical")
        pan.pack(fill="both", expand=True)
        tf = ttk.Frame(pan)
        cols = ("ip", "ms", "state", "site", "note")
        self.dtree = ttk.Treeview(tf, columns=cols, show="tree headings", selectmode="browse", height=9)
        self.dtree.heading("#0", text="Контроллер (щелчок — выбрать)", command=lambda: self.dom_sort("name"))
        self.dtree.heading("ip", text="IP")
        self.dtree.heading("ms", text="Отклик, мс", command=lambda: self.dom_sort("ms"))
        self.dtree.heading("state", text="Состояние", command=lambda: self.dom_sort("auto"))
        self.dtree.heading("site", text="Сайт AD", command=lambda: self.dom_sort("site"))
        self.dtree.heading("note", text="Примечание")
        self.dtree.column("#0", width=280)
        self.dtree.column("ip", width=115)
        self.dtree.column("ms", width=100, anchor="e")
        self.dtree.column("state", width=100, anchor="center")
        self.dtree.column("site", width=140)
        self.dtree.column("note", width=260)
        self.dtree.tag_configure("mine", foreground="#1a7f37")
        self.dtree.tag_configure("partial", foreground="#9a6700")
        self.dtree.tag_configure("dead", foreground="#cf222e")
        make_tree_copyable(self.dtree)
        sb = ttk.Scrollbar(tf, orient="vertical", command=self.dtree.yview)
        self.dtree.configure(yscrollcommand=sb.set)
        self.dtree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.dtree.bind("<ButtonRelease-1>", self.dom_click)
        self.dtree.bind("<space>", lambda e: self.dom_toggle(self.dtree.focus()))
        pan.add(tf, weight=2)
        lf = ttk.Frame(pan)
        self.dlog = self._text(lf)
        self.dlog.configure(height=10)
        pan.add(lf, weight=3)

    # ---------- список контроллеров ----------
    def dom_sort(self, key):
        self.dsort = key
        self.dom_render()

    def dom_render(self):
        flt = self.dfilter.get().strip().lower()
        rows = []
        for d in self.dcs:
            if self.donly.get() and d["st"] in ("dead", "nodns") and d["name"] not in self.dc_sel:
                continue
            if flt and flt not in ("%s %s %s" % (d["name"], d["site"], d["ip"])).lower():
                continue
            rows.append(d)
        big = 10 ** 9
        keys = {
            "name": lambda d: d["name"],
            "ms": lambda d: (d["ms"] if d["ms"] is not None else big, d["name"]),
            "site": lambda d: (d["site"] or "~", d["ms"] if d["ms"] is not None else big),
            "auto": lambda d: (self.DC_RANK[d["st"]], 0 if d["mine"] else 1,
                               d["ms"] if d["ms"] is not None else big, d["name"]),
        }
        rows.sort(key=keys[self.dsort])
        focus = self.dtree.focus()
        for i in self.dtree.get_children():
            self.dtree.delete(i)
        for d in rows:
            note = []
            if d["name"] in self.dc_sel:
                n = self.dc_sel.index(d["name"])
                mark = "☑ " + (self.NUM[n] if n < len(self.NUM) else str(n + 1))
                note.append("основной" if n == 0 else "запасной")
            else:
                mark = "☐"
            if d["mine"]:
                note.append("ваш сайт AD")
            if "dns" in d["flags"]:
                note.append("ваш DNS-сервер")
            if "cfg" in d["flags"]:
                note.append("прописан в настройках")
            if d["st"] == "partial":
                note.append("закрыты порты " + d["closed"])
            tag = d["st"] if d["st"] in ("partial",) else ("dead" if d["st"] in ("dead", "nodns") else
                                                         ("mine" if d["mine"] else ""))
            self.dtree.insert("", "end", iid=d["name"], text="%s  %s" % (mark, d["name"]),
                              values=(d["ip"], "" if d["ms"] is None else d["ms"], self.DC_STATE[d["st"]],
                                      d["site"], ", ".join(note)), tags=(tag,) if tag else ())
        if focus and self.dtree.exists(focus):
            self.dtree.focus(focus)
            self.dtree.selection_set(focus)

    def dom_click(self, e):
        if self.dtree.identify_region(e.x, e.y) in ("tree", "cell"):
            self.dom_toggle(self.dtree.identify_row(e.y))

    def dom_toggle(self, name):
        d = next((x for x in self.dcs if x["name"] == name), None)
        if not d or self.dom_busy:
            return
        if name in self.dc_sel:
            self.dc_sel.remove(name)
        elif d["st"] in ("dead", "nodns"):
            self.dstatus.set("%s не отвечает — выбрать его нельзя." % name)
            return
        else:
            self.dc_sel.append(name)
        self.pre_key = None
        self.dom_render()
        self.dom_hint()

    def dom_hint(self):
        ok = any(d["st"] == "ok" for d in self.dcs)
        st = "normal" if (self.dc_sel and not self.dom_busy) else "disabled"
        self.b_pre.configure(state=st)
        self.b_join.configure(state=st)
        if not self.dcs:
            return
        if not self.dc_sel:
            self.dstatus.set("Отметьте контроллер щелчком по строке (первый отмеченный — основной, остальные — запасные)."
                             if ok else "Нет ни одного доступного контроллера — проверьте сеть и DNS.")
            return
        d = next(x for x in self.dcs if x["name"] == self.dc_sel[0])
        txt = "Основной: %s (%s мс%s)" % (d["name"], d["ms"], ", ваш сайт AD" if d["mine"] else
                                           (", сайт %s" % d["site"] if d["site"] else ""))
        if len(self.dc_sel) > 1:
            txt += "; запасные: " + ", ".join(self.dc_sel[1:])
        self.dstatus.set(txt + ". Шаг 2: «Проверка перед вводом» покажет, что может помешать. Шаг 3: «Ввести в домен».")

    # ---------- запуск astra-domain.sh ----------
    def dom_run(self, mode, args, passfile=None):
        def drop():
            if passfile:
                try:
                    os.unlink(passfile)
                except Exception:
                    pass
            return False
        if self.dom_busy or self.running or self.fixing:
            return drop()
        if not os.path.isfile(DOMSCRIPT):
            messagebox.showerror("Ошибка", "Не найден файл:\n" + DOMSCRIPT)
            return drop()
        ok, pw = self.ask_password()
        if not ok:
            return drop()
        self.dom_busy, self.dom_mode, self.dom_head = True, mode, []
        for b in (self.b_scan, self.b_pre, self.b_join, self.btn):
            b.configure(state="disabled")
        self.pb.start(12)
        cmd = (["bash", DOMSCRIPT] if pw is None else ["sudo", "-S", "-p", "", "bash", DOMSCRIPT]) + [mode] + args

        def work():
            rc = -1
            try:
                p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                if pw is not None:
                    try:
                        p.stdin.write((pw + "\n").encode("utf-8"))
                    except Exception:
                        pass
                p.stdin.close()
                for raw in iter(p.stdout.readline, b""):
                    self.q.put(("dline", ANSI.sub("", raw.decode("utf-8", "replace")).rstrip("\n")))
                rc = p.wait()
            except Exception as e:
                self.q.put(("dline", "Ошибка запуска: %s" % e))
            finally:
                if passfile:
                    try:
                        os.unlink(passfile)
                    except Exception:
                        pass
                self.q.put(("ddone", rc))
        threading.Thread(target=work, daemon=True).start()
        return True

    def make_passfile(self, pw):
        d = "/dev/shm" if os.path.isdir("/dev/shm") and os.access("/dev/shm", os.W_OK) else None
        fd, path = tempfile.mkstemp(prefix="astra-pw-", dir=d)      # права 0600
        os.write(fd, (pw + "\n").encode("utf-8"))
        os.close(fd)
        return path

    def dom_args(self):
        args = ["--domain", self.domain.get().strip(), "--dc", ",".join(self.dc_sel)]
        if self.dadmin.get().strip():
            args += ["--user", self.dadmin.get().strip()]
        if self.dou.get().strip():
            args += ["--ou", self.dou.get().strip()]
        return args

    def dom_scan(self):
        dom = self.domain.get().strip()
        if not dom:
            messagebox.showinfo("Домен", "Введите имя домена, например: example.ru")
            return
        if self.dom_run("scan", ["--domain", dom]):
            self.dcs, self.dc_sel, self.dsite, self.pre_key = [], [], "", None
            self.dom_render()
            self._clear(self.dlog)
            self.dstatus.set("Ищу контроллеры домена %s и измеряю отклик…" % dom)

    def dom_precheck(self):
        if not self.dc_sel:
            return
        pw = ""
        if self.dadmin.get().strip():
            if self._dpw is None:
                pw = simpledialog.askstring(
                    "Пароль администратора домена",
                    "Пароль пользователя %s в домене %s.\nОн нужен, чтобы проверить, пускает ли контроллер этого "
                    "пользователя.\nМожно оставить пустым — тогда логин и пароль не проверяются."
                    % (self.dadmin.get().strip(), self.domain.get().strip()), show="*", parent=self.root)
                if pw is None:
                    return
                self._dpw = pw or None
            else:
                pw = self._dpw
        args = self.dom_args()
        pf = None
        if pw:
            pf = self.make_passfile(pw)
            args += ["--passfile", pf]
        if self.dom_run("precheck", args, pf):
            self._clear(self.dlog)
            self.pre_errors = None
            self.dstatus.set("Проверяю, всё ли готово для ввода в домен…")

    def dom_join(self):
        if not self.dc_sel:
            return
        admin, dom = self.dadmin.get().strip(), self.domain.get().strip()
        if not admin:
            messagebox.showinfo("Администратор домена", "Заполните поле «Администратор домена» — логин пользователя, "
                                                         "у которого есть право вводить компьютеры в домен.")
            return
        key = (tuple(self.dc_sel), admin, dom)
        if self.pre_key != key:
            if not messagebox.askyesno("Проверка не выполнена", "Проверка перед вводом для этого набора (контроллер, "
                                       "пользователь) не выполнялась.\nЛучше сначала нажать «Проверка перед вводом».\n\n"
                                       "Всё равно вводить в домен сейчас?"):
                return
        elif self.pre_errors:
            if not messagebox.askyesno("Есть ошибки", "Проверка перед вводом нашла ошибок: %d.\nСкорее всего, ввод в домен "
                                       "не пройдёт.\n\nВсё равно попробовать?" % self.pre_errors):
                return
        if not self._dpw:
            pw = simpledialog.askstring("Пароль администратора домена", "Пароль пользователя %s в домене %s:"
                                        % (admin, dom), show="*", parent=self.root)
            if not pw:
                return
            self._dpw = pw
        if not messagebox.askyesno(
                "Ввод в домен",
                "Компьютер будет введён в домен %s.\n\nОсновной контроллер: %s\nЗапасные: %s%s\nПользователь: %s\n"
                "OU: %s\n\nЧто будет сделано:\n"
                "• копия настроек в /var/backups/astra-helper/;\n"
                "• установка недостающих пакетов (adcli, sssd…);\n"
                "• ввод в домен (adcli join), новый /etc/krb5.keytab;\n"
                "• настройка sssd.conf, krb5.conf, nsswitch и PAM, перезапуск sssd.\n\nПродолжить?"
                % (dom, self.dc_sel[0], ", ".join(self.dc_sel[1:]) or "нет",
                   " + автопоиск (_srv_)" if self.dsrv.get() else "", admin, self.dou.get().strip() or "по умолчанию")):
            return
        pf = self.make_passfile(self._dpw)
        args = self.dom_args() + ["--passfile", pf] + (["--srv"] if self.dsrv.get() else [])
        if self.dom_run("join", args, pf):
            self._clear(self.dlog)
            self.dstatus.set("Ввожу компьютер в домен… не закрывайте программу.")

    # ---------- разбор вывода ----------
    def dom_event(self, kind, val):
        if kind == "dline":
            if len(self.dom_head) < 8:
                self.dom_head.append(val)
            if val.startswith("[DC] "):
                a = (val[5:].split("|") + [""] * 9)[:9]
                self.dcs.append({"name": a[0], "ip": a[1], "st": a[2] if a[2] in self.DC_RANK else "dead",
                                 "ms": int(a[3]) if a[3].isdigit() else None, "closed": a[4], "site": a[5],
                                 "csite": a[6], "flags": a[8].split(), "mine": False})
                return
            if val.startswith("[SITE]"):
                self.dsite = val[6:].strip()
                return
            if val.startswith(("[SHORT]", "[SCAN]")):
                return
            m = re.match(r"^\[RESULT\] (\w+) ?(\S*)", val)
            if m:
                self.dom_result = (m.group(1), m.group(2))
                return
            mi, mf, ms = ITEM_RE.match(val), FIX_RE.match(val), SECTION_RE.match(val)
            if ms:
                self._append(self.dlog, "\n" + ms.group(1) + "\n", "h2")
            elif mi:
                self._append(self.dlog, "%s %s\n" % (ICON[mi.group(1)], mi.group(2)), mi.group(1))
            elif mf:
                self._append(self.dlog, "      " + mf.group(1) + "\n", "FIX")
            elif val.strip():
                self._append(self.dlog, val + "\n")
            return
        # ddone
        mode, rc = self.dom_mode, val
        self.dom_busy = False
        self.pb.stop()
        self.b_scan.configure(state="normal")
        self.btn.configure(state="normal")
        self.save_btn.configure(state="normal")
        res = getattr(self, "dom_result", None)
        self.dom_result = None
        if rc != 0 and not res and re.search(r"incorrect password|Sorry, try again|no password was provided|"
                                             r"is not in the sudoers", "\n".join(self.dom_head)):
            self._pw = None
            self.dstatus.set("Не удалось запустить (неверный пароль sudo?). Попробуйте ещё раз.")
            self.dom_hint_buttons()
            return
        if mode == "scan":
            for d in self.dcs:
                d["mine"] = bool(self.dsite) and d["site"] == self.dsite
            good = sorted([d for d in self.dcs if d["st"] == "ok"],
                          key=lambda d: (0 if d["mine"] else 1, d["ms"] if d["ms"] is not None else 10 ** 9))
            if good and not self.dc_sel:
                self.dc_sel = [good[0]["name"]]
            self.dom_render()
            n = len(self.dcs)
            dead = [d for d in self.dcs if d["st"] in ("dead", "nodns")]
            part = [d for d in self.dcs if d["st"] == "partial"]
            if n:
                self._append(self.dlog, "Контроллеров в DNS: %d, доступно: %d, частично: %d, не отвечают: %d\n"
                             % (n, len(good), len(part), len(dead)), "h2")
                self._append(self.dlog, "Сайт AD этого компьютера: %s\n" % (
                    self.dsite or "не определён (подсеть компьютера не привязана к сайту — ориентируйтесь на отклик)"))
                if good:
                    self._append(self.dlog, "Ближайший: %s — %s мс. Он отмечен; щелчком можно выбрать другой "
                                 "или добавить запасные.\n" % (good[0]["name"], good[0]["ms"]), "OK")
                if dead:
                    self._append(self.dlog, "\nНе отвечают (стоит передать администраторам домена — записи пора убрать из DNS):\n", "ВНИМАНИЕ")
                    for d in dead:
                        self._append(self.dlog, "  %s  %s\n" % (d["name"], d["ip"] or "нет в DNS"))
                if part:
                    self._append(self.dlog, "\nДоступны частично (для ввода в домен не подходят):\n", "ВНИМАНИЕ")
                    for d in part:
                        self._append(self.dlog, "  %s  %s — закрыты порты %s\n" % (d["name"], d["ip"], d["closed"]))
                self.dlog.see("1.0")
            self.dom_hint()
            if not n:
                self.dstatus.set("Контроллеры не найдены — причина в журнале ниже.")
        elif mode == "precheck":
            errs = int(res[1]) if res and res[1].isdigit() else None
            self.pre_errors = errs
            self.pre_key = (tuple(self.dc_sel), self.dadmin.get().strip(), self.domain.get().strip())
            if "не принял" in self.dlog.get("1.0", "end"):
                self._dpw = None                     # пароль не подошёл — спросим заново
            self.dom_hint_buttons()
            if errs == 0:
                self.dstatus.set("Проверка пройдена: препятствий нет. Шаг 3: «Ввести в домен».")
            elif errs:
                self.dstatus.set("Проверка нашла препятствий: %d — они отмечены ✖ в журнале ниже, там же что делать. "
                                 "Исправьте и повторите проверку." % errs)
            else:
                self.dstatus.set("Проверка не завершилась — смотрите журнал ниже.")
            self.dlog.see("1.0")
        elif mode == "join":
            self._dpw = None
            self.dom_hint_buttons()
            if res and res[1] == "ok":
                self.dstatus.set("Компьютер введён в домен. Перезагрузитесь и войдите под доменной учётной записью.")
                if messagebox.askyesno("Готово", "Компьютер введён в домен %s.\n\nЗапустить полную проверку, чтобы "
                                       "убедиться, что всё в порядке?" % self.domain.get().strip()):
                    self.start()
            else:
                self.dstatus.set("Ввод в домен не прошёл — причина отмечена ✖ в журнале ниже. Журнал можно скопировать.")
                self.dlog.see("end")

    def dom_hint_buttons(self):
        st = "normal" if self.dc_sel else "disabled"
        self.b_pre.configure(state=st)
        self.b_join.configure(state=st)

    def extra_report(self):
        out = ""
        txt = self.dlog.get("1.0", "end").strip()
        if txt:
            out += "\n\n===== ДОМЕН =====\n" + txt
            rows = []
            for iid in self.dtree.get_children(""):
                rows += tree_lines(self.dtree, iid)
            if rows:
                out += "\n\nКонтроллеры:\n" + "\n".join(rows)
        txt = self.fixlog.get("1.0", "end").strip()
        if txt:
            out += "\n\n===== ЖУРНАЛ ИСПРАВЛЕНИЙ =====\n" + txt
        return out



def main():
    root = tk.Tk()
    try:
        ttk.Style().theme_use("clam")
    except Exception:
        pass
    HelperApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
