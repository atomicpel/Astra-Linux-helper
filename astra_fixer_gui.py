#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Astra Fixer — исправление типичных проблем Astra Linux SE 1.6 / 1.7 / 1.8.
Делает те же проверки, что Astra Linux Helper, и предлагает готовые команды исправления.
Выполняет ТОЛЬКО отмеченные пользователем команды, после подтверждения,
предварительно сохранив копию настроек в /var/backups/astra-helper/.
"""
import os
import re
import sys
import base64
import shlex
import tempfile
import threading
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import astra_helper_gui as base                       # noqa: E402
from astra_helper_gui import tk, ttk, messagebox, simpledialog, ANSI   # noqa: E402

CMD_RE = re.compile(r'^\s*\[CMD\]\s*(safe|careful|danger)\|([^|]*)\|([^|]*)\|(\S*)\s*$')
RISK = {"safe": "безопасно", "careful": "осторожно", "danger": "⚠ защита"}
BACKUP_PATHS = ("/etc/apt/sources.list /etc/apt/sources.list.d /etc/krb5.conf /etc/sssd "
                "/etc/samba/smb.conf /etc/nsswitch.conf /etc/hosts /etc/pam.d /etc/X11/xorg.conf /etc/fstab")
BOX = {True: "☑", False: "☐"}


class FixerApp(base.App):
    extra_args = ["--cmds"]

    def __init__(self, root):
        self._pw = None
        self.fixes = []
        self.fixing = False
        base.App.__init__(self, root)
        root.title("Astra Fixer %s — исправление проблем Astra Linux" % base.VERSION)
        self.btn.configure(text="▶  Найти проблемы")

        f = ttk.Frame(self.nb)
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
        self.detail.configure(state="disabled")
        pan.add(df, weight=1)
        self.ftree.bind("<ButtonRelease-1>", self.on_click)
        self.ftree.bind("<space>", lambda e: self.toggle(self.ftree.focus()))
        self.ftree.bind("<<TreeviewSelect>>", lambda e: self.show_detail(self.ftree.focus()))

        f4 = ttk.Frame(self.nb)
        self.fixlog_tab = f4
        self.nb.add(f4, text="Журнал исправлений")
        self.fixlog = self._text(f4)
        self.fixlog.tag_configure("run", font=("DejaVu Sans Mono", 10, "bold"))

    # ---------- пароль запоминается на время работы программы ----------
    def ask_password(self):
        if os.geteuid() == 0:
            return True, None
        if self._pw is not None:
            return True, self._pw
        ok, pw = base.App.ask_password(self)
        if ok:
            self._pw = pw
        return ok, pw

    # ---------- разбор вывода проверок ----------
    def reset_state(self):
        base.App.reset_state(self)
        self.pending = []

    def handle(self, line):
        m = CMD_RE.match(line)
        if not m:
            base.App.handle(self, line)
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
        base.App.finish(self, rc)
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
            self.nb.select(1)
            self.ftree.focus(self.fixes[0]["iid"])
            self.ftree.selection_set(self.fixes[0]["iid"])
            self.sysinfo.set("Найдено готовых исправлений: %d. Отметьте нужные и нажмите «Выполнить отмеченные». "
                             "Остальное — вручную, см. «Итог и что сделать»." % len(self.fixes))
        else:
            self.nb.select(2)

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
        t.configure(state="normal")
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
        t.configure(state="disabled")

    # ---------- выполнение ----------
    def run_fixes(self):
        if self.fixing or self.running:
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
        if kind == "fixline":
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


def main():
    root = tk.Tk()
    try:
        ttk.Style().theme_use("clam")
    except Exception:
        pass
    FixerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
