#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Astra Linux Helper — графическая диагностика типичных проблем Astra Linux SE 1.6 / 1.7 / 1.8.
Ничего не меняет в системе: запускает проверки (astra-doctor.sh) и показывает, что исправить.
Совместимо с Python 3.5+ (Astra 1.6) и Python 3.11 (Astra 1.8). Нужен пакет python3-tk.
"""
import os
import re
import sys
import threading
import subprocess

try:
    import queue
    import tkinter as tk
    from tkinter import ttk, messagebox, simpledialog, filedialog
except ImportError:
    print("Не найден tkinter (пакет python3-tk). Запустите установку: sudo ./install.sh")
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "astra-doctor.sh")
VERSION = "1.0"

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
        ttk.Label(root, textvariable=self.sysinfo, padding=(8, 2), foreground="#444").pack(fill="x")
        self.pb = ttk.Progressbar(root, mode="indeterminate")
        self.pb.pack(fill="x", padx=8, pady=4)

        nb = ttk.Notebook(root)
        nb.pack(fill="both", expand=True, padx=8, pady=(0, 8))
        self.nb = nb

        f1 = ttk.Frame(nb)
        nb.add(f1, text="Проверки")
        self.tree = ttk.Treeview(f1, show="tree")
        sb = ttk.Scrollbar(f1, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        for tag, color in (("OK", "#1a7f37"), ("ВНИМАНИЕ", "#9a6700"), ("ОШИБКА", "#cf222e"),
                           ("RUN", "#555555"), ("FIX", "#0b5cad")):
            self.tree.tag_configure(tag, foreground=color)

        f2 = ttk.Frame(nb)
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
        t.configure(state="disabled")
        return t

    def _append(self, t, text, tag=None):
        t.configure(state="normal")
        t.insert("end", text, tag)
        t.see("end")
        t.configure(state="disabled")

    def _clear(self, t):
        t.configure(state="normal")
        t.delete("1.0", "end")
        t.configure(state="disabled")

    # ---------------- запуск ----------------
    def start(self):
        if self.running:
            return
        if not os.path.isfile(SCRIPT):
            messagebox.showerror("Ошибка", "Не найден файл проверок:\n" + SCRIPT)
            return
        only = [k for k, _ in MODULES if self.mod_vars[k].get()]
        if not only:
            messagebox.showinfo("Нечего проверять", "Отметьте хотя бы один раздел.")
            return
        pw = None
        if os.geteuid() != 0:
            pw = simpledialog.askstring(
                "Нужны права администратора",
                "Проверкам нужны права root (чтение системных настроек).\n"
                "Введите пароль sudo для пользователя %s:" % os.environ.get("USER", ""),
                show="*", parent=self.root)
            if pw is None:
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
        threading.Thread(target=self.worker, args=(pw, args), daemon=True).start()

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
                else:
                    self.finish(val)
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
        self.nb.select(1)

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
            messagebox.showinfo("Сохранено", "Отчёт сохранён:\n" + fn)
        except Exception as e:
            messagebox.showerror("Ошибка", str(e))


def main():
    root = tk.Tk()
    try:
        ttk.Style().theme_use("clam")
    except Exception:
        pass
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
