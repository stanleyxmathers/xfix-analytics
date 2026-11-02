"""Shifton (MCP shift:list) -> Excel grid for the XFIX Analytics schedule import.

Usage: python3 shifton_to_xlsx.py <shift_list.json> <out.xlsx> [YYYY-MM]

Input is the JSON answer of the Shifton MCP `read shift list` call (UTC times).
Output is one sheet «сотрудники × дни»: a row per employee, a column per day
(dd.mm.yyyy), cells «ЧЧ:ММ-ЧЧ:ММ» in Moscow time. Several shifts on one day are
merged into first start – last end. Contacts and other personal fields are not
copied. The dashboard reads this file via «Загрузить файл» in Планирование or
«Импорт из Shifton» in График.
"""
import calendar
import json
import sys
from collections import defaultdict
from datetime import datetime, timedelta

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill

MSK = timedelta(hours=3)


def load(path):
    d = json.load(open(path, encoding="utf-8"))
    return d.get("data", d) if isinstance(d, dict) else d


def main(src, out, month=None):
    shifts = [s for s in load(src) if s.get("employee") and not s.get("deleted_at")]
    days = defaultdict(lambda: defaultdict(list))  # name -> date -> [(start, end)]
    for s in shifts:
        a = datetime.strptime(s["time_from"], "%Y-%m-%d %H:%M:%S") + MSK
        b = datetime.strptime(s["time_to"], "%Y-%m-%d %H:%M:%S") + MSK
        if month and a.strftime("%Y-%m") != month:
            continue
        name = s["employee"]["full_name"].strip()
        days[name][a.date()].append((a, b))
    if not days:
        sys.exit("нет смен")
    month = month or min(d for v in days.values() for d in v).strftime("%Y-%m")
    y, m = map(int, month.split("-"))
    dates = [datetime(y, m, i).date() for i in range(1, calendar.monthrange(y, m)[1] + 1)]

    wb = Workbook()
    ws = wb.active
    ws.title = month
    ws.append(["Сотрудник", "Смен", "Часов"] + [d.strftime("%d.%m.%Y") for d in dates])
    weekend = PatternFill("solid", fgColor="EEEEEE")
    for name in sorted(days):
        row, n, hrs = [], 0, 0.0
        for d in dates:
            spans = days[name].get(d)
            if not spans:
                row.append("")
                continue
            a, b = min(x for x, _ in spans), max(y for _, y in spans)
            row.append(f"{a:%H:%M}-{b:%H:%M}")
            n += 1
            hrs += sum((y - x).total_seconds() for x, y in spans) / 3600
        ws.append([name, n, round(hrs, 1)] + row)
    for c in ws[1]:
        c.font = Font(bold=True)
        c.alignment = Alignment(horizontal="center", text_rotation=90 if c.column > 3 else 0)
    for i, d in enumerate(dates, start=4):
        if d.weekday() >= 5:
            for r in range(1, ws.max_row + 1):
                ws.cell(r, i).fill = weekend
        ws.column_dimensions[ws.cell(1, i).column_letter].width = 11
    ws.column_dimensions["A"].width = 26
    ws.freeze_panes = "D2"
    wb.save(out)
    print(f"{out}: {len(days)} сотрудников, {sum(len(v) for v in days.values())} рабочих дней, {month}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
